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
            let list = LocalStarter.entries(LocalStarter.loadRegistry()).map(Server.init)
            let ordered = Self.order(list)
            DispatchQueue.main.async {
                self.loaded = true
                if self.servers != ordered { self.servers = ordered }
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
    func start(_ name: String) {
        setError(name, nil)
        mutate { [weak self] reg in
            guard var e = LocalStarter.entries(reg).first(where: { $0.name == name }) else { return }
            LocalStarter.start(&reg, &e)
            // The exit status of the launch line means nothing: the real work is
            // backgrounded with `&`, so zsh exits 0 even when the binary does not
            // exist. Confirm by watching the port, and if it never binds, surface
            // the last line of the log — which readLog could already produce and
            // nothing ever called.
            guard e.port > 0 else { return }
            for _ in 0..<16 {
                usleep(500_000)
                if LocalStarter.portLive(e.port) { return }
            }
            let tail = LocalStarter.readLog(name, limit: 2048)
                .split(separator: "\n").last.map(String.init)?
                .trimmingCharacters(in: .whitespaces)
            self?.setError(name, tail?.isEmpty == false ? tail! : "didn't start — no log output")
        }
    }

    func stop(_ name: String) {
        setError(name, nil)
        mutate { [weak self] reg in
            guard let e = LocalStarter.entries(reg).first(where: { $0.name == name }) else { return }
            switch LocalStarter.stop(e) {
            case .stopped, .notRunning:
                break
            case .notOurs(let pid, let cmd):
                self?.setError(name, "port :\(e.port) is held by \(cmd) (pid \(pid)) — not stopped")
            case .refusedToDie(let pid):
                self?.setError(name, "pid \(pid) ignored SIGTERM and SIGKILL")
            }
        }
    }

    /// Why a row's last action failed, keyed by server name. Before this, a
    /// failed launch was byte-identical to one that was never attempted: no
    /// spinner, no error, no log view, the dot just stayed gray.
    @Published private(set) var lastError: [String: String] = [:]

    private func setError(_ name: String, _ message: String?) {
        DispatchQueue.main.async { [weak self] in
            if let message { self?.lastError[name] = message }
            else { self?.lastError.removeValue(forKey: name) }
        }
    }

    func favorite(_ name: String) { mutate { _ in LocalStarter.toggleFavorite(name) } }
    func remove(_ name: String)   { mutate { _ in LocalStarter.remove(name) } }

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
