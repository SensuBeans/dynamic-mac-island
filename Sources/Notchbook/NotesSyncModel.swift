import AppKit
import Combine

/// Two-way sync between the Notes tab and ONE dedicated Apple Notes folder.
///
/// Every script runs as a spawned `osascript` on a background queue — never
/// `NSAppleScript` (main-thread-only) and never on the main thread. The model
/// only ever touches notes inside its folder, so it structurally cannot clobber
/// the user's other notes. Notes are tracked by their stable AppleScript `id`
/// (an `x-coredata://` URL), never by name or index.
///
/// Conflict rule: freshest-writer-wins. Before pushing an edit we re-read the
/// note's modification date; if it changed in Notes.app/iPhone since our last
/// pull, we DO NOT push — we pull the fresh content and toast the user.
final class NotesSyncModel: ObservableObject {
    struct Page: Identifiable, Equatable, Codable {
        let id: String          // AppleScript note id (x-coredata:// URL)
        var title: String       // note title (first line)
        var body: String        // plaintext
        var modSeconds: Double   // local-epoch seconds (consistent, not absolute)
    }

    enum Mode: String { case local, notes }

    @Published var mode: Mode {
        didSet { UserDefaults.standard.set(mode.rawValue, forKey: Self.modeKey) }
    }
    @Published var folderName: String {
        didSet { UserDefaults.standard.set(folderName, forKey: Self.folderKey) }
    }
    @Published private(set) var pages: [Page] = []
    @Published private(set) var syncing = false

    /// Set by the app: shows a transient island toast (title, subtitle).
    var onToast: ((String, String) -> Void)?
    /// Called on the main thread when Automation permission for Notes is denied.
    var onPermissionDenied: (() -> Void)?

    private static let modeKey = "notesSyncMode"
    private static let folderKey = "notesSyncFolder"
    private static let cacheFile = "notes-sync-cache.json"

    private let scriptQueue = DispatchQueue(label: "com.sensubeans.notchbook.notes",
                                            qos: .userInitiated)
    /// Per-note debounce so rapid typing coalesces into one push.
    private var pushWork: [String: DispatchWorkItem] = [:]
    /// id → modification seconds at last pull, for conflict detection.
    private var modCache: [String: Double] = [:]

    private let unit = "\u{1F}"   // field separator
    private let record = "\u{1E}" // record separator

    init() {
        mode = Mode(rawValue: UserDefaults.standard.string(forKey: Self.modeKey) ?? "")
            ?? .local
        folderName = UserDefaults.standard.string(forKey: Self.folderKey) ?? "Notchbook"
        loadCache()   // instant render from the last-synced snapshot
        if mode == .notes { pull() }
    }

    // MARK: - Mode

    func setMode(_ newMode: Mode) {
        guard newMode != mode else { return }
        mode = newMode
        if newMode == .notes { pull() }
    }

    // MARK: - Pull (read the whole folder)

    /// Called on tab open / panel expand while in Apple Notes mode.
    func refresh() { guard mode == .notes else { return }; pull() }

    func pull() {
        let f = Self.escapeAS(folderName)
        let script = """
        tell application "Notes"
            if not (exists folder "\(f)") then make new folder with properties {name:"\(f)"}
            \(Self.epochPrefix)
            set us to (ASCII character 31)
            set rs to (ASCII character 30)
            set out to ""
            repeat with n in notes of folder "\(f)"
                set secs to ((modification date of n) - refDate)
                set out to out & (id of n) & us & (secs as string) & us & (name of n) & us & (plaintext of n) & rs
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
                if self.handlePermission(result) { return }
                guard result.ok else { return }
                let parsed = self.parsePull(result.out ?? "")
                self.modCache = Dictionary(uniqueKeysWithValues:
                    parsed.map { ($0.id, $0.modSeconds) })
                self.pages = parsed.sorted { $0.modSeconds > $1.modSeconds }.prefix(9).map { $0 }
                self.saveCache()
            }
        }
    }

    private func parsePull(_ raw: String) -> [Page] {
        raw.components(separatedBy: record).compactMap { rec in
            guard !rec.isEmpty else { return nil }
            let parts = rec.components(separatedBy: unit)
            guard parts.count >= 4 else { return nil }
            let id = parts[0]
            let secs = Double(parts[1]) ?? 0
            let name = parts[2]
            let plain = parts[3]
            return Page(id: id, title: name, body: plain, modSeconds: secs)
        }
    }

    // MARK: - Create

    func createNote(completion: (() -> Void)? = nil) {
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
                self.pull()
                completion?()
            }
        }
    }

    // MARK: - Edit / push

    /// Optimistically update the local page and schedule a debounced push.
    func edit(id: String, text: String) {
        guard let idx = pages.firstIndex(where: { $0.id == id }) else { return }
        pages[idx].body = text
        pages[idx].title = text.components(separatedBy: "\n").first ?? ""
        saveCache()

        pushWork[id]?.cancel()
        let work = DispatchWorkItem { [weak self] in self?.push(id: id, text: text) }
        pushWork[id] = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 2, execute: work)
    }

    private func push(id: String, text: String) {
        let idEsc = Self.escapeAS(id)
        let html = Self.escapeAS(Self.htmlBody(from: text))
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
        let script = """
        tell application "Notes"
            set n to note id "\(idEsc)"
            \(Self.epochPrefix)
            set us to (ASCII character 31)
        \(guardScript)
        end tell
        """
        scriptQueue.async { [weak self] in
            guard let self else { return }
            let result = Self.run(script)
            DispatchQueue.main.async {
                if self.handlePermission(result) { return }
                guard result.ok, let out = result.out else { return }
                let parts = out.components(separatedBy: self.unit)
                if parts.first == "CONFLICT", parts.count >= 4 {
                    // Note changed elsewhere — pull fresh content in, don't clobber.
                    let secs = Double(parts[1]) ?? 0
                    if let idx = self.pages.firstIndex(where: { $0.id == id }) {
                        self.pages[idx].title = parts[2]
                        self.pages[idx].body = parts[3]
                        self.pages[idx].modSeconds = secs
                    }
                    self.modCache[id] = secs
                    self.saveCache()
                    self.onToast?("Updated from Notes", "Kept the newer copy")
                } else if parts.first == "OK", parts.count >= 2 {
                    self.modCache[id] = Double(parts[1]) ?? self.modCache[id] ?? 0
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
        pages = cached
        modCache = Dictionary(uniqueKeysWithValues: cached.map { ($0.id, $0.modSeconds) })
    }

    private func saveCache() {
        if let data = try? JSONEncoder().encode(pages) {
            try? data.write(to: Self.cacheURL, options: .atomic)
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

    /// Notes body is HTML: escape entities, one `<div>` per line (blank →
    /// `<div><br></div>`). The first line becomes the note's title automatically.
    static func htmlBody(from text: String) -> String {
        text.components(separatedBy: "\n").map { line in
            if line.isEmpty { return "<div><br></div>" }
            let esc = line
                .replacingOccurrences(of: "&", with: "&amp;")
                .replacingOccurrences(of: "<", with: "&lt;")
                .replacingOccurrences(of: ">", with: "&gt;")
            return "<div>\(esc)</div>"
        }.joined()
    }

    /// Escape a Swift string for embedding inside an AppleScript double-quoted
    /// literal: backslashes first, then quotes.
    static func escapeAS(_ s: String) -> String {
        s.replacingOccurrences(of: "\\", with: "\\\\")
         .replacingOccurrences(of: "\"", with: "\\\"")
    }

    private static func run(_ source: String) -> ScriptResult {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/osascript")
        p.arguments = ["-e", source]
        let o = Pipe(), e = Pipe()
        p.standardOutput = o
        p.standardError = e
        do { try p.run() } catch { return ScriptResult(out: nil, err: "\(error)", ok: false) }
        p.waitUntilExit()
        let out = String(data: o.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        let err = String(data: e.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return ScriptResult(out: (out?.isEmpty ?? true) ? nil : out,
                            err: (err?.isEmpty ?? true) ? nil : err,
                            ok: p.terminationStatus == 0)
    }
}
