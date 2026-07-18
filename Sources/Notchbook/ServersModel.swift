import Foundation
import AppKit
import Combine

/// Drives the local "Local Starter" dev-server launcher (a Python server on
/// `localhost:7780`) straight from the notch — pure JSON API, no web view.
/// Polls `/api/list` ONLY while the Servers tab is visible; degrades to an
/// "isn't running" state when the Starter is down.
final class ServersModel: ObservableObject {
    struct Server: Identifiable, Equatable, Decodable {
        var name: String
        var path: String
        var kind: String
        var port: Int
        var favorite: Bool
        var running: Bool
        var id: String { name }
        // Ignore the API's extra fields (cmd, custom).
        enum CodingKeys: String, CodingKey { case name, path, kind, port, favorite, running }

        init(from decoder: Decoder) throws {
            let c = try decoder.container(keyedBy: CodingKeys.self)
            name = try c.decode(String.self, forKey: .name)
            path = try c.decode(String.self, forKey: .path)
            kind = try c.decode(String.self, forKey: .kind)
            // `port` may arrive as an Int or a String (the add flow posts "") —
            // tolerate both so one odd entry doesn't throw and drop the whole row.
            if let p = try? c.decode(Int.self, forKey: .port) {
                port = p
            } else if let s = try? c.decode(String.self, forKey: .port), let p = Int(s) {
                port = p
            } else {
                port = 0
            }
            favorite = try c.decode(Bool.self, forKey: .favorite)
            running = try c.decode(Bool.self, forKey: .running)
        }
    }

    /// Lossy list wrapper: decode each element independently so ONE malformed
    /// entry is skipped instead of failing the entire list — a whole-list decode
    /// failure used to take the connection-failure branch and wrongly claim the
    /// Starter "isn't running" while it was up.
    private struct LossyServers: Decodable {
        let servers: [Server]
        init(from decoder: Decoder) throws {
            var c = try decoder.unkeyedContainer()
            var out: [Server] = []
            while !c.isAtEnd {
                if let s = try? c.decode(Server.self) { out.append(s) }
                else { _ = try? c.decode(AnyIgnored.self) }   // consume + skip the bad row
            }
            servers = out
        }
    }
    private struct AnyIgnored: Decodable {}

    @Published private(set) var servers: [Server] = []
    /// Is the Starter answering? Flipped false on connection failure.
    @Published private(set) var reachable = true
    /// True once the first response (success OR failure) has landed, so the UI
    /// doesn't flash "isn't running" before the first poll completes.
    @Published private(set) var loaded = false

    /// Base URL — overridable (default `localhost:7780`) so pointing at a dead
    /// port exercises the unreachable path without killing the real Starter.
    private var baseString: String {
        UserDefaults.standard.string(forKey: "servers.baseURL") ?? "http://localhost:7780"
    }

    private let session: URLSession = {
        let c = URLSessionConfiguration.ephemeral
        c.timeoutIntervalForRequest = 4
        c.waitsForConnectivity = false
        return URLSession(configuration: c)
    }()

    private var pollTimer: Timer?
    private var launchPoll: Timer?
    /// Monotonic per-request token. The 2.5 s cadence + 4 s timeout can overlap
    /// requests; a stale failure landing after a fresh success would flash
    /// "isn't running" for a tick. A completion applies only if it's still the
    /// newest. Touched only on main (refresh() is always called on main).
    private var generation = 0

    // MARK: - Polling (visible-only)

    /// Start/stop the light poll. Called from NotchView when the Servers tab is
    /// shown/hidden — zero network otherwise.
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
        guard let url = URL(string: baseString + "/api/list") else { return }
        generation += 1
        let gen = generation
        session.dataTask(with: url) { [weak self] data, _, err in
            guard let self else { return }
            if let data, err == nil {
                // A response arrived → the connection is fine. Decode leniently:
                // skip any bad rows, keep the good ones. A decode problem must
                // NOT read as "isn't running" — `reachable` means CONNECTION only.
                let list = (try? JSONDecoder().decode(LossyServers.self, from: data))?.servers ?? []
                let ordered = Self.order(list)
                DispatchQueue.main.async {
                    guard gen == self.generation else { return }   // drop stale/out-of-order completion
                    self.reachable = true
                    self.loaded = true
                    if self.servers != ordered { self.servers = ordered }
                }
            } else {
                DispatchQueue.main.async {
                    guard gen == self.generation else { return }   // drop stale/out-of-order completion
                    self.reachable = false
                    self.loaded = true
                }
            }
        }.resume()
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

    /// Explicit start/stop (NOT toggle): with a 2–3 s poll the `running` flag can
    /// be stale, and toggle against stale state inverts the user's intent. The
    /// button knows the state it rendered, so it calls the matching endpoint.
    func start(_ name: String)    { post("api/start", name: name) }
    func stop(_ name: String)     { post("api/stop", name: name) }
    func favorite(_ name: String) { post("api/favorite", name: name) }
    func remove(_ name: String)   { post("api/remove", name: name) }

    func startFavorites() {
        for s in servers where s.favorite && !s.running { start(s.name) }
    }

    /// Register a new server from a picked folder. Name defaults to the folder,
    /// kind/port auto-detected by the Starter (kind:"" → it sniffs next/static).
    func addServer(path: String) {
        let name = URL(fileURLWithPath: path).lastPathComponent
        let body: [String: String] = ["name": name, "path": path,
                                      "kind": "", "cmd": "", "port": ""]
        guard let url = URL(string: baseString + "/api/add"),
              let data = try? JSONSerialization.data(withJSONObject: body) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        req.setValue("application/json", forHTTPHeaderField: "Content-Type")
        req.httpBody = data
        session.dataTask(with: req) { [weak self] _, _, _ in
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.refresh() }
        }.resume()
    }

    /// Open the server in the default browser on the same host the Starter uses.
    func open(_ s: Server) {
        let host = URL(string: baseString)?.host ?? "localhost"
        if let u = URL(string: "http://\(host):\(s.port)") { NSWorkspace.shared.open(u) }
    }

    private func post(_ path: String, name: String) {
        let enc = name.addingPercentEncoding(withAllowedCharacters: .alphanumerics) ?? name
        guard let url = URL(string: baseString + "/" + path + "?name=" + enc) else { return }
        var req = URLRequest(url: url)
        req.httpMethod = "POST"
        session.dataTask(with: req) { [weak self] _, _, _ in
            // Refresh shortly after so running/favorite reflect reality.
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) { self?.refresh() }
        }.resume()
    }

    // MARK: - Launch the Starter

    /// Start the Python Starter headless if it isn't already up, then poll until
    /// it answers (give up after ~10 s). Mirrors the repo's own launcher (lsof
    /// guard + nohup + log) but never pops a Terminal window.
    func launchStarter() {
        let cmd = "cd /Users/jaureguimac/Core/local-starter && "
            + "lsof -ti tcp:7780 -sTCP:LISTEN >/dev/null 2>&1 || "
            + "nohup python3 server.py >/tmp/localstarter.out 2>&1 &"
        let task = Process()
        task.executableURL = URL(fileURLWithPath: "/bin/zsh")
        task.arguments = ["-lc", cmd]
        try? task.run()

        launchPoll?.invalidate()
        var tries = 0
        launchPoll = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] t in
            guard let self else { t.invalidate(); return }
            tries += 1
            self.refresh()
            if self.reachable || tries >= 10 { t.invalidate() }
        }
    }
}
