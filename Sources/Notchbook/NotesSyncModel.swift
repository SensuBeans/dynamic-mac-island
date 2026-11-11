import AppKit
import Combine

/// Two-way sync between the Notes tab and the user's Apple Notes library.
///
/// Every script runs as a spawned `osascript` on a background queue — never
/// `NSAppleScript` (main-thread-only) and never on the main thread. Notes are
/// tracked by their stable AppleScript `id` (an `x-coredata://` URL), never by
/// name or index.
///
/// Scope: the model reads the WHOLE library (folder/title/date index, plus the
/// bodies of the handful of notes the editor is actually backing) but the only
/// write it can ever perform is a conflict-guarded `set body of n` on a note the
/// user explicitly opened. There is no delete path — nothing here can remove a
/// note or a folder.
///
/// Conflict rule: freshest-writer-wins. Before pushing an edit we re-read the
/// note's modification date; if it changed in Notes.app/iPhone since our last
/// pull, we DO NOT push — we pull the fresh content and toast the user.
final class NotesSyncModel: ObservableObject {
    /// Why a page's body is (or isn't) editable. `.loading` and `.locked` both
    /// mean "never push"; only `.ready` may be written back.
    enum Load: String, Codable { case ready, loading, locked }

    struct Page: Identifiable, Equatable, Codable {
        let id: String          // AppleScript note id (x-coredata:// URL)
        var title: String       // note title (first line)
        var body: String        // plaintext
        var modSeconds: Double   // local-epoch seconds (consistent, not absolute)
        var load: Load = .ready
        /// Whether the note holds more than plain text lines (see
        /// `isRichNote`). nil = its body was never inspected. A rich note is
        /// shown with `load == .locked` and is never written back, because a
        /// push rebuilds the note from plain text and would strip the rest.
        var rich: Bool? = nil
        /// The note's first line carries Notes' title style; a push keeps it.
        var titleHeading = false
        /// Cache only: a local edit Apple Notes had not confirmed when the
        /// cache was written, so the next launch sends it instead of treating
        /// it as synced.
        var unsent = false

        // Hand-rolled so a cache written before `load` existed still decodes
        // (synthesized Codable ignores default values and would throw).
        init(id: String, title: String, body: String, modSeconds: Double,
             load: Load = .ready) {
            self.id = id; self.title = title; self.body = body
            self.modSeconds = modSeconds; self.load = load
        }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            id = try c.decode(String.self, forKey: .id)
            title = try c.decode(String.self, forKey: .title)
            body = try c.decode(String.self, forKey: .body)
            modSeconds = try c.decode(Double.self, forKey: .modSeconds)
            load = (try? c.decode(Load.self, forKey: .load)) ?? .ready
            rich = try? c.decode(Bool.self, forKey: .rich)
            titleHeading = (try? c.decode(Bool.self, forKey: .titleHeading)) ?? false
            unsent = (try? c.decode(Bool.self, forKey: .unsent)) ?? false
        }
    }

    /// One note as it appears in the browser: metadata only, never a body.
    struct NoteMeta: Identifiable, Equatable {
        let id: String
        var title: String
        var modSeconds: Double
        var locked: Bool
    }

    /// One Apple Notes folder and its notes, in the order Notes reports them.
    struct NoteFolder: Identifiable, Equatable {
        let id: String
        var name: String
        var notes: [NoteMeta]
    }

    enum Mode: String { case local, notes }

    @Published var mode: Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) }
    }
    @Published var folderName: String {
        didSet { UserDefaults.standard.set(folderName, forKey: Self.folderKey) }
    }
    /// Bodies the editor is backing: the most recently modified notes across
    /// the whole library, plus whatever the user explicitly opened.
    @Published private(set) var pages: [Page] = []
    /// The browser index: every folder, every note title — no bodies.
    @Published private(set) var folders: [NoteFolder] = []
    @Published private(set) var syncing = false

    /// Set by the app: shows a transient island toast (title, subtitle).
    var onToast: ((String, String) -> Void)?
    /// Called on the main thread when Automation permission for Notes is denied.
    var onPermissionDenied: (() -> Void)?

    /// How many notes back the chips/editor hold at once.
    static let pageCap = 9

    private static let modeKey = "notesSyncMode"
    private static let folderKey = "notesSyncFolder"
    private static let cacheFile = "notes-sync-cache.json"
    /// Name of the Notes trash folder (English systems).
    private static let trashFolderName = "Recently Deleted"

    private let scriptQueue = DispatchQueue(label: "com.sensubeans.notchbook.notes",
                                            qos: .userInitiated)
    /// Per-note debounce so rapid typing coalesces into one push.
    private var pushWork: [String: DispatchWorkItem] = [:]
    /// Monotonic per-note edit counter. A push carries the generation it was built
    /// from, so its completion can tell "I am the latest" from "the user has typed
    /// since" — the difference between safely clearing `dirty` and losing an edit.
    private var editGeneration: [String: Int] = [:]
    /// id → modification seconds at last pull, for conflict detection. Only ever
    /// written when we actually (re)read that note's BODY — refreshing it from a
    /// metadata-only index would blind the guard to outside edits.
    private var modCache: [String: Double] = [:]
    /// Notes with a local edit that Apple Notes hasn't confirmed yet. An index
    /// refresh must not overwrite their bodies out from under the typist.
    private var dirty: Set<String> = []
    /// Flat id → metadata map built from the last index pull.
    private var metaIndex: [String: NoteMeta] = [:]
    /// The note the user explicitly opened; kept in `pages` even once it falls
    /// out of the most-recent window.
    private var openID: String?
    /// A library pull is queued or running. Each one walks every folder, so a
    /// second request while one is out is dropped rather than stacked.
    private var pullInFlight = false
    /// When the last pull started, for `refresh()`'s minimum interval.
    private var lastPullAt = Date.distantPast
    /// The island asks for a refresh on every open; pull at most this often.
    private static let minRefreshInterval: TimeInterval = 30
    /// A pull or body fetch failed and the user was told; cleared on the next
    /// success so a run of failures toasts once, not on every open.
    private var readFailing = false
    /// Automatic retries used per note since its last edit or confirmed push.
    private var pushRetries: [String: Int] = [:]
    private static let maxPushRetries = 3
    /// Debounced cache write, and the queue it runs on (off the main thread).
    private var cacheWork: DispatchWorkItem?
    private let cacheQueue = DispatchQueue(label: "com.sensubeans.notchbook.notes.cache",
                                           qos: .utility)

    private let unit = "\u{1F}"   // field separator
    private let record = "\u{1E}" // record separator

    init() {
        mode = Mode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "")
            ?? .local
        folderName = UserDefaults.standard.string(forKey: Self.folderKey) ?? "Notchbook"
        loadCache()   // instant render from the last-synced snapshot
        if mode == .notes { pull(); resendUnsent() }
    }

    // MARK: - Mode

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        if newMode == .notes { pull(); resendUnsent() }
    }

    // MARK: - Pull (index the whole library)

    /// Called on tab open / panel expand while in Apple Notes mode.
    /// The panel calls this on every open whatever tab is showing, so it is
    /// rate-limited here: each pull is a whole-library script against Notes.
    func refresh() {
        guard mode == .notes, !pullInFlight,
              Date().timeIntervalSince(lastPullAt) >= Self.minRefreshInterval
        else { return }
        pull()
    }

    /// ONE script for the entire library: folder ids/names plus each note's id,
    /// modification date, lock flag and title. Properties are read as bulk lists
    /// (`id of notes of f`, …) — a per-note Apple Event loop is orders of
    /// magnitude slower. No bodies: those are fetched lazily by `loadBodies`.
    func pull() {
        // One at a time: pulls share the serial queue with pushes, and stacked
        // pulls made edits wait behind them.
        guard !pullInFlight else { return }
        pullInFlight = true
        lastPullAt = Date()
        let script = """
        tell application "Notes"
            \(Self.epochPrefix)
            set us to (ASCII character 31)
            set rs to (ASCII character 30)
            set out to ""
            repeat with f in folders
                set nIds to id of notes of f
                set nNames to name of notes of f
                set nDates to modification date of notes of f
                set nLock to password protected of notes of f
                set out to out & "F" & us & (id of f) & us & (name of f) & us & (count of nIds) & rs
                repeat with i from 1 to (count of nIds)
                    set secs to ((item i of nDates) - refDate)
                    set out to out & "N" & us & (item i of nIds) & us & (secs as string) & us & (item i of nLock) & us & (item i of nNames) & rs
                end repeat
            end repeat
            return out
        end tell
        """
        syncing = true
        scriptQueue.async { [weak self] in
            guard let self else { return }
            let result = Self.run(script)
            DispatchQueue.main.async {
                self.syncing = false
                self.pullInFlight = false
                if self.handlePermission(result) { return }
                guard result.ok else {
                    self.lastPullAt = .distantPast   // let the next open retry
                    self.reportReadFailure()
                    return
                }
                self.readFailing = false
                let parsed = self.parseIndex(result.out ?? "")
                self.folders = parsed
                self.metaIndex = Dictionary(
                    parsed.flatMap { $0.notes }.map { ($0.id, $0) },
                    uniquingKeysWith: { a, _ in a })
                self.applyIndex()
            }
        }
    }

    private func parseIndex(_ raw: String) -> [NoteFolder] {
        var out: [NoteFolder] = []
        // Notes lists its trash as a folder. Notes in it must not be offered
        // for editing, so that folder and its notes are left out.
        var inTrash = false
        for rec in raw.components(separatedBy: record) where !rec.isEmpty {
            let parts = rec.components(separatedBy: unit)
            guard let kind = parts.first else { continue }
            if kind == "F", parts.count >= 3 {
                inTrash = parts[2] == Self.trashFolderName
                if inTrash { continue }
                out.append(NoteFolder(id: parts[1], name: parts[2], notes: []))
            } else if kind == "N", parts.count >= 5, !out.isEmpty, !inTrash {
                out[out.count - 1].notes.append(
                    NoteMeta(id: parts[1],
                             title: parts[4],
                             modSeconds: Double(parts[2]) ?? 0,
                             locked: parts[3] == "true"))
            }
        }
        return out
    }

    /// Rebuild `pages` from the freshly pulled index: the `pageCap` most
    /// recently modified notes in the library (plus the explicitly opened one),
    /// reusing bodies we already hold and fetching the ones we don't.
    private func applyIndex() {
        var order = metaIndex.values
            .sorted { $0.modSeconds > $1.modSeconds }
            .prefix(Self.pageCap)
            .map(\.id)
        if let openID, metaIndex[openID] != nil, !order.contains(openID) {
            order.append(openID)
        }

        let existing = Dictionary(pages.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var next: [Page] = []
        var needBody: [String] = []
        for id in order {
            guard let meta = metaIndex[id] else { continue }
            let held = existing[id]
            if meta.locked {
                // Password-protected: the body is unreadable and must never be
                // written. Surface it as an empty, read-only page.
                next.append(Page(id: id, title: meta.title, body: "",
                                 modSeconds: meta.modSeconds, load: .locked))
            } else if dirty.contains(id), let held {
                // A local edit is in flight — the index's copy is the stale one.
                next.append(held)
            } else if let held, held.modSeconds == meta.modSeconds,
                      (held.load == .ready && held.rich == false) || held.rich == true {
                // Unchanged since we last read and inspected its body.
                var p = held
                p.title = meta.title
                next.append(p)
            } else {
                needBody.append(id)
                next.append(Page(id: id, title: meta.title, body: held?.body ?? "",
                                 modSeconds: meta.modSeconds, load: .loading))
            }
        }
        pages = next
        saveCache()
        loadBodies(needBody)
    }

    // MARK: - Open (lazy body fetch)

    /// Open any note in the library: promote it into `pages` and fetch its body.
    /// Metadata comes from the last index pull when we have it, so the chip and
    /// title appear immediately.
    func open(id: String) {
        openID = id
        let meta = metaIndex[id]
        if let idx = pages.firstIndex(where: { $0.id == id }) {
            // Already backed — refresh it unless a local edit is pending.
            guard !dirty.contains(id) else { return }
            if meta?.locked == true {
                pages[idx].load = .locked
                pages[idx].body = ""
                return
            }
            if pages[idx].load == .ready,
               let meta, pages[idx].modSeconds == meta.modSeconds { return }
            if pages[idx].rich == true,
               let meta, pages[idx].modSeconds == meta.modSeconds {
                toastReadOnly()   // say why the editor is greyed out
                return
            }
            pages[idx].load = .loading
        } else {
            let page = Page(id: id,
                            title: meta?.title ?? "",
                            body: "",
                            modSeconds: meta?.modSeconds ?? 0,
                            load: meta?.locked == true ? .locked : .loading)
            pages.insert(page, at: 0)
            trimPages()
            if page.load == .locked { saveCache(); return }
        }
        loadBodies([id])
    }

    /// Drop the oldest pages beyond the cap, never the open one.
    private func trimPages() {
        while pages.count > Self.pageCap,
              let victim = pages.lastIndex(where: { $0.id != openID }) {
            pages.remove(at: victim)
        }
    }

    /// Fetch plaintext + fresh metadata for specific ids in ONE script. Each
    /// note is wrapped in its own `try` so a note deleted between the index pull
    /// and this fetch can't take the whole batch down.
    private func loadBodies(_ ids: [String]) {
        guard !ids.isEmpty else { return }
        let fetches = ids.map { id in
            """
                try
                    set n to note id "\(Self.escapeAS(id))"
                    set secs to ((modification date of n) - refDate)
                    set att to 1
                    try
                        set att to (count of attachments of n)
                    end try
                    set markup to ""
                    if att is 0 then set markup to (body of n)
                    set out to out & (id of n) & us & (secs as string) & us & (name of n) & us & (plaintext of n) & us & (att as string) & us & markup & rs
                end try
            """
        }.joined(separator: "\n")
        let script = """
        tell application "Notes"
            \(Self.epochPrefix)
            set us to (ASCII character 31)
            set rs to (ASCII character 30)
            set out to ""
        \(fetches)
            return out
        end tell
        """
        syncing = true
        scriptQueue.async { [weak self] in
            guard let self else { return }
            let result = Self.run(script)
            DispatchQueue.main.async {
                self.syncing = false
                if self.handlePermission(result) { return }
                guard result.ok else { self.reportReadFailure(); return }
                self.readFailing = false
                for rec in (result.out ?? "").components(separatedBy: self.record)
                where !rec.isEmpty {
                    let parts = rec.components(separatedBy: self.unit)
                    guard parts.count >= 6 else { continue }
                    let id = parts[0]
                    let secs = Double(parts[1]) ?? 0
                    // A local edit that landed while the fetch was in flight wins.
                    guard !self.dirty.contains(id),
                          let idx = self.pages.firstIndex(where: { $0.id == id })
                    else { continue }
                    self.pages[idx].title = parts[2]
                    self.pages[idx].body = parts[3]
                    self.pages[idx].modSeconds = secs
                    // A note with attachments or any markup beyond plain lines
                    // stays read-only here: pushing would flatten it.
                    let rich = (Int(parts[4]) ?? 1) > 0 || Self.isRichNote(html: parts[5])
                    self.pages[idx].rich = rich
                    self.pages[idx].titleHeading = !rich && Self.hasTitleHeading(html: parts[5])
                    self.pages[idx].load = rich ? .locked : .ready
                    self.modCache[id] = secs
                    if rich, id == self.openID { self.toastReadOnly() }
                }
                self.saveCache()
            }
        }
    }

    // MARK: - Create

    /// The `+` chip: always creates in the dedicated sync folder.
    func createNote(completion: ((String?) -> Void)? = nil) {
        let f = Self.escapeAS(folderName)
        let script = """
        tell application "Notes"
            if not (exists folder "\(f)") then make new folder with properties {name:"\(f)"}
            set n to make new note at folder "\(f)" with properties {body:"<div>New Note</div>"}
            return id of n
        end tell
        """
        scriptQueue.async { [weak self] in
            guard let self else { return }
            let result = Self.run(script)
            DispatchQueue.main.async {
                if self.handlePermission(result) { return }
                let newID = result.ok ? result.out : nil
                if newID == nil {
                    self.onToast?("Couldn't create the note", "Notes did not answer")
                }
                if let newID { self.open(id: newID) }
                self.pull()
                completion?(newID)
            }
        }
    }

    // MARK: - Edit / push

    /// Optimistically update the local page and schedule a debounced push.
    /// Only a fully loaded, unlocked note may be written.
    func edit(id: String, text: String) {
        guard let idx = pages.firstIndex(where: { $0.id == id }),
              pages[idx].load == .ready else { return }
        pages[idx].body = text
        pages[idx].title = text.components(separatedBy: "\n").first ?? ""
        dirty.insert(id)
        pushRetries[id] = nil
        saveCache()

        // Stamp this edit. A push that completes AFTER a newer keystroke must not
        // clear `dirty` or drop the newer work item — see the completion handler.
        let gen = (editGeneration[id] ?? 0) + 1
        editGeneration[id] = gen

        pushWork[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.push(id: id, text: text, gen: gen) }
        pushWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    /// Push every debounced edit RIGHT NOW, synchronously. Called from
    /// `applicationWillTerminate`.
    ///
    /// `edit()` saves to the local cache immediately but only schedules the real
    /// push 2 s later. Quitting inside that window killed the queued work item, so
    /// the island kept the text forever while Apple Notes — and every synced
    /// device — never received it, with nothing on screen to say the two copies
    /// had diverged. Blocking quit briefly is the right trade against silently
    /// diverging the user's notes; `Self.run` is timeout-bounded, and only
    /// genuinely pending notes are flushed.
    func flushPendingEdits() {
        let pending = pushWork.keys.sorted()
        for id in pending {
            pushWork[id]?.cancel()
            pushWork[id] = nil
            // A parked retry means Notes already failed this push. Running it
            // again here would hold quit for up to 30 s per note; the note
            // stays dirty, is cached as unsent, and goes out on next launch.
            if pushRetries[id] != nil { continue }
            guard let idx = pages.firstIndex(where: { $0.id == id }),
                  pages[idx].load == .ready
            else { continue }
            let result = Self.run(pushScript(id: id, text: pages[idx].body,
                                             titleHeading: pages[idx].titleHeading))
            // Record a confirmed write so the cache below does not mark the
            // note unsent and the next launch does not send it a second time.
            let parts = (result.out ?? "").components(separatedBy: unit)
            if result.ok, parts.first == "OK", parts.count >= 2,
               let secs = Double(parts[1]) {
                dirty.remove(id)
                modCache[id] = secs
                pages[idx].modSeconds = secs
            }
        }
        // Cache writes are debounced; make sure the last one lands before exit.
        saveCacheNow()
    }

    /// Queue a push for every note still marked unsent (restored from the
    /// cache, or left behind by failed pushes) that has no push scheduled.
    private func resendUnsent() {
        for id in dirty where pushWork[id] == nil {
            guard let page = pages.first(where: { $0.id == id }), page.load == .ready
            else { continue }
            let gen = editGeneration[id] ?? 0
            let text = page.body
            let work = DispatchWorkItem { [weak self] in
                self?.push(id: id, text: text, gen: gen)
            }
            pushWork[id] = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
        }
    }

    /// A push that did not reach Notes: say so once, keep the note dirty, and
    /// try again a few times. The retry sits in `pushWork`, so a new keystroke
    /// replaces it. Quitting does not run it again (see `flushPendingEdits`);
    /// the next launch sends it.
    private func pushFailed(id: String, text: String, gen: Int) {
        let tries = pushRetries[id] ?? 0
        guard tries < Self.maxPushRetries else {
            onToast?("Not saved to Notes", "Kept here. Type again to retry")
            return
        }
        if tries == 0 { onToast?("Couldn't save to Notes", "Kept here. Retrying") }
        pushRetries[id] = tries + 1
        let work = DispatchWorkItem { [weak self] in
            self?.push(id: id, text: text, gen: gen)
        }
        pushWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 20, execute: work)
    }

    /// A pull or body fetch failed. Toast once per run of failures.
    private func reportReadFailure() {
        guard !readFailing else { return }
        readFailing = true
        onToast?("Couldn't reach Notes", "Showing the last synced copy")
    }

    private func toastReadOnly() {
        onToast?("Read-only in the island", "This note has formatting. Edit it in Notes")
    }

    /// The AppleScript for one push. Extracted so the terminate-time flush can run
    /// the identical script synchronously.
    private func pushScript(id: String, text: String, titleHeading: Bool) -> String {
        let idEsc = Self.escapeAS(id)
        let html = Self.escapeAS(Self.htmlBody(from: text, titleHeading: titleHeading))
        // Conflict guard only when we have a cached mod date to compare against.
        let guardScript: String
        if let cached = modCache[id] {
            guardScript = """
                set secs to ((modification date of n) - refDate)
                if secs > \(cached) then
                    return "CONFLICT" & us & (secs as string) & us & (name of n) & us & (plaintext of n)
                else
                    set body of n to "\(html)"
                    set newsecs to ((modification date of n) - refDate)
                    return "OK" & us & (newsecs as string)
                end if
            """
        } else {
            guardScript = """
                set body of n to "\(html)"
                set newsecs to ((modification date of n) - refDate)
                return "OK" & us & (newsecs as string)
            """
        }
        return """
        tell application "Notes"
            set n to note id "\(idEsc)"
            \(Self.epochPrefix)
            set us to (ASCII character 31)
        \(guardScript)
        end tell
        """
    }

    private func push(id: String, text: String, gen: Int) {
        // Never write a note that is not a plain, fully loaded one (it may have
        // turned out rich, or been locked, since this push was scheduled).
        let page = pages.first(where: { $0.id == id })
        if let page, page.load != .ready || page.rich != false {
            if (editGeneration[id] ?? gen) == gen { pushWork[id] = nil; dirty.remove(id) }
            return
        }
        let script = pushScript(id: id, text: text,
                                titleHeading: page?.titleHeading ?? false)
        scriptQueue.async { [weak self] in
            guard let self else { return }
            let result = Self.run(script)
            DispatchQueue.main.async {
                // Only retire this push's own bookkeeping. If the user typed again
                // while it was in flight, `editGeneration` has moved on and there is
                // a NEWER work item under `pushWork[id]` plus a `dirty` entry that
                // still means something. Clearing them unconditionally dropped the
                // handle (so the next keystroke's `cancel()` no-opped and the
                // debounce stopped coalescing) and marked the note clean while the
                // latest text had never reached Notes — after which an incoming
                // pull would quietly overwrite it, with no conflict toast.
                let isCurrent = (self.editGeneration[id] ?? gen) == gen
                if isCurrent { self.pushWork[id] = nil }
                if self.handlePermission(result) { return }
                guard result.ok, let out = result.out else {
                    // Not sent. A newer queued edit will push on its own.
                    if isCurrent { self.pushFailed(id: id, text: text, gen: gen) }
                    return
                }
                let parts = out.components(separatedBy: self.unit)
                // Stay dirty until Notes gives a definitive answer — a failed
                // push must not let the next index pull pull the stale copy
                // back over what the user typed. And stay dirty regardless if a
                // newer edit is already queued (see above).
                if isCurrent { self.dirty.remove(id); self.pushRetries[id] = nil }
                if parts.first == "CONFLICT", parts.count >= 4 {
                    // A newer edit is still queued with the local text. Taking
                    // the Notes copy and its stamp now would let that push sail
                    // past the guard and overwrite the outside edit. Leave the
                    // stamp alone: the queued push meets the same conflict and
                    // settles it when it is the latest.
                    guard isCurrent else { return }
                    // Note changed elsewhere — pull fresh content in, don't
                    // clobber. Re-read it through the body fetch so the fresh
                    // copy is also checked for rich content before it is
                    // editable again; `modCache` moves when that read lands.
                    if let idx = self.pages.firstIndex(where: { $0.id == id }) {
                        self.pages[idx].title = parts[2]
                        self.pages[idx].body = parts[3]
                        self.pages[idx].load = .loading
                    }
                    self.saveCache()
                    self.loadBodies([id])
                    self.onToast?("Updated from Notes", "Kept the newer copy")
                } else if parts.first == "OK", parts.count >= 2 {
                    let secs = Double(parts[1]) ?? self.modCache[id] ?? 0
                    self.modCache[id] = secs
                    // Keep the page's stamp in step with the guard's, so the next
                    // index pull doesn't mistake our own write for an outside one.
                    if let idx = self.pages.firstIndex(where: { $0.id == id }) {
                        self.pages[idx].modSeconds = secs
                    }
                    self.saveCache()
                }
            }
        }
    }

    // MARK: - Permission

    /// Returns true (and reverts to Local) if the result is an Automation denial.
    private func handlePermission(_ r: ScriptResult) -> Bool {
        guard !r.ok, let err = r.err,
              err.contains("Not authorized") || err.contains("-1743") else { return false }
        mode = .local
        onPermissionDenied?()
        onToast?("Notes access denied", "Reverted to local pages")
        return true
    }

    // MARK: - Local cache (instant render; separate from local-mode notes.json)

    private static var cacheURL: URL {
        let dir = FileManager.default
            .urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Notchbook", isDirectory: true)
        try? FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        return dir.appendingPathComponent(cacheFile)
    }

    private func loadCache() {
        guard let data = try? Data(contentsOf: Self.cacheURL),
              let cached = try? JSONDecoder().decode([Page].self, from: data) else { return }
        // A page cached mid-fetch stays `.loading`. It MUST NOT be promoted to
        // `.ready` here, which is what this did before.
        //
        // `applyIndex` writes placeholders as `{body: "", modSeconds: <the note's
        // TRUE stamp>, load: .loading}` and calls `saveCache()` BEFORE the bodies
        // are fetched, so an interrupted fetch — a quit, a crash, or just
        // `loadBodies` bailing on a script error or its 30 s timeout — leaves that
        // on disk legitimately. Promoting it to `.ready` made an EMPTY body
        // indistinguishable from a fetched one: `applyIndex`'s
        // `held.load == .ready && held.modSeconds == meta.modSeconds` branch kept
        // it and never re-fetched, the editor un-greyed, and the first keystroke
        // pushed `set body of n to ""` past a conflict guard comparing the note
        // against its own matching stamp. That silently destroyed the real note,
        // on every synced device, with no toast and no undo.
        //
        // Left `.loading`, the same branch falls through to `needBody` and the
        // body is re-fetched. The old comment worried about a page stuck at
        // "opening…" forever, but nothing gets stuck: notes mode pulls on init and
        // refreshes on every expand. Momentarily showing "opening…" is the correct
        // report of the actual state, and the editor stays read-only until the
        // real body lands.
        pages = cached.map { p in
            var p = p
            // Belt and braces: a placeholder must not carry the true stamp either,
            // so it cannot match the index even if it were somehow read as ready.
            if p.load == .loading { p.modSeconds = 0 }
            // A ready page cached before bodies were inspected for rich
            // content: keep its text on screen but read it again before it can
            // be edited.
            if p.load == .ready, p.rich == nil { p.load = .loading; p.modSeconds = 0 }
            return p
        }
        modCache = Dictionary(pages.filter { $0.load == .ready }
            .map { ($0.id, $0.modSeconds) }, uniquingKeysWith: { a, _ in a })
        // Edits Notes never confirmed stay dirty, so a pull cannot replace them
        // and `resendUnsent` sends them (behind the usual conflict guard).
        dirty = Set(pages.filter { $0.unsent && $0.load == .ready }.map(\.id))
    }

    /// Debounced: this is called on every keystroke, and encoding every backed
    /// body plus an atomic write on the main thread made typing stutter.
    private func saveCache() {
        cacheWork?.cancel()
        let work = DispatchWorkItem { [weak self] in
            guard let self else { return }
            let snapshot = self.cacheSnapshot()
            let url = Self.cacheURL
            self.cacheQueue.async { Self.writeCache(snapshot, to: url) }
        }
        cacheWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
    }

    /// Write the cache before returning (quit path). Goes through the same
    /// queue so it lands after any write already under way.
    private func saveCacheNow() {
        cacheWork?.cancel()
        cacheWork = nil
        let snapshot = cacheSnapshot()
        let url = Self.cacheURL
        cacheQueue.sync { Self.writeCache(snapshot, to: url) }
    }

    /// `pages` with each one marked unsent if its edit is still unconfirmed.
    private func cacheSnapshot() -> [Page] {
        pages.map { p in
            var p = p
            p.unsent = dirty.contains(p.id)
            return p
        }
    }

    private static func writeCache(_ pages: [Page], to url: URL) {
        if let data = try? JSONEncoder().encode(pages) {
            try? data.write(to: url, options: .atomic)
        }
    }

    // MARK: - Script helpers

    private struct ScriptResult { let out: String?; let err: String?; let ok: Bool }

    /// Builds a 1970 reference date so `(modification date - refDate)` yields
    /// seconds. It's local-time based (off by the TZ offset from true epoch) but
    /// CONSISTENT across reads, which is all conflict detection and ordering need.
    private static let epochPrefix = """
        set refDate to current date
        set year of refDate to 1970
        set month of refDate to January
        set day of refDate to 1
        set time of refDate to 0
        """

    /// "Now" in the same local-epoch frame the scripts report, so relative dates
    /// ("2d") can be computed without a second Apple Event.
    static var nowSeconds: Double {
        Date().timeIntervalSince1970 + Double(TimeZone.current.secondsFromGMT())
    }

    /// Notes body is HTML: escape entities, one `<div>` per line (blank →
    /// `<div><br></div>`). The first line becomes the note's title automatically.
    /// With `titleHeading`, the first line keeps the title style it had in Notes.
    static func htmlBody(from text: String, titleHeading: Bool = false) -> String {
        text.components(separatedBy: "\n").enumerated().map { index, line in
            if line.isEmpty { return "<div><br></div>" }
            let esc = line
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            if titleHeading, index == 0 { return "<div><h1>\(esc)</h1></div>" }
            return "<div>\(esc)</div>"
        }.joined()
    }

    /// One tag found in a note's HTML body.
    private struct HTMLTag {
        let name: String        // lowercased
        let closing: Bool
        let attrs: String       // empty when the tag has no attributes
        let start: String.Index
    }

    private static func tags(in html: String) -> [HTMLTag] {
        guard let re = try? NSRegularExpression(
            pattern: "<\\s*(/?)\\s*([A-Za-z][A-Za-z0-9]*)([^>]*)>")
        else { return [] }
        let ns = html as NSString
        var out: [HTMLTag] = []
        for m in re.matches(in: html, range: NSRange(location: 0, length: ns.length)) {
            guard let r = Range(m.range, in: html) else { continue }
            let attrs = ns.substring(with: m.range(at: 3))
                .trimmingCharacters(in: CharacterSet(charactersIn: "/")
                    .union(.whitespacesAndNewlines))
            out.append(HTMLTag(name: ns.substring(with: m.range(at: 2)).lowercased(),
                               closing: ns.substring(with: m.range(at: 1)) == "/",
                               attrs: attrs,
                               start: r.lowerBound))
        }
        return out
    }

    /// The one `<h1>` Notes puts on a plain note's title line: a single h1
    /// with nothing but empty wrappers before it.
    static func hasTitleHeading(html: String) -> Bool {
        let all = tags(in: html)
        let opens = all.filter { $0.name == "h1" && !$0.closing }
        guard opens.count == 1, let h1 = opens.first else { return false }
        // Text before the heading means it is not the title line.
        let before = String(html[html.startIndex..<h1.start])
        guard let re = try? NSRegularExpression(pattern: "<[^>]*>") else { return false }
        let text = re.stringByReplacingMatches(
            in: before, range: NSRange(location: 0, length: (before as NSString).length),
            withTemplate: "")
        return text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }

    /// True when a note's HTML body holds anything a plain-text push would
    /// lose. Plain means: only `<div>` and `<br>` tags with no attributes,
    /// plus at most the one title `<h1>`. Any other tag (lists and checklists,
    /// links, images, objects, tables, bold/italic, spans, fonts, other
    /// headings), any attribute such as a style, or an unreadable body counts
    /// as rich. Unknown markup is treated as rich on purpose.
    static func isRichNote(html: String) -> Bool {
        let all = tags(in: html)
        // A body with text but no tags at all is not a shape Notes produces.
        if all.isEmpty { return !html.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty }
        var sawHeading = false
        for tag in all {
            if !tag.attrs.isEmpty { return true }
            switch tag.name {
            case "div", "br": continue
            case "h1": sawHeading = true
            default: return true
            }
        }
        return sawHeading && !hasTitleHeading(html: html)
    }

    /// Escape a Swift string for embedding inside an AppleScript double-quoted
    /// literal: backslashes first, then quotes.
    static func escapeAS(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func run(_ source: String) -> ScriptResult {
        // Draining before waiting (which this already did) fixes the stdout
        // deadlock, but the two reads were sequential: >64 KiB on stderr while
        // stdout was still being drained wedged both sides permanently, and a
        // wedged script blocks the serial scriptQueue for the rest of the run.
        // Subprocess drains both concurrently and bounds the wait.
        let r = Subprocess.osascript(source, timeout: 30)
        let out = r.out.trimmingCharacters(in: .whitespacesAndNewlines)
        let err = r.timedOut
            ? "Notes did not respond within 30s"
            : r.err.trimmingCharacters(in: .whitespacesAndNewlines)
        return ScriptResult(out: out.isEmpty ? nil : out,
                            err: err.isEmpty ? nil : err,
                            ok: r.ok)
    }
}
