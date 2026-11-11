import Foundation
import AppKit
import Combine

/// Drives the dev-server list straight from `LocalStarter` — no daemon, no HTTP.
///
/// This used to be a client of a Python service on `localhost:7780`. Everything
/// that service did is filesystem and process work, so it now happens in-process
/// (see `LocalStarter`). That deleted a whole class of state this model had to
/// carry: connection reachability, a lossy JSON decoder, a request generation
/// counter for out-of-order network completions, and a bootstrap that shelled
/// out to launch the daemon. Reads are still done off the main thread and
/// polling still runs ONLY while the Servers tab is visible.
final class ServersModel: ObservableObject {
    struct Server: Identifiable, Equatable {
        var name: String
        var path: String
        var kind: String
        var port: Int
        var favorite: Bool
        var running: Bool
        var id: String { name }

        init(_ e: LocalStarter.Entry) {
            name = e.name; path = e.path; kind = e.kind
            port = e.port; favorite = e.favorite; running = e.running
        }
    }

    @Published private(set) var servers: [Server] = []
    /// True once the first scan has landed, so the UI doesn't flash an empty
    /// state before the list is known.
    @Published private(set) var loaded = false

    /// Serial: registry reads/writes and port probes must not interleave, and a
    /// serial queue also keeps refresh results in order without a generation
    /// counter. Utility QoS — nothing here is user-blocking.
    private let work = DispatchQueue(label: "notchbook.localstarter", qos: .utility)
    /// Where the long waits run: watching a port after a launch (up to 8 s) and
    /// stop's kill-and-verify (up to 5 s). On `work` they held up every refresh
    /// and every other row's action, so the list froze until they finished.
    /// Nothing here reads or writes the registry.
    private let slow = DispatchQueue(label: "notchbook.localstarter.wait",
                                     qos: .utility, attributes: .concurrent)
    private var pollTimer: Timer?

    // MARK: - Polling (visible-only)

    /// Start/stop the light poll. Called from NotchView when the Servers tab is
    /// shown/hidden — zero work otherwise.
    func setPolling(_ active: Bool) {
        pollTimer?.invalidate(); pollTimer = nil
        guard active else { return }
        refresh()   // immediate
        let t = Timer.scheduledTimer(withTimeInterval: 2.5, repeats: true) { [weak self] _ in
            self?.refresh()
        }
        t.tolerance = 0.5
        pollTimer = t
    }

    func refresh() {
        work.async { [weak self] in
            guard let self else { return }
            let reg = LocalStarter.loadRegistry()
            let registryOK = !reg.loadFailed
            let list = LocalStarter.entries(reg).map(Server.init)
            let ordered = Self.order(list)
            DispatchQueue.main.async {
                self.loaded = true
                if self.servers != ordered { self.servers = ordered }
                // Drop messages that stopped being true: a "didn't start" under
                // a server that has since come up, a registry warning once the
                // file reads again.
                for (name, when) in self.autoClear {
                    let over: Bool
                    switch when {
                    case .running: over = ordered.contains { $0.name == name && $0.running }
                    case .registryReadable: over = registryOK
                    }
                    if over {
                        self.lastError.removeValue(forKey: name)
                        self.autoClear.removeValue(forKey: name)
                    }
                }
            }
        }
    }

    /// Favorites first, then running, then the rest — name-sorted within a group.
    /// Stable so SwiftUI row identity doesn't flicker across refreshes.
    private static func order(_ s: [Server]) -> [Server] {
        s.sorted {
            if $0.favorite != $1.favorite { return $0.favorite }
            if $0.running != $1.running { return $0.running }
            return $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending
        }
    }

    var runningCount: Int { servers.filter(\.running).count }
    var favoriteCount: Int { servers.filter(\.favorite).count }

    // MARK: - Actions

    /// Explicit start/stop (NOT toggle): with a 2.5 s poll the `running` flag can
    /// be stale, and toggling against stale state inverts the user's intent. The
    /// button knows the state it rendered, so it calls the matching action.
    /// Where a started server runs. Injected rather than read from defaults here
    /// so the model stays testable and the Configurations setting has exactly one
    /// owner (`SettingsStore`).
    var useDeck: () -> Bool = { false }

    func start(_ name: String) {
        setError(name, nil)
        // Terminal Deck host: hand the server to a real pane instead of detaching
        // it. The point of routing servers here is that the output is ON SCREEN
        // and ⌃C works — a detached child logging to a file is what the deck is
        // replacing. No port-watch/log-tail follow-up either: the pane IS the
        // feedback, and the row's own poll flips the dot green when the port binds.
        if useDeck() {
            // The outcome is reported from INSIDE the work block. It used to be
            // captured into a `var started` out here and tested straight after the
            // `mutate` call — but `mutate` is `work.async`, so that test ran on main
            // before the block had executed and always read the initial `false`.
            // Every deck launch therefore reported "couldn't reach Terminal Deck"
            // and left a red row, moments before its own port poll turned the dot
            // green. (It was also an unsynchronised cross-thread read of a captured
            // local — a real data race, not just a wrong answer.)
            mutate { [weak self] reg in
                guard var e = LocalStarter.entries(reg).first(where: { $0.name == name })
                else { return }
                guard !LocalStarter.portLive(e.port) else { return }   // already up
                // Needs a new port, and the registry can't be saved to remember it.
                if reg.loadFailed, e.port == 0 {
                    self?.setError(name, Self.registryUnreadable, clear: .registryReadable)
                    return
                }
                guard let p = LocalStarter.plan(&reg, &e) else { return }
                let started = DeckBridge.run(command: "PORT=\(p.port) \(p.inner)",
                                             cwd: p.cwd, title: name)
                if !started { self?.setError(name, "couldn't reach Terminal Deck") }
            }
            return
        }
        // One start per row at a time. The port wait no longer blocks the queue,
        // so without this a second tap would launch a second copy while the
        // first is still coming up.
        guard let token = claim(name, stopping: false) else { return }
        mutate { [weak self] reg in
            // A stop tapped since then cancels this start.
            guard let self, self.holds(name, token) else { return }
            guard var e = LocalStarter.entries(reg).first(where: { $0.name == name }) else {
                self.release(name, token); return
            }
            // Needs a new port, and the registry can't be saved to remember it.
            if reg.loadFailed, e.port == 0 {
                self.release(name, token)
                self.setError(name, Self.registryUnreadable, clear: .registryReadable)
                return
            }
            let logBefore = LocalStarter.logSize(name)
            let launchError = LocalStarter.start(&reg, &e)
            // The exit status of the launch line means nothing: the real work is
            // backgrounded with `&`, so zsh exits 0 even when the binary does not
            // exist. Confirm by watching the port, and if it never binds, say why.
            guard e.port > 0 else { self.release(name, token); return }
            let port = e.port
            // Watch off the serial queue so the list keeps updating and the
            // other favourites launch now, not one 8 s wait after another.
            self.slow.async { [weak self] in
                for _ in 0..<16 {
                    usleep(500_000)
                    guard let self, self.holds(name, token) else { return }
                    if LocalStarter.portLive(port) {
                        self.release(name, token)
                        self.refresh()
                        return
                    }
                }
                guard let self, self.holds(name, token) else { return }
                self.release(name, token)
                // Only what THIS launch wrote. The log is append-only, so its
                // last line can be weeks old and unrelated.
                let logNow = LocalStarter.logSize(name)
                let grown = logNow >= logBefore ? logNow - logBefore : logNow
                var reason: String?
                if grown > 0 {
                    reason = LocalStarter.readLog(name, limit: Int(min(grown, 2048)))
                        .split(separator: "\n").last.map(String.init)?
                        .trimmingCharacters(in: .whitespaces)
                }
                // Nothing in the log: the launch failed before the server ran,
                // and the shell's own complaint is the reason.
                if reason?.isEmpty != false { reason = launchError }
                self.setError(name, reason ?? "didn't start — no log output", clear: .running)
            }
        }
    }

    func stop(_ name: String) {
        // Ignore a second stop while one is still verifying; a stop during a
        // start takes over from it.
        guard let token = claim(name, stopping: true) else { return }
        setError(name, nil)
        mutate { [weak self] reg in
            guard let self else { return }
            guard let e = LocalStarter.entries(reg).first(where: { $0.name == name }) else {
                self.release(name, token); return
            }
            // Kill-and-verify can take 5 s; it needs no registry, so it runs off
            // the serial queue.
            self.slow.async { [weak self] in
                let result = LocalStarter.stop(e)
                guard let self else { return }
                self.release(name, token)
                switch result {
                case .stopped, .notRunning:
                    break
                case .notOurs(let pid, let cmd):
                    self.setError(name, "port :\(e.port) is held by \(cmd) (pid \(pid)) — not stopped")
                case .refusedToDie(let pid):
                    self.setError(name, "pid \(pid) ignored SIGTERM and SIGKILL")
                }
                self.refresh()
            }
        }
    }

    /// The action in flight per row, so the waits on `slow` can't overlap for
    /// one server. Touched from main and from both queues, hence the lock.
    private var busy: [String: (token: Int, stopping: Bool)] = [:]
    private var busySeq = 0
    private let busyLock = NSLock()

    /// Nil when the row is already busy. A stop may replace a pending start.
    private func claim(_ name: String, stopping: Bool) -> Int? {
        busyLock.lock(); defer { busyLock.unlock() }
        if let b = busy[name], b.stopping || !stopping { return nil }
        busySeq += 1
        busy[name] = (token: busySeq, stopping: stopping)
        return busySeq
    }

    private func holds(_ name: String, _ token: Int) -> Bool {
        busyLock.lock(); defer { busyLock.unlock() }
        return busy[name]?.token == token
    }

    private func release(_ name: String, _ token: Int) {
        busyLock.lock(); defer { busyLock.unlock() }
        if busy[name]?.token == token { busy.removeValue(forKey: name) }
    }

    /// Why a row's last action failed, keyed by server name. Before this, a
    /// failed launch was byte-identical to one that was never attempted: no
    /// spinner, no error, no log view, the dot just stayed gray.
    @Published private(set) var lastError: [String: String] = [:]

    /// When a message goes away without another tap on its row.
    private enum AutoClear { case running, registryReadable }
    /// Main thread only, like `lastError`.
    private var autoClear: [String: AutoClear] = [:]

    private static let registryUnreadable =
        "registry.json can't be read — nothing was changed; fix or restore the file"

    private func setError(_ name: String, _ message: String?, clear: AutoClear? = nil) {
        DispatchQueue.main.async { [weak self] in
            if let message { self?.lastError[name] = message }
            else { self?.lastError.removeValue(forKey: name) }
            self?.autoClear[name] = message == nil ? nil : clear
        }
    }

    /// With an unreadable registry these would be silent no-ops (the save is
    /// refused), so the row says why instead.
    func favorite(_ name: String) {
        mutate { [weak self] reg in
            if reg.loadFailed {
                self?.setError(name, Self.registryUnreadable, clear: .registryReadable); return
            }
            LocalStarter.toggleFavorite(name)
        }
    }
    func remove(_ name: String) {
        mutate { [weak self] reg in
            if reg.loadFailed {
                self?.setError(name, Self.registryUnreadable, clear: .registryReadable); return
            }
            LocalStarter.remove(name)
        }
    }

    func startFavorites() {
        for s in servers where s.favorite && !s.running { start(s.name) }
    }

    /// Register a new server from a picked folder. Name defaults to the folder;
    /// kind and port are auto-detected.
    func addServer(path: String) {
        mutate { _ in LocalStarter.add(path: path) }
    }

    /// Open the running server in the default browser.
    func open(_ s: Server) {
        // A "running" entry whose port fell back to 0 has no real URL — building
        // http://localhost:0 would silently fail to open with no feedback. Guard
        // here (the row also hides its open button when port == 0).
        guard s.port > 0, let u = URL(string: "http://localhost:\(s.port)") else { return }
        NSWorkspace.shared.open(u)
    }

    /// Run a registry-touching action off the main thread, then refresh. The
    /// delay lets a just-launched process bind its port before the probe runs,
    /// so the row doesn't flick back to "stopped" for one cycle.
    private func mutate(_ body: @escaping (inout LocalStarter.Registry) -> Void) {
        work.async { [weak self] in
            var reg = LocalStarter.loadRegistry()
            body(&reg)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.refresh() }
        }
    }
}
