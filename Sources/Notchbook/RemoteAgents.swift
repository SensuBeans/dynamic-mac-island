import Combine
import Foundation

/// Agents running on another Mac, shown in the Agents tab beside this Mac's own, labeled with that Mac's name
/// ("Mac mini" on the MacBook, "MacBook Pro" on the mini).
///
/// Every Mac writes a snapshot of its own sessions to `Application Support/Notchbook/agents-snapshot.json`
/// and shows whatever fresh snapshots sit in `Application Support/Notchbook/remote/`. One Mac carries both ways
/// over ssh: set `agents.remoteHost` (an ssh host alias, e.g. `defaults write com.sensubeans.notchbook
/// agents.remoteHost mini`) and every few seconds it sends its snapshot into the other Mac's `remote/` and brings
/// the other Mac's snapshot back into its own. So only one side needs ssh access to the other.
/// Remote rows are read-only: no Open / Approve (their terminals are on the other machine).
final class RemoteAgentsModel: ObservableObject {
    @Published private(set) var sessions: [AgentSession] = []

    struct Snapshot: Codable {
        var machine: String
        var at: Date
        var agents: [Agent]
    }
    struct Agent: Codable, Equatable {
        var id: String
        var name: String?
        var project: String
        var gitBranch: String?
        var model: String
        var state: String
        var stateSince: Date
        var lastActivity: Date
        var contextTokens: Int
        var contextWindow: Int?
        var outputTokens: Int
        var cwd: String
    }

    /// A remote snapshot older than this is a Mac that went away (asleep, off the network): its rows go.
    static let staleAfter: TimeInterval = 20
    private static let linkEvery: TimeInterval = 3
    /// After a failed link (host unreachable, ssh or the remote command failing, nothing readable back) the next
    /// try waits linkEvery × 2^failures (6, 12, 24, 48 s), capped here; the first success goes back to every 3 s.
    private static let maxBackoff: TimeInterval = 60

    private let dir = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("Library/Application Support/Notchbook", isDirectory: true)
    private var snapshotURL: URL { dir.appendingPathComponent("agents-snapshot.json") }
    private var remoteDir: URL { dir.appendingPathComponent("remote", isDirectory: true) }
    private let queue = DispatchQueue(label: "notchbook.remote-agents", qos: .utility)
    private var cancellable: AnyCancellable?
    private var timer: DispatchSourceTimer?
    private var linkBusy = false
    private var linkFailures = 0            // queue only
    private var nextLinkAt = Date.distantPast // queue only
    /// What the snapshot file last got written with (queue only), so an unchanged list doesn't rewrite it.
    private var lastWritten: (machine: String, agents: [Agent])?
    /// One entry per row last published to `sessions` (main only), so every displayed field is compared.
    private struct Row: Equatable { var machine: String; var agent: Agent }
    private var shown: [Row] = []

    /// This Mac's short name: the computer name without its owner ("Erick's MacBook Pro" → "MacBook Pro").
    /// `agents.machineLabel` overrides it.
    static var machineLabel: String {
        if let custom = UserDefaults.standard.string(forKey: "agents.machineLabel"), !custom.isEmpty { return custom }
        let full = Host.current().localizedName ?? "Mac"
        for mark in ["’s ", "'s "] {
            if let r = full.range(of: mark) { return String(full[r.upperBound...]) }
        }
        return full
    }

    func start(local: AgentSessionsModel) {
        try? FileManager.default.createDirectory(at: remoteDir, withIntermediateDirectories: true)
        cancellable = local.$sessions
            .throttle(for: .seconds(1), scheduler: DispatchQueue.main, latest: true)
            .sink { [weak self] list in self?.writeSnapshot(list) }
        let t = DispatchSource.makeTimerSource(queue: queue)
        t.schedule(deadline: .now() + 1, repeating: Self.linkEvery)
        t.setEventHandler { [weak self] in self?.tick() }
        t.resume()
        timer = t
    }

    // MARK: snapshot out

    private func writeSnapshot(_ list: [AgentSession]) {
        let machine = Self.machineLabel
        let snap = Snapshot(machine: machine, at: Date(), agents: list.map { s in
            Agent(id: s.id, name: s.name, project: s.project, gitBranch: s.gitBranch, model: s.modelDisplay,
                  state: Self.text(s.state), stateSince: s.stateSince, lastActivity: s.lastActivity,
                  contextTokens: s.contextTokens, contextWindow: s.contextWindow, outputTokens: s.outputTokens, cwd: s.cwd)
        })
        queue.async { [weak self, snapshotURL] in
            guard let self else { return }
            // Same machine and same agents as the last write: leave the file alone. tick() still moves its clock
            // forward every staleAfter/2 so the other side doesn't drop it as stale.
            if let last = self.lastWritten, last.machine == machine, last.agents == snap.agents,
               FileManager.default.fileExists(atPath: snapshotURL.path) { return }
            guard let data = try? Self.encoder.encode(snap) else { return }
            if (try? data.write(to: snapshotURL, options: .atomic)) != nil {
                self.lastWritten = (machine, snap.agents)
            }
        }
    }

    // MARK: link + read (queue)

    private func tick() {
        // An idle Mac's sessions don't change, but the snapshot's clock must, or the other side would drop it as stale.
        if let data = try? Data(contentsOf: snapshotURL), var snap = try? Self.decoder.decode(Snapshot.self, from: data),
           Date().timeIntervalSince(snap.at) > Self.staleAfter / 2 {
            snap.at = Date()
            if let out = try? Self.encoder.encode(snap) { try? out.write(to: snapshotURL, options: .atomic) }
        }
        if let host = UserDefaults.standard.string(forKey: "agents.remoteHost"), !host.isEmpty, !linkBusy, Date() >= nextLinkAt {
            link(host: host)
        }
        readRemotes()
    }

    /// One ssh round trip: our snapshot in on stdin → the other Mac's remote/<us>.json; theirs back on stdout.
    /// A shared control connection keeps it to one TCP/auth setup per minute.
    private func link(host: String) {
        guard let mine = try? Data(contentsOf: snapshotURL) else { return }
        linkBusy = true
        let me = Self.machineLabel.replacingOccurrences(of: "/", with: "-").replacingOccurrences(of: "'", with: "")
        let base = "\"$HOME/Library/Application Support/Notchbook\""
        let remoteCmd = "mkdir -p \(base)/remote && cat > \(base)/remote/'\(me).json' && cat \(base)/agents-snapshot.json 2>/dev/null"
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        p.arguments = ["-o", "BatchMode=yes", "-o", "ConnectTimeout=4",
                       "-o", "ControlMaster=auto", "-o", "ControlPath=/tmp/notchbook-ssh-%r@%h:%p", "-o", "ControlPersist=60",
                       host, remoteCmd]
        let inPipe = Pipe(), outPipe = Pipe()
        p.standardInput = inPipe; p.standardOutput = outPipe; p.standardError = FileHandle.nullDevice
        p.terminationHandler = { [weak self] proc in
            let data = outPipe.fileHandleForReading.readDataToEndOfFile()
            self?.queue.async {
                guard let self else { return }
                self.linkBusy = false
                guard proc.terminationStatus == 0, let snap = try? Self.decoder.decode(Snapshot.self, from: data) else {
                    self.linkFailed()
                    return
                }
                self.linkFailures = 0
                self.nextLinkAt = .distantPast
                let name = snap.machine.replacingOccurrences(of: "/", with: "-")
                try? data.write(to: self.remoteDir.appendingPathComponent("\(name).json"), options: .atomic)
                self.readRemotes()
            }
        }
        do {
            try p.run()
            inPipe.fileHandleForWriting.write(mine)
            try? inPipe.fileHandleForWriting.close()
            // A hung link (network gone mid-call) must not block the next ones forever.
            queue.asyncAfter(deadline: .now() + 10) { if p.isRunning { p.terminate() } }
        } catch {
            linkBusy = false
            linkFailed()
        }
    }

    /// Back off after a failed link: 6, 12, 24, 48, then 60 s between tries until one succeeds.
    private func linkFailed() {
        linkFailures = min(linkFailures + 1, 10)
        let delay = min(Self.maxBackoff, Self.linkEvery * pow(2, Double(linkFailures)))
        nextLinkAt = Date().addingTimeInterval(delay)
    }

    private func readRemotes() {
        let me = Self.machineLabel
        let files = (try? FileManager.default.contentsOfDirectory(at: remoteDir, includingPropertiesForKeys: nil)) ?? []
        var out: [AgentSession] = []
        var rows: [Row] = []
        for f in files.sorted(by: { $0.lastPathComponent < $1.lastPathComponent }) where f.pathExtension == "json" {
            guard let data = try? Data(contentsOf: f), let snap = try? Self.decoder.decode(Snapshot.self, from: data),
                  snap.machine != me, Date().timeIntervalSince(snap.at) < Self.staleAfter else { continue }
            rows += snap.agents.map { Row(machine: snap.machine, agent: $0) }
            out += snap.agents.map { a in
                AgentSession(id: "\(snap.machine)/\(a.id)", project: a.project, gitBranch: a.gitBranch, modelDisplay: a.model,
                             state: Self.state(a.state), stateSince: a.stateSince, lastActivity: a.lastActivity,
                             contextTokens: a.contextTokens, contextWindow: a.contextWindow, outputTokens: a.outputTokens,
                             messageCount: 0, cwd: a.cwd, tty: nil, host: .none, pid: nil, name: a.name, autoResumeAt: nil,
                             hasLimitBanner: false, autoResumeArmed: false, autoResumeOptedIn: false,
                             pendingTool: nil, resumeVerdict: nil, machine: snap.machine)
            }
        }
        DispatchQueue.main.async { [weak self] in
            guard let self else { return }
            // Compare every field a row shows (context, tokens, name, model, branch, activity, state), not just ids
            // and state, so a working remote agent's meter keeps moving; identical results still don't republish.
            if self.shown != rows {
                self.shown = rows
                self.sessions = out
            }
        }
    }

    private static func text(_ s: AgentState) -> String {
        switch s {
        case .working: return "working"
        case .complete: return "complete"
        case .interrupted: return "interrupted"
        case .idle: return "idle"
        case .waiting: return "waiting"
        }
    }
    private static func state(_ s: String) -> AgentState {
        switch s {
        case "working": return .working
        case "complete": return .complete
        case "interrupted": return .interrupted
        case "waiting": return .waiting
        default: return .idle
        }
    }
    private static let encoder: JSONEncoder = { let e = JSONEncoder(); e.dateEncodingStrategy = .secondsSince1970; return e }()
    private static let decoder: JSONDecoder = { let d = JSONDecoder(); d.dateDecodingStrategy = .secondsSince1970; return d }()
}
