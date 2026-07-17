import Foundation
import Combine
import SwiftUI
import CoreServices

/// Watches every Claude Code transcript under `~/.claude/projects` and derives a
/// live `AgentSession` per running session — zero config, pure transcript
/// tailing. Everything expensive (FSEvents, stat, byte-offset reads, JSON) runs
/// on `ioQueue`; only the two `@Published` mirrors and `onTransition` toasts
/// ever touch the main thread.
///
/// Why a poll timer AND FSEvents: FSEvents makes appends land fast, but some
/// states are *time* transitions with no file write behind them — a session
/// stops being `.working` after 10 s of quiet, and a live session drops off the
/// list after 30 min of no message activity. A ~1.5 s timer re-evaluates the
/// clock (over the already-tracked parsers, no directory walk) so those fire
/// even when nothing is being written.
///
/// `.waiting` (needs a human) is NOT derived here — without hooks the transcript
/// can't reliably tell "asking a question" from "just finished". The resting
/// state after a turn is `.complete` (green, your move). `.waiting` is reserved
/// for the Phase C hook enhancer, which sees permission prompts directly.

// MARK: - Public model types

enum AgentState {
    case working, complete, interrupted, idle, waiting

    /// SF Symbol for the row's state glyph.
    var glyph: String {
        switch self {
        case .working:     return "circle.fill"
        case .complete:    return "checkmark.circle.fill"
        case .interrupted: return "stop.circle.fill"
        case .idle:        return "moon.zzz.fill"
        case .waiting:     return "exclamationmark.triangle.fill"
        }
    }

    var tint: Color {
        switch self {
        case .working:     return .blue
        case .complete:    return .green
        case .interrupted: return .gray
        case .idle:        return .secondary
        case .waiting:     return .orange
        }
    }

    var label: String {
        switch self {
        case .working:     return "Working"
        case .complete:    return "Done"
        case .interrupted: return "Interrupted"
        case .idle:        return "Idle"
        case .waiting:     return "Waiting"
        }
    }

    /// Grouping order for the sessions list: needs-attention first, then busy,
    /// then recently-finished, then dim/idle.
    var sortRank: Int {
        switch self {
        case .waiting, .interrupted: return 0
        case .working:               return 1
        case .complete:              return 2
        case .idle:                  return 3
        }
    }
}

struct AgentSession: Identifiable {
    let id: String            // sessionId (filename stem fallback)
    var project: String       // cwd basename
    var gitBranch: String?    // nil if "HEAD"/empty
    var modelDisplay: String  // "Opus 4.8","Fable","Sonnet","Haiku 4.5", or raw id
    var state: AgentState
    var stateSince: Date
    var lastActivity: Date
    var contextTokens: Int    // latest assistant usage: input + cache_read + cache_creation
    var contextWindow: Int?   // nil => render raw tokens, no percent
    var outputTokens: Int     // running sum across assistant entries
    var messageCount: Int
    var cwd: String           // full path (for jump-back)
    var tty: String?          // controlling tty, short form ("ttys003"); nil if headless
    var host: TerminalHost    // where the session's terminal lives (drives actions)
    var pid: Int?             // Claude Code process pid (from ~/.claude/sessions)
    var name: String?         // friendly session name ("core-00")
    var autoResumeAt: Date?   // armed auto-resume fire time (nil = not armed / notify-only)

    /// A session parked waiting for the user (a permission prompt or the end of
    /// a turn) — the states the notch offers an Approve / Open action for.
    var needsAttention: Bool { state == .waiting || state == .interrupted }
}

/// Live status Claude Code publishes per running process in
/// `~/.claude/sessions/<pid>.json`. Authoritative for busy/waiting/idle in a way
/// transcript tailing can't be (it sees permission prompts, which never reach
/// the JSONL until answered).
private struct SessionMeta {
    var pid: Int
    var name: String?
    var status: String   // "busy" | "waiting" | "idle"
    var cwd: String
}

/// Account-wide Claude usage limits (the 5-hour rolling "session" window and the
/// weekly window), captured from the statusline's stdin payload — the only place
/// Claude Code surfaces `rate_limits`. Percent is 0…100 used; `resetsAt` is when
/// that window rolls over.
struct AgentUsage: Equatable {
    var sessionPct: Int?
    var sessionResetsAt: Date?
    var weeklyPct: Int?
    var weeklyResetsAt: Date?

    var isEmpty: Bool { sessionPct == nil && weeklyPct == nil }
}

final class AgentSessionsModel: ObservableObject {

    /// Ordered: needs-attention (waiting/interrupted), then working, then recent
    /// complete, then idle; most-recent activity first within a group.
    @Published private(set) var sessions: [AgentSession] = []

    /// Account usage limits shown at the top of the Agents tab. `nil` until the
    /// statusline has written the spool file at least once (non-subscribers or a
    /// fresh install never populate it — the header then stays hidden).
    @Published private(set) var usage: AgentUsage?

    /// Additive convenience for the collapsed ear pill: how many `.complete`
    /// sessions the user has NOT yet seen (cleared by `acknowledgeCompletes`).
    /// Not in the original contract — the pill's "✓ N" needs an ack-aware count,
    /// and the fixed `AgentSession` struct has no per-row ack field to carry it.
    @Published private(set) var unacknowledgedCompleteCount: Int = 0

    /// Collapsed ear-pill descriptor for the notch, by priority: any `.waiting`
    /// (needs a human) beats any `.working` beats a recently-`.complete` run
    /// (finished within `completePillWindow`). `nil` => no pill, so the bar stays
    /// hidden. Single source of truth so the pill's drawing (NotchView.agentEar),
    /// the collapsed island width (three sites) and AppDelegate.islandRect all
    /// agree on WHEN — and thus how wide — the pill is. Additive convenience,
    /// like `unacknowledgedCompleteCount`.
    enum CollapsedPill: Equatable {
        case waiting(Int), working(Int), complete(Int)
    }

    var collapsedPill: CollapsedPill? {
        var waiting = 0, working = 0
        for s in sessions {
            switch s.state {
            case .waiting: waiting += 1
            case .working: working += 1
            default: break
            }
        }
        if waiting > 0 { return .waiting(waiting) }
        if working > 0 { return .working(working) }
        // Recent, still-unacknowledged completes (see `updateAckCount`: recency
        // < completePillWindow AND not yet seen). Viewing the Agents tab clears this, so the
        // green "✓ N" pill actually goes away — the ack machinery now drives it.
        if unacknowledgedCompleteCount > 0 { return .complete(unacknowledgedCompleteCount) }
        return nil
    }

    /// Does the collapsed pill have anything to show? Gates the collapsed
    /// island's width + visibility, mirroring `mediaEarWidth`'s role.
    var hasActivePill: Bool { collapsedPill != nil }

    /// Fired on the MAIN queue on debounced per-session state changes.
    /// Arguments: (session carrying the NEW state, the OLD state).
    var onTransition: ((AgentSession, AgentState) -> Void)?

    /// Injected by AppDelegate: the island's own built-in Terminal-tab shells as
    /// `(sessionID, shellPid)`. Lets terminal-identity resolution recognize a
    /// Claude session hosted inside the notch and match its exact tab. Called on
    /// `ioQueue`, so AppDelegate must return a thread-safe snapshot (the model
    /// has no reference to `TerminalSessionsModel`, matching the callback idiom
    /// of `onTransition`). Default: no built-in shells.
    var builtinShellPids: () -> [(UUID, Int32)] = { [] }

    /// Injected by AppDelegate: is auto-resume enabled (the Agents settings
    /// toggle)? Read on `ioQueue`; AppDelegate returns a lock-guarded snapshot.
    /// Default ON so the detector runs if never wired.
    var autoResumeEnabled: () -> Bool = { true }

    /// Injected: fire an auto-resume into the island's own built-in terminal
    /// session (host `.notch`). Runs on MAIN (touches `TerminalSessionsModel`).
    var onNotchResume: ((UUID) -> Void)?

    /// Injected: an auto-resume fired. `notify == false` ⇒ resume was injected
    /// (green toast, no sound); `notify == true` ⇒ notify-only host or a
    /// Terminal.app tab that vanished (orange toast + Glass). Called on MAIN.
    var onResumeFired: ((_ project: String, _ name: String?, _ notify: Bool) -> Void)?

    // MARK: State constants (spec §2, tunable)

    private let workingWindow: TimeInterval = 10      // fresh message => working
    private let idleMin:       TimeInterval = 5 * 60  // dim row (user-prompt-last, quiet)
    private let idleMax:       TimeInterval = 30 * 60 // drop from the live list
    /// How long the collapsed green "✓ N" complete pill lingers after a turn
    /// finishes. Deliberately SHORT and independent of `idleMin`: `.complete`
    /// re-fires on every finished turn, so a 5-min window kept the pill
    /// perpetually re-lit while you work — it read as permanently "stuck". A
    /// brief window makes it blip on completion, then fade. (Row/idle dimming in
    /// the expanded tab is unchanged — that's still `idleMin`.)
    private let completePillWindow: TimeInterval = 30

    // MARK: Threading

    /// Single serial queue owns ALL mutable parsing state (`parsers`,
    /// `acknowledgedCompleteIDs`, publish throttle). Confinement, not locks.
    private let ioQueue = DispatchQueue(label: "com.sensubeans.notchbook.agents",
                                        qos: .utility)
    /// User-initiated terminal control (focus/approve) — kept off `ioQueue` and
    /// off main so an AppleScript round-trip never stalls parsing or the UI.
    private let controlQueue = DispatchQueue(label: "com.sensubeans.notchbook.agents.control",
                                             qos: .userInitiated)

    private let projectsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/projects", isDirectory: true)

    /// Spool file the statusline writes account usage to (see statusline-command.sh).
    /// A `NOTCHBOOK_USAGE_OVERRIDE` env path redirects it — the only way to
    /// exercise auto-resume without waiting on a real 5-hour cap; unset in normal
    /// runs, so release behavior is unchanged.
    private let usageURL: URL = {
        if let override = ProcessInfo.processInfo.environment["NOTCHBOOK_USAGE_OVERRIDE"],
           !override.isEmpty {
            return URL(fileURLWithPath: override)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/Notchbook/usage.json")
    }()
    private var lastUsage: AgentUsage?

    /// Directory of per-process live-status files (`<pid>.json`).
    private let sessionsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent(".claude/sessions", isDirectory: true)

    /// Per-session live-model spool the statusline writes (`models/<sid>.json`
    /// with `{id, display}`). Claude Code's session file carries NO model, and
    /// the transcript only records the previous turn's model — so it lags a
    /// `/model` switch and can't show the current selection before the next
    /// turn lands. This spool is the authoritative live model (updated on every
    /// statusline render). Absent when the statusline isn't the notch-aware one
    /// — then we fall back to the transcript model.
    private let modelsURL = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Notchbook/models", isDirectory: true)
    /// Throttle for pruning stale model-spool files (once every few minutes).
    private var lastModelPrune = Date.distantPast

    /// path -> incremental parser state. Touched only on `ioQueue`.
    private var parsers: [String: FileParser] = [:]
    /// sessionId -> current state + when it entered that state. Keyed by session,
    /// NOT by transcript, so a brand-new terminal with no transcript yet still
    /// tracks state/transitions. Touched only on `ioQueue`.
    private var sessionStates: [String: (state: AgentState, since: Date)] = [:]
    /// Complete sessions the user has acknowledged. Touched only on `ioQueue`.
    private var acknowledgedCompleteIDs: Set<String> = []
    /// Resolved terminal identity per live pid — tty and process ancestry never
    /// change for a live pid, so resolve once (a few syscalls) and reuse on every
    /// 1.5 s tick. Guarded by the sessionId it was resolved for, so a recycled pid
    /// (old process died, new session reused the number) re-resolves fresh.
    /// Pruned to currently-live pids each rebuild. Touched only on `ioQueue`.
    private var identityCache: [Int32: (sid: String, identity: TerminalIdentity)] = [:]
    /// This app's pid, for spotting sessions hosted in the island's own terminal.
    private let selfPid = getpid()

    // MARK: Auto-resume (arming + firing; ioQueue only)

    private enum ResumeMode { case inject, notifyOnly }

    /// A session armed to auto-resume at `resetAt`. Captured at arm time so the
    /// fire-time guards can prove nothing moved since (a manual resume advances
    /// `armedEntryTs`; the tab/host must still resolve the same).
    private struct ArmedResume {
        let sessionId: String
        let pid: Int
        let resetAt: Date
        let armedEntryTs: Date?
        let tty: String?
        let host: TerminalHost
        let mode: ResumeMode
    }

    /// Inputs collected per session during the rebuild loop, then evaluated for
    /// arming after `readUsage()` has refreshed the cap state.
    private struct ResumeCandidate {
        let id: String
        let pid: Int?
        let host: TerminalHost
        let tty: String?
        let newestEntryTs: Date?
        let midTurn: Bool     // assistant last, stop_reason != end_turn (raw parser)
        let status: String?   // process status from the session meta
    }

    /// Currently-armed sessions, keyed by sessionId. Touched only on `ioQueue`.
    private var armedResumes: [String: ArmedResume] = [:]
    /// Consumed `(sessionId, resetAt)` epochs — a fired/cancelled arm never
    /// re-arms for the same reset window (the usage file still reads 100% after
    /// the window reopens and must not re-trigger). Touched only on `ioQueue`.
    private var consumedEpochs: Set<String> = []
    /// The one wall-clock timer that fires due resumes, + its current deadline.
    private var resumeTimer: DispatchSourceTimer?
    private var resumeTimerDeadline: Date?
    /// Grace after a window's `resetsAt` before firing — lets the account limit
    /// actually clear server-side before we type `continue`.
    private let resumeGrace: TimeInterval = 5

    private var stream: FSEventStreamRef?
    private var timer: DispatchSourceTimer?

    // Publish throttle (<= 2 Hz), all on `ioQueue`.
    private var pendingPublish: [AgentSession]?
    private var lastPublish = Date.distantPast
    private var publishScheduled = false
    /// Last value pushed to `unacknowledgedCompleteCount` — publish only on a
    /// real change so a fast-appending transcript can't storm SwiftUI with
    /// no-op `objectWillChange` for a count that never moved.
    private var lastAckCount = -1

    // MARK: - Lifecycle

    func start() {
        ioQueue.async { [weak self] in self?.scan() }   // immediate initial scan
        startFSEvents()
        startTimer()
    }

    func shutdown() {
        stopFSEvents()
        timer?.cancel()
        timer = nil
        resumeTimer?.cancel()
        resumeTimer = nil
    }

    /// Raise the Terminal.app tab running this session (host `.terminalApp`;
    /// `.notch`/`.other` are routed in the view). Off-main — AppleScript
    /// round-trips can take a beat. Reuses the already-resolved tty, falling back
    /// to a `ps` lookup only when it's nil. `missed(true)` on the main queue when
    /// the tab couldn't be found, so the caller can surface a toast.
    func focus(_ session: AgentSession, missed: @escaping (Bool) -> Void = { _ in }) {
        guard let pid = session.pid else { missed(false); return }
        let ttyPath = session.tty.map { "/dev/\($0)" }
        controlQueue.async {
            let outcome = AgentTerminalControl.focus(pid: pid, ttyPath: ttyPath)
            DispatchQueue.main.async { missed(outcome == .notFound) }
        }
    }

    /// Accept the session's pending permission prompt by sending Return to its
    /// Terminal.app tab (host `.terminalApp`). `missed(true)` when the tab is gone.
    func approve(_ session: AgentSession, missed: @escaping (Bool) -> Void = { _ in }) {
        guard let pid = session.pid else { missed(false); return }
        let ttyPath = session.tty.map { "/dev/\($0)" }
        controlQueue.async {
            let outcome = AgentTerminalControl.approve(pid: pid, ttyPath: ttyPath)
            DispatchQueue.main.async { missed(outcome == .notFound) }
        }
    }

    /// Called when the Agents tab is viewed — clears the "recent complete"
    /// highlight so the ear pill stops flagging finished runs the user has seen.
    func acknowledgeCompletes() {
        ioQueue.async { [weak self] in
            guard let self else { return }
            let completeIDs = Set(self.sessionStates
                .filter { $0.value.state == .complete }
                .map { $0.key })
            self.acknowledgedCompleteIDs.formUnion(completeIDs)
            self.lastAckCount = 0
            DispatchQueue.main.async { self.unacknowledgedCompleteCount = 0 }
        }
    }

    // MARK: - FSEvents

    /// C callback carries no capture — it hops back to the instance through the
    /// `info` pointer, then does the scan on the queue FSEvents delivers on.
    private static let fsCallback: FSEventStreamCallback = { _, info, _, eventPaths, _, _ in
        guard let info else { return }
        let model = Unmanaged<AgentSessionsModel>.fromOpaque(info).takeUnretainedValue()
        // Ingest ONLY the paths that changed (file-level events) rather than
        // re-walking the whole projects tree on every write burst — that walk
        // was the app's steady-state CPU cost while sessions stream.
        let paths = (Unmanaged<CFArray>.fromOpaque(eventPaths).takeUnretainedValue()
                     as? [String]) ?? []
        model.ingestChanged(paths)   // already on ioQueue (FSEventStreamSetDispatchQueue)
    }

    private func startFSEvents() {
        // passUnretained: the app delegate owns us for the process lifetime, so
        // FSEvents must not add a retain (it would outlive shutdown otherwise).
        var ctx = FSEventStreamContext(version: 0,
                                       info: Unmanaged.passUnretained(self).toOpaque(),
                                       retain: nil, release: nil, copyDescription: nil)
        // UseCFTypes: the callback's eventPaths arrives as a CFArray of CFString
        // so we can read exactly which files changed.
        let flags = UInt32(kFSEventStreamCreateFlagFileEvents |
                           kFSEventStreamCreateFlagNoDefer |
                           kFSEventStreamCreateFlagUseCFTypes)
        guard let s = FSEventStreamCreate(kCFAllocatorDefault,
                                          Self.fsCallback,
                                          &ctx,
                                          [projectsURL.path] as CFArray,
                                          FSEventStreamEventId(kFSEventStreamEventIdSinceNow),
                                          0.3,     // coalesce bursts
                                          flags) else { return }
        FSEventStreamSetDispatchQueue(s, ioQueue)
        guard FSEventStreamStart(s) else {
            // Start failed — no events will arrive; the 1.5 s timer still keeps
            // known sessions' clocks moving. Don't retain a dead stream.
            FSEventStreamInvalidate(s)
            FSEventStreamRelease(s)
            return
        }
        stream = s
    }

    private func stopFSEvents() {
        guard let s = stream else { return }
        FSEventStreamStop(s)
        FSEventStreamInvalidate(s)
        FSEventStreamRelease(s)
        stream = nil
    }

    private func startTimer() {
        let t = DispatchSource.makeTimerSource(queue: ioQueue)
        t.schedule(deadline: .now() + 1.5, repeating: 1.5)
        // Timer only re-evaluates the clock over already-tracked parsers — no
        // directory walk / stat storm. Directory discovery is FSEvents-driven.
        t.setEventHandler { [weak self] in self?.rebuild() }
        t.resume()
        timer = t
    }

    // MARK: - Scan (ioQueue only)

    /// One-shot full walk at launch: discover every live transcript, then hand
    /// off to `rebuild()`. Ongoing discovery + appends come from FSEvents
    /// (`ingestChanged`), which reports file creates too, so this never repeats.
    private func scan() {
        let now = Date()
        for path in jsonlFiles() { processFile(path, now: now) }
        rebuild()
    }

    /// FSEvents delivered these paths — adopt/ingest just them (no tree walk).
    private func ingestChanged(_ paths: [String]) {
        let now = Date()
        for path in paths where path.hasSuffix(".jsonl") { processFile(path, now: now) }
        rebuild()
    }

    /// Adopt a new live file or read a known file's appended bytes.
    private func processFile(_ path: String, now: Date) {
        guard let attrs = try? FileManager.default.attributesOfItem(atPath: path) else { return }
        let size = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let mtime = (attrs[.modificationDate] as? Date) ?? now

        var parser = parsers[path]
        if parser == nil {
            // New file: adopt only if live (ignore transcripts already past the
            // drop threshold — an old file touched by a stray write stays out).
            guard now.timeIntervalSince(mtime) < idleMax else { return }
            let p = FileParser(path: path, now: now)
            parsers[path] = p
            parser = p
        }
        guard let p = parser else { return }
        if size < p.byteOffset { p.reset(now: now) }   // truncation/rotation
        if size > p.byteOffset { ingest(into: p) }
    }

    /// Rebuild the session list. TERMINAL-DRIVEN: a row exists iff a running
    /// Claude Code process does (a `~/.claude/sessions/<pid>.json` with a live
    /// pid) — shown until its terminal closes, no matter how long it sits idle.
    /// This page is a hub that tracks OPEN terminals: when a terminal closes,
    /// Claude deletes its session file, so the row drops on the next tick. A
    /// lingering recent transcript never resurrects a closed session. Transcripts
    /// only enrich (model, context, tokens, interrupt). No file IO beyond the tiny
    /// session/usage files; runs from FSEvents and the 1.5 s timer.
    private func rebuild() {
        let now = Date()
        let metas = readSessionMetas()   // live terminals only, by sessionId

        // Drop identity-cache entries for pids no longer live (keyed by pid, so a
        // recycled pid is also caught by the sessionId guard in resolveIdentity).
        let livePids = Set(metas.values.map { Int32($0.pid) })
        identityCache = identityCache.filter { livePids.contains($0.key) }

        // Drop parsers whose transcript file vanished.
        for (path, _) in parsers where !FileManager.default.fileExists(atPath: path) {
            parsers.removeValue(forKey: path)
        }
        // Index transcripts by sessionId (most-recently-active wins on the rare
        // collision), so each session finds its enrichment.
        var parserByID: [String: FileParser] = [:]
        for p in parsers.values where !p.id.isEmpty && p.messageCount > 0 {
            if let existing = parserByID[p.id],
               (existing.newestEntryTs ?? .distantPast) >= (p.newestEntryTs ?? .distantPast) {
                continue
            }
            parserByID[p.id] = p
        }

        // TERMINAL-DRIVEN: a row exists iff there's a LIVE session file (a running
        // Claude process). A closed terminal deletes its `<pid>.json` on exit — no
        // live file ⇒ no row, dropped on the very next tick. We deliberately do NOT
        // resurrect a session from a lingering recent transcript: that fallback let
        // just-closed terminals hang around as stale "idle" remnants. Transcripts
        // still ENRICH live sessions (model/context/tokens/interrupt) via parserByID.
        let ids = Set(metas.keys)

        var built: [(session: AgentSession, old: AgentState?)] = []
        var liveIDs = Set<String>()
        var resumeCandidates: [ResumeCandidate] = []

        for id in ids {
            guard let meta = metas[id] else { continue }   // live session file required
            let p = parserByID[id]
            let lastActivity = p?.newestEntryTs
            let age = lastActivity.map { now.timeIntervalSince($0) } ?? .infinity
            liveIDs.insert(id)

            let base = p.map { classify($0, age: age) } ?? .idle
            let resolved = resolveState(base: base, meta: meta, hasTranscript: p != nil)

            // Transition tracking keyed by session (survives having no transcript).
            let prev = sessionStates[id]
            if prev == nil {
                // Anchor stateSince to the real last-activity instant so a relaunch
                // doesn't replay a long-finished run as a "just now" complete.
                sessionStates[id] = (resolved, lastActivity.map { min(now, $0) } ?? now)
            } else if prev!.state != resolved {
                sessionStates[id] = (resolved, now)
            }
            let since = sessionStates[id]!.since

            let identity = resolveIdentity(pid: meta.pid, sid: id)
            built.append((makeSession(id: id, parser: p, meta: meta, identity: identity,
                                      state: resolved, since: since,
                                      lastActivity: lastActivity ?? since),
                          prev?.state))

            // Auto-resume detection uses RAW parser flags (mid-turn = assistant
            // last, not end_turn), never the resolved UI state which the process
            // fold drifts to idle/waiting once a session is capped.
            let midTurn = (p?.lastMsgIsAssistant ?? false) && (p?.lastMsgStopReason != "end_turn")
            resumeCandidates.append(ResumeCandidate(
                id: id, pid: meta.pid, host: identity.host, tty: identity.tty,
                newestEntryTs: lastActivity, midTurn: midTurn, status: meta.status))
        }
        // Forget state for sessions that closed.
        sessionStates = sessionStates.filter { liveIDs.contains($0.key) }

        // Toasts: only real changes, never on first observation (old == nil).
        for item in built {
            if let old = item.old, old != item.session.state {
                let s = item.session
                DispatchQueue.main.async { [weak self] in self?.onTransition?(s, old) }
            }
        }

        // Refresh cap state BEFORE arming (readUsage updates `lastUsage`), then
        // arm/disarm from this tick's candidates.
        readUsage()
        evaluateArming(resumeCandidates, now: now)

        // Stamp the armed fire-time onto each session so the row can render its
        // countdown chip (inject mode only — notify-only shows no chip).
        let ordered = built.map { pair -> AgentSession in
            var s = pair.session
            if let a = armedResumes[s.id], a.mode == .inject { s.autoResumeAt = a.resetAt }
            return s
        }.sorted {
            if $0.state.sortRank != $1.state.sortRank {
                return $0.state.sortRank < $1.state.sortRank
            }
            return $0.lastActivity > $1.lastActivity
        }

        updateAckCount(ordered)
        publish(ordered)
        pruneModelSpool(now: now, liveIDs: liveIDs)
    }

    /// Poll the statusline-written usage spool (tiny file, cheap on the 1.5 s
    /// tick). Publishes only on change so an unchanged file never churns SwiftUI.
    private func readUsage() {
        guard let data = try? Data(contentsOf: usageURL),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let rl = obj["rate_limits"] as? [String: Any] else { return }
        func window(_ key: String) -> (Int?, Date?) {
            guard let w = rl[key] as? [String: Any] else { return (nil, nil) }
            let pct = (w["used_percentage"] as? NSNumber)?.intValue
            let reset = (w["resets_at"] as? NSNumber)
                .map { Date(timeIntervalSince1970: $0.doubleValue) }
            return (pct, reset)
        }
        let (s, sr) = window("five_hour")
        let (wk, wr) = window("seven_day")
        let u = AgentUsage(sessionPct: s, sessionResetsAt: sr,
                           weeklyPct: wk, weeklyResetsAt: wr)
        guard !u.isEmpty, u != lastUsage else { return }
        lastUsage = u
        DispatchQueue.main.async { [weak self] in self?.usage = u }
    }

    // MARK: - Auto-resume: arming (ioQueue only)

    private func epochKey(_ id: String, _ resetAt: Date) -> String {
        "\(id)|\(Int(resetAt.timeIntervalSince1970))"
    }

    /// Arm/disarm sessions for auto-resume from this tick's candidates + cap state.
    /// Called inside `rebuild()` after `readUsage()`; spawns nothing.
    private func evaluateArming(_ candidates: [ResumeCandidate], now: Date) {
        // Settings OFF ⇒ detector inert: drop live arms (do NOT consume epochs, so
        // toggling back ON re-arms), keep the timer honest, done.
        guard autoResumeEnabled() else {
            if !armedResumes.isEmpty { armedResumes.removeAll(); rescheduleResumeTimer() }
            return
        }

        // Drop arms for sessions that vanished this tick.
        let liveIDs = Set(candidates.map(\.id))
        for id in armedResumes.keys where !liveIDs.contains(id) {
            armedResumes.removeValue(forKey: id)
        }

        // Capped == the 5-hour window at/above 99% AND its reset is still ahead.
        // A stale spool whose reset already passed must never arm (a past reset is
        // indistinguishable from old data — the file only refreshes while sessions
        // run). No cap ⇒ nothing new arms; existing arms keep their own resetAt.
        if let usage = lastUsage, let resetAt = usage.sessionResetsAt,
           (usage.sessionPct ?? 0) >= 99, resetAt > now {
            for c in candidates {
                // Already armed for THIS epoch — leave it. Armed for an older epoch
                // (reset window changed) — fall through to re-arm on the new one.
                if let existing = armedResumes[c.id], existing.resetAt == resetAt { continue }
                if consumedEpochs.contains(epochKey(c.id, resetAt)) { continue }
                guard let pid = c.pid, c.midTurn else { continue }
                let mode: ResumeMode
                switch c.host {
                case .terminalApp, .notch: mode = .inject
                case .other, .none:        mode = .notifyOnly
                }
                armedResumes[c.id] = ArmedResume(
                    sessionId: c.id, pid: pid, resetAt: resetAt,
                    armedEntryTs: c.newestEntryTs, tty: c.tty, host: c.host, mode: mode)
            }
        }
        rescheduleResumeTimer()
    }

    /// Cancel from the UI, called only after the chip's undo grace lapses (undo
    /// within the grace never reaches the model — the arm stayed live the whole
    /// time). Consumes the epoch so it stays cancelled for this reset window; a
    /// fresh cap (new resetsAt) re-arms via a new epoch. No-op if not armed.
    func cancelAutoResume(_ sessionId: String) {
        ioQueue.async { [weak self] in
            guard let self, let a = self.armedResumes[sessionId] else { return }
            self.armedResumes.removeValue(forKey: sessionId)
            self.consumedEpochs.insert(self.epochKey(sessionId, a.resetAt))
            self.rescheduleResumeTimer()
            self.rebuild()   // reflect the dropped chip promptly
        }
    }

    // MARK: - Auto-resume: firing (ioQueue only)

    /// (Re)schedule the single wall-clock timer to the earliest armed fire time.
    /// Wall clock is mandatory: if the Mac sleeps through the reset, the timer
    /// fires on wake and the resume happens then.
    private func rescheduleResumeTimer() {
        guard let earliest = armedResumes.values
            .map({ $0.resetAt.addingTimeInterval(resumeGrace) }).min() else {
            resumeTimer?.cancel(); resumeTimer = nil; resumeTimerDeadline = nil
            return
        }
        if resumeTimer != nil, resumeTimerDeadline == earliest { return }   // unchanged
        resumeTimer?.cancel()
        let t = DispatchSource.makeTimerSource(queue: ioQueue)
        let delay = max(0, earliest.timeIntervalSinceNow)
        t.schedule(wallDeadline: .now() + delay, leeway: .seconds(1))
        t.setEventHandler { [weak self] in self?.fireDueResumes() }
        t.resume()
        resumeTimer = t
        resumeTimerDeadline = earliest
    }

    /// Fire every arm whose deadline has arrived. Each is consumed (fired or
    /// silently cancelled) exactly once, then the timer is rescheduled for the rest.
    private func fireDueResumes() {
        let now = Date()
        let due = armedResumes.values
            .filter { $0.resetAt.addingTimeInterval(resumeGrace) <= now.addingTimeInterval(0.5) }
        for a in due {
            armedResumes.removeValue(forKey: a.sessionId)
            consumedEpochs.insert(epochKey(a.sessionId, a.resetAt))   // never re-fire this epoch
            fireOne(a)
        }
        rescheduleResumeTimer()
    }

    /// Re-check ALL guards at fire time; any failure ⇒ silent cancel (no toast, no
    /// injection). Guards pass ⇒ inject (or notify) + toast. Runs on `ioQueue`;
    /// injection hops to `controlQueue`/main like focus/approve.
    private func fireOne(_ a: ArmedResume) {
        // Guard 1: session file still present, same pid, alive.
        guard let meta = readSessionMetas()[a.sessionId], meta.pid == a.pid,
              kill(Int32(a.pid), 0) == 0 else { return }
        // Guard 3: not busy (a just-started manual resume would be busy).
        guard meta.status != "busy" else { return }
        // Guard 2: transcript untouched since arming AND still mid-turn (a manual
        // resume writes a user entry — advances newestEntryTs and clears mid-turn).
        guard let p = parser(forID: a.sessionId),
              p.newestEntryTs == a.armedEntryTs,
              p.lastMsgIsAssistant, p.lastMsgStopReason != "end_turn" else { return }
        // Guard 4: terminal identity re-resolves to the same tty + host.
        let identity = resolveIdentity(pid: a.pid, sid: a.sessionId)
        guard identity.tty == a.tty, identity.host == a.host else { return }

        let project = meta.cwd.isEmpty
            ? (meta.name ?? String(a.sessionId.prefix(8)))
            : URL(fileURLWithPath: meta.cwd).lastPathComponent
        let name = meta.name

        switch a.mode {
        case .notifyOnly:
            DispatchQueue.main.async { [weak self] in
                self?.onResumeFired?(project, name, true)
            }
        case .inject:
            switch a.host {
            case .notch(let sid):
                DispatchQueue.main.async { [weak self] in
                    self?.onNotchResume?(sid)
                    self?.onResumeFired?(project, name, false)
                }
            case .terminalApp:
                let pid = a.pid
                let ttyPath = a.tty.map { "/dev/\($0)" }
                controlQueue.async { [weak self] in
                    let outcome = AgentTerminalControl.resume(pid: pid, ttyPath: ttyPath)
                    DispatchQueue.main.async {
                        // Tab vanished between guard and send ⇒ notify instead.
                        self?.onResumeFired?(project, name, outcome == .notFound)
                    }
                }
            case .other, .none:
                break   // never inject-mode; defensive
            }
        }
    }

    /// The freshest live parser for a sessionId (mirrors the rebuild index).
    private func parser(forID id: String) -> FileParser? {
        var best: FileParser?
        for p in parsers.values where p.id == id && p.messageCount > 0 {
            if best == nil || (p.newestEntryTs ?? .distantPast) > (best?.newestEntryTs ?? .distantPast) {
                best = p
            }
        }
        return best
    }

    /// Read every `~/.claude/sessions/<pid>.json`, keyed by sessionId, keeping
    /// only entries whose process is still alive (`kill(pid,0)==0`). Claude Code
    /// deletes the file when the terminal closes, so a missing/dead file is the
    /// authoritative "this terminal is gone" signal that drives the row's removal.
    private func readSessionMetas() -> [String: SessionMeta] {
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: sessionsURL.path)
        else { return [:] }
        var out: [String: SessionMeta] = [:]
        for name in names where name.hasSuffix(".json") {
            let url = sessionsURL.appendingPathComponent(name)
            guard let data = try? Data(contentsOf: url),
                  let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
                  let sid = obj["sessionId"] as? String,
                  let pid = (obj["pid"] as? NSNumber)?.int32Value,
                  kill(pid, 0) == 0 else { continue }
            // Claude Code 2.1+ pre-warms `bg-spare` processes and runs headless
            // background jobs — both write a `<pid>.json` with kind == "bg".
            // They're not terminals the user "has open" (nothing to jump to) and
            // would just inflate the list, so show only interactive sessions.
            // Files with no `kind` are older Claude Code — treat as interactive.
            if (obj["kind"] as? String) == "bg" { continue }
            out[sid] = SessionMeta(pid: Int(pid),
                                   name: obj["name"] as? String,
                                   status: obj["status"] as? String ?? "idle",
                                   cwd: obj["cwd"] as? String ?? "")
        }
        return out
    }

    /// The live model id the statusline last spooled for this session, if any.
    /// Preferred over the transcript's model so a `/model` switch shows up
    /// immediately (the statusline re-renders on the switch). Empty/missing =>
    /// nil, and the caller falls back to the transcript's last-seen model.
    private func liveModelID(for sessionId: String) -> String? {
        let url = modelsURL.appendingPathComponent("\(sessionId).json")
        guard let data = try? Data(contentsOf: url),
              let obj = (try? JSONSerialization.jsonObject(with: data)) as? [String: Any],
              let id = obj["id"] as? String, !id.isEmpty else { return nil }
        return id
    }

    /// Prune orphaned model-spool files. Liveness — NOT age — is the deletion
    /// criterion: a live session may sit idle for hours (its statusline only
    /// re-renders on activity), so its spool file goes stale on disk while the
    /// session is very much alive. Deleting on age alone would strip that
    /// session's badge back to the transcript's lagging model — the exact
    /// inaccuracy this spool exists to kill. So we keep every file whose sid is
    /// a currently-live session regardless of mtime, and only reap files for
    /// sids NOT in the live set, and even then only past a 48h long-stop (so a
    /// crashed/force-killed session that never cleaned up eventually clears,
    /// without churning files a session might still resume into). Throttled —
    /// the dir is tiny, but no need to walk it every tick.
    private func pruneModelSpool(now: Date, liveIDs: Set<String>) {
        guard now.timeIntervalSince(lastModelPrune) > 300 else { return }
        lastModelPrune = now
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: modelsURL.path)
        else { return }
        for name in names where name.hasSuffix(".json") {
            let sid = String(name.dropLast(".json".count))
            if liveIDs.contains(sid) { continue }   // live session: never prune on age
            let url = modelsURL.appendingPathComponent(name)
            if let attrs = try? FileManager.default.attributesOfItem(atPath: url.path),
               let mtime = attrs[.modificationDate] as? Date,
               now.timeIntervalSince(mtime) > 48 * 3600 {
                try? FileManager.default.removeItem(at: url)
            }
        }
    }

    /// Cached terminal-identity lookup (see `identityCache`). Resolves via
    /// syscalls only — never spawns — and reuses the result for a live pid. The
    /// stored sessionId guards against pid recycling: if this pid now belongs to
    /// a different session, the stale entry is discarded and re-resolved.
    private func resolveIdentity(pid: Int, sid: String) -> TerminalIdentity {
        let key = Int32(pid)
        if let hit = identityCache[key], hit.sid == sid { return hit.identity }
        let identity = TerminalIdentity.resolve(pid: key, selfPid: selfPid,
                                                builtinShellPids: builtinShellPids())
        // Don't cache an unresolved notch session (the built-in shell list may not
        // have bubbled in yet) — let the next tick resolve it once the tab exists.
        if identity.host != .none || identity.tty != nil {
            identityCache[key] = (sid, identity)
        }
        return identity
    }

    private func jsonlFiles() -> [String] {
        guard let en = FileManager.default.enumerator(
            at: projectsURL,
            includingPropertiesForKeys: nil,
            options: [.skipsHiddenFiles]) else { return [] }
        var out: [String] = []
        for case let url as URL in en where url.pathExtension == "jsonl" {
            out.append(url.path)
        }
        return out
    }

    // MARK: - Incremental read + parse (ioQueue only)

    /// Read only the bytes appended since last time, holding any unterminated
    /// final line in `partial` so a mid-append write is never mis-parsed.
    private func ingest(into p: FileParser) {
        guard let fh = try? FileHandle(forReadingFrom: URL(fileURLWithPath: p.path)) else { return }
        defer { try? fh.close() }
        try? fh.seek(toOffset: p.byteOffset)
        let delta = (try? fh.readToEnd()) ?? Data()
        guard !delta.isEmpty else { return }

        // byteOffset always advances past everything we read; the incomplete
        // tail lives in `partial` (out of the offset) until its newline arrives.
        p.byteOffset += UInt64(delta.count)

        var combined = p.partial
        combined.append(delta)

        // Split ONLY on literal 0x0A — safe because JSON escapes newlines inside
        // string values, so no unescaped LF ever appears mid-record.
        var lines = combined.split(separator: 0x0A, omittingEmptySubsequences: false)
            .map { Data($0) }
        if combined.last == 0x0A {
            if lines.last?.isEmpty == true { lines.removeLast() }
            p.partial = Data()
        } else {
            p.partial = lines.popLast() ?? Data()
        }

        for line in lines where !line.isEmpty { parse(line, into: p) }
    }

    private func parse(_ line: Data, into p: FileParser) {
        guard let obj = (try? JSONSerialization.jsonObject(with: line)) as? [String: Any] else {
            return   // skip garbage / partial — never abort the file
        }

        let type = obj["type"] as? String ?? ""
        let isSidechain = obj["isSidechain"] as? Bool ?? false

        // Latest-wins metadata, present on every entry type (cwd can change mid-file).
        if let cwd = obj["cwd"] as? String, !cwd.isEmpty { p.cwd = cwd }
        if let gb = obj["gitBranch"] as? String { p.gitBranch = gb }
        if let sid = obj["sessionId"] as? String, !sid.isEmpty { p.id = sid }

        // Only user/assistant are agent activity. Non-message types
        // (system/attachment/queue-operation/mode/ai-title/…) must NOT touch the
        // activity clock — they land long after a turn ends and would keep a
        // finished session pinned to "working" and never let it drop.
        guard type == "user" || type == "assistant",
              let message = obj["message"] as? [String: Any] else { return }

        // Newest user/assistant timestamp is the keep-alive clock — sidechain
        // INCLUDED (a subagent burst means the parent is still working).
        if let tsStr = obj["timestamp"] as? String, let ts = Self.parseDate(tsStr),
           ts > (p.newestEntryTs ?? .distantPast) {
            p.newestEntryTs = ts
        }

        // Sidechain (subagent) counts as activity above, but must NOT set
        // lastMsg / latestAssistant / messageCount or flip the parent's state.
        guard !isSidechain else { return }

        p.messageCount += 1

        if type == "assistant" {
            if let model = message["model"] as? String { p.latestModel = model }
            p.lastMsgIsAssistant = true
            p.lastMsgIsInterrupt = false
            p.lastMsgStopReason = message["stop_reason"] as? String   // nil = streaming

            if let usage = message["usage"] as? [String: Any] {
                let input = usage["input_tokens"] as? Int ?? 0
                let read  = usage["cache_read_input_tokens"] as? Int ?? 0
                let creat = usage["cache_creation_input_tokens"] as? Int ?? 0
                let ctx = input + read + creat           // live window occupancy
                p.contextTokens = ctx
                if ctx > p.maxContextTokens { p.maxContextTokens = ctx }
                p.outputTokens += usage["output_tokens"] as? Int ?? 0
            }
        } else {   // user
            p.lastMsgIsAssistant = false
            p.lastMsgStopReason = nil
            p.lastMsgIsInterrupt = Self.isInterrupt(message["content"])
        }
    }

    /// Interrupt marker: an array item {type:"text", text:"[Request interrupted..."}
    /// (verified form) — also defensively check a plain-string content.
    private static func isInterrupt(_ content: Any?) -> Bool {
        let prefix = "[Request interrupted by user"
        if let s = content as? String {
            return s.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(prefix)
        }
        if let arr = content as? [Any] {
            for case let item as [String: Any] in arr {
                if (item["type"] as? String) == "text",
                   let t = item["text"] as? String,
                   t.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix(prefix) {
                    return true
                }
            }
        }
        return false
    }

    // MARK: - State machine

    /// Classify a session from its transcript alone (never drops — liveness is
    /// decided in `rebuild` from the live session file). `.waiting` is never
    /// produced here; that comes from the process status.
    private func classify(_ p: FileParser, age: TimeInterval) -> AgentState {
        // Interrupted — sticky until a newer non-interrupt message lands.
        if p.lastMsgIsInterrupt { return .interrupted }

        // Working — a message landed in the last few seconds (streaming/tools).
        if age < workingWindow { return .working }

        if p.lastMsgIsAssistant {
            // Turn just finished => green "your move" briefly, then settle to idle
            // (a session left untouched for a while reads as idle, not fresh).
            if p.lastMsgStopReason == "end_turn" { return age < idleMin ? .complete : .idle }
            // Mid-turn (tool_use / streaming): a tool can run for minutes — still
            // working, NOT idle.
            return .working
        }

        // Last message is a user prompt: assistant presumed spinning up.
        return age < idleMin ? .working : .idle
    }

    /// Fold the authoritative process status over the transcript classification.
    /// Interrupt wins; then busy→working, waiting→waiting; "idle" defers to the
    /// transcript but never reports "working" (the process says it's not busy),
    /// so a quiet session settles to complete (just finished) or idle.
    private func resolveState(base: AgentState, meta: SessionMeta?,
                              hasTranscript: Bool) -> AgentState {
        if base == .interrupted { return .interrupted }
        guard let meta else { return base }
        switch meta.status {
        case "busy":    return .working
        case "waiting": return .waiting
        default:        return base == .complete ? .complete : .idle
        }
    }

    private func makeSession(id: String, parser p: FileParser?, meta: SessionMeta?,
                             identity: TerminalIdentity, state: AgentState, since: Date,
                             lastActivity: Date) -> AgentSession {
        // Prefer the statusline's live model spool (reflects a /model switch at
        // once); fall back to the transcript's last-seen model when the spool is
        // absent (non-notch statusline, or nothing rendered yet).
        let (display, window) = Self.resolveModel(liveModelID(for: id) ?? p?.latestModel ?? nil,
                                                  observedContextTokens: p?.maxContextTokens ?? 0)
        let branch: String? = {
            guard let b = p?.gitBranch?.trimmingCharacters(in: .whitespacesAndNewlines),
                  !b.isEmpty, b != "HEAD" else { return nil }
            return b
        }()
        // Prefer the transcript's cwd, then the session file's, then the name.
        let cwd = (p.map { $0.cwd.isEmpty ? nil : $0.cwd } ?? nil)
            ?? (meta.map { $0.cwd.isEmpty ? nil : $0.cwd } ?? nil) ?? ""
        let project = cwd.isEmpty
            ? (meta?.name ?? String(id.prefix(8)))
            : URL(fileURLWithPath: cwd).lastPathComponent
        return AgentSession(
            id: id,
            project: project,
            gitBranch: branch,
            modelDisplay: display,
            state: state,
            stateSince: since,
            lastActivity: lastActivity,
            contextTokens: p?.contextTokens ?? 0,
            contextWindow: window,
            outputTokens: p?.outputTokens ?? 0,
            messageCount: p?.messageCount ?? 0,
            cwd: cwd,
            tty: identity.tty,
            host: identity.host,
            pid: meta?.pid,
            name: meta?.name,
            autoResumeAt: nil)
    }

    // MARK: - Ack count + publish throttle (ioQueue only)

    private func updateAckCount(_ sessions: [AgentSession]) {
        let completeIDs = Set(sessions.filter { $0.state == .complete }.map(\.id))
        acknowledgedCompleteIDs.formIntersection(completeIDs)   // forget acks for no-longer-complete
        // Only just-finished completes (within completePillWindow) drive the
        // pill, and only those the user hasn't cleared by opening the tab. The
        // short window is what makes the green ✓ fade instead of lingering.
        let now = Date()
        let recent = Set(sessions
            .filter { $0.state == .complete && now.timeIntervalSince($0.stateSince) < completePillWindow }
            .map(\.id))
        let count = recent.subtracting(acknowledgedCompleteIDs).count
        guard count != lastAckCount else { return }   // publish only on a real change
        lastAckCount = count
        DispatchQueue.main.async { [weak self] in self?.unacknowledgedCompleteCount = count }
    }

    /// Coalesce to <= 2 Hz: publish immediately if >= 0.5 s since the last one,
    /// otherwise schedule a single trailing flush.
    private func publish(_ list: [AgentSession]) {
        pendingPublish = list
        let since = Date().timeIntervalSince(lastPublish)
        if since >= 0.5 {
            flushPublish()
        } else if !publishScheduled {
            publishScheduled = true
            ioQueue.asyncAfter(deadline: .now() + (0.5 - since)) { [weak self] in
                self?.flushPublish()
            }
        }
    }

    private func flushPublish() {
        publishScheduled = false
        guard let list = pendingPublish else { return }
        pendingPublish = nil
        lastPublish = Date()
        DispatchQueue.main.async { [weak self] in self?.sessions = list }
    }

    // MARK: - Model resolution (catalog + 1M heuristic)

    // Base id -> (short display name, standard 200k/1M window).
    private static let modelCatalog: [String: (name: String, window: Int)] = [
        "claude-fable-5":            ("Fable",       1_000_000),
        "claude-mythos-5":           ("Mythos",      1_000_000),
        "claude-opus-4-8":           ("Opus 4.8",      200_000),
        "claude-opus-4-7":           ("Opus 4.7",      200_000),
        "claude-opus-4-6":           ("Opus 4.6",      200_000),
        "claude-sonnet-5":           ("Sonnet",        200_000),
        "claude-sonnet-4-6":         ("Sonnet 4.6",    200_000),
        "claude-haiku-4-5":          ("Haiku 4.5",     200_000),
        "claude-haiku-4-5-20251001": ("Haiku 4.5",     200_000),
    ]

    // Ids that expose a 1M-context variant ("[1m]" suffix). Haiku has none.
    private static let has1MVariant: Set<String> = [
        "claude-opus-4-8", "claude-opus-4-7", "claude-opus-4-6",
        "claude-sonnet-5", "claude-sonnet-4-6",
        "claude-fable-5", "claude-mythos-5",
    ]

    /// (displayName, contextWindow?). Window nil => unknown id => UI shows raw
    /// tokens. Heuristic: the id alone can't tell 200k from 1M, so treat as 1M
    /// when it carries the `[1m]` suffix OR observed context has exceeded 200k.
    static func resolveModel(_ rawId: String?, observedContextTokens: Int)
            -> (displayName: String, contextWindow: Int?) {
        guard let rawId, !rawId.isEmpty else { return ("Claude", nil) }

        let is1MSuffix = rawId.lowercased().hasSuffix("[1m]")
        let baseId = is1MSuffix ? String(rawId.dropLast(4)) : rawId

        var entry = modelCatalog[baseId]
        if entry == nil, baseId.hasPrefix("claude-haiku-4-5") {
            entry = ("Haiku 4.5", 200_000)   // dated haiku variants
        }
        guard let (name, window) = entry else { return (rawId, nil) }

        if has1MVariant.contains(baseId), is1MSuffix || observedContextTokens > 200_000 {
            return (name, 1_000_000)
        }
        return (name, window)
    }

    // MARK: - Date parsing

    private static let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime]
        return f
    }()
    static func parseDate(_ s: String) -> Date? {
        isoFrac.date(from: s) ?? iso.date(from: s)
    }
}

// MARK: - Per-file incremental parser state

/// Reference type so mutations persist inside the `parsers` dictionary and are
/// confined to `ioQueue` (no locking needed).
private final class FileParser {
    let path: String
    var id: String                 // sessionId; filename stem until first seen

    // Incremental read cursor.
    var byteOffset: UInt64 = 0
    var partial = Data()           // unterminated final line, held out of offset

    // Running tallies (exact — first ingest reads from offset 0, i.e. whole file).
    var outputTokens = 0
    var messageCount = 0
    var maxContextTokens = 0       // latches the 1M inference
    var contextTokens = 0          // latest assistant occupancy

    // Latest-state drivers.
    var latestModel: String?
    var newestEntryTs: Date?       // newest user/assistant ts incl. sidechain (keep-alive clock)
    var cwd = ""
    var gitBranch: String?

    var lastMsgIsAssistant = false
    var lastMsgStopReason: String?
    var lastMsgIsInterrupt = false

    // Debounce / transition tracking.
    var currentState: AgentState?
    var stateSince: Date

    init(path: String, now: Date) {
        self.path = path
        self.id = URL(fileURLWithPath: path).deletingPathExtension().lastPathComponent
        self.stateSince = now
    }

    /// File truncated/rotated — discard everything and re-cold-start from 0.
    func reset(now: Date) {
        byteOffset = 0
        partial = Data()
        outputTokens = 0
        messageCount = 0
        maxContextTokens = 0
        contextTokens = 0
        latestModel = nil
        newestEntryTs = nil
        cwd = ""
        gitBranch = nil
        lastMsgIsAssistant = false
        lastMsgStopReason = nil
        lastMsgIsInterrupt = false
        currentState = nil
        stateSince = now
    }
}
