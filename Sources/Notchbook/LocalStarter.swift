import Foundation

/// The dev-server launcher, in-process.
///
/// This replaces the Python `local-starter` HTTP API that used to run as a
/// separate launchd service on port 7780. Everything it did — the registry,
/// folder discovery, port assignment, liveness, launching and stopping — is
/// plain filesystem and process work, so it needed neither a daemon nor a
/// socket. Removing the socket removes the whole attack surface: `/api/add`
/// took a `cmd` that `/api/start` handed to a shell, which on a routable bind
/// was command execution for anyone on the network.
///
/// State stays at `~/.local-starter/` in the same JSON shape Python wrote, so
/// nothing is lost and the old service still reads it if it is ever restored.
///
/// Static folders are still served by a real child process (`_serve.py`, 38
/// lines, bundled in Resources). A static server has to hold a port, and
/// keeping it a detached child means dev servers survive quitting the notch
/// app — the same lifetime they had under launchd.
///
/// Everything here is blocking filesystem/process work. Call it off the main
/// thread; `ServersModel` owns that queue.
enum LocalStarter {

    // MARK: - Paths

    static let stateDir = NSString(string: "~/.local-starter").expandingTildeInPath
    static let coreDir = NSString(string: "~/Core").expandingTildeInPath
    static var registryURL: URL { URL(fileURLWithPath: stateDir + "/registry.json") }
    static var logsDir: String { stateDir + "/logs" }
    static var pidsDir: String { stateDir + "/pids" }

    /// The folder the Python service lived in. It still holds `_serve.py` and is
    /// kept as the development fallback, but it is never *listed* as a servable
    /// project — the old API excluded itself from discovery and the tab should
    /// not grow a new row just because the daemon went away.
    static let legacyDir = coreDir + "/local-starter"

    /// `_serve.py` from the app bundle, falling back to the source folder for
    /// `swift run` builds where there is no `Contents/Resources`.
    static var staticServerScript: String? {
        if let r = Bundle.main.resourceURL?.appendingPathComponent("_serve.py").path,
           FileManager.default.isReadableFile(atPath: r) { return r }
        let dev = legacyDir + "/_serve.py"
        return FileManager.default.isReadableFile(atPath: dev) ? dev : nil
    }

    // MARK: - Model

    struct Entry: Equatable {
        var name: String
        var path: String
        var kind: String        // next | pyserver | static
        var port: Int
        var cmd: String
        var custom: Bool
        var favorite: Bool
        var running: Bool
    }

    /// Mirrors `registry.json` exactly as the Python wrote it: custom specs,
    /// hidden discovered names, assigned ports, favorites.
    struct Registry: Codable {
        struct Spec: Codable {
            var path: String
            var kind: String?
            var cmd: String?
            var port: Int?
        }
        var custom: [String: Spec] = [:]
        var hidden: [String] = []
        var ports: [String: Int] = [:]
        var favorites: [String] = []
    }

    // MARK: - Registry I/O

    static func loadRegistry() -> Registry {
        guard let data = try? Data(contentsOf: registryURL),
              let reg = try? JSONDecoder().decode(Registry.self, from: data)
        else { return Registry() }
        return reg
    }

    /// Atomic write — a torn registry loses every custom entry and favourite,
    /// and this is rewritten on every favourite tap.
    static func saveRegistry(_ reg: Registry) {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        guard let data = try? enc.encode(reg) else { return }
        try? FileManager.default.createDirectory(atPath: stateDir,
                                                 withIntermediateDirectories: true)
        let tmp = registryURL.appendingPathExtension("tmp")
        guard (try? data.write(to: tmp)) != nil else { return }
        _ = try? FileManager.default.replaceItemAt(registryURL, withItemAt: tmp)
    }

    // MARK: - Discovery

    /// next when package.json depends on it, pyserver when there's a server.py,
    /// else a plain static folder.
    static func sniffKind(_ path: String) -> String {
        if let data = FileManager.default.contents(atPath: path + "/package.json"),
           let pkg = try? JSONSerialization.jsonObject(with: data) as? [String: Any] {
            let deps = (pkg["dependencies"] as? [String: Any] ?? [:])
                .merging(pkg["devDependencies"] as? [String: Any] ?? [:]) { a, _ in a }
            if deps["next"] != nil { return "next" }
        }
        if FileManager.default.fileExists(atPath: path + "/server.py") { return "pyserver" }
        return "static"
    }

    /// Folders in ~/Core that look servable and are neither custom nor hidden.
    static func discovered(_ reg: Registry) -> [String: String] {
        var out: [String: String] = [:]
        let fm = FileManager.default
        guard let names = try? fm.contentsOfDirectory(atPath: coreDir) else { return out }
        for n in names.sorted() {
            if n.hasPrefix(".") || reg.custom[n] != nil || reg.hidden.contains(n) { continue }
            let p = coreDir + "/" + n
            if URL(fileURLWithPath: p).resolvingSymlinksInPath().path
                == URL(fileURLWithPath: legacyDir).resolvingSymlinksInPath().path { continue }
            var isDir: ObjCBool = false
            guard fm.fileExists(atPath: p, isDirectory: &isDir), isDir.boolValue else { continue }
            if ["index.html", "server.py", "package.json"].contains(where: {
                fm.fileExists(atPath: p + "/" + $0)
            }) { out[n] = p }
        }
        return out
    }

    /// The full list the tab renders: custom entries plus discovered folders,
    /// with ports, favourites and live state folded in.
    static func entries(_ reg: Registry) -> [Entry] {
        var out: [Entry] = []
        for (name, spec) in reg.custom {
            let port = spec.port ?? reg.ports[name] ?? 0
            out.append(Entry(name: name, path: spec.path,
                             kind: (spec.kind?.isEmpty == false ? spec.kind! : sniffKind(spec.path)),
                             port: port, cmd: spec.cmd ?? "", custom: true,
                             favorite: reg.favorites.contains(name), running: portLive(port)))
        }
        for (name, path) in discovered(reg) {
            let port = reg.ports[name] ?? 0
            out.append(Entry(name: name, path: path, kind: sniffKind(path),
                             port: port, cmd: "", custom: false,
                             favorite: reg.favorites.contains(name), running: portLive(port)))
        }
        return out.sorted { $0.name.localizedCaseInsensitiveCompare($1.name) == .orderedAscending }
    }

    // MARK: - Ports

    /// Is anything listening on loopback at this port? Deliberately a probe and
    /// not a pid check, so a server started from a terminal still reads as
    /// running. Non-blocking connect + poll so a wedged listener can't stall the
    /// poll loop; 300 ms matches the old Python probe.
    /// Dual-stack. This probed 127.0.0.1 only, which made every IPv6-bound dev
    /// server read as permanently down: node's `listen(port, 'localhost')` —
    /// the most common form on macOS, and what vite does — resolves ::1 first
    /// and binds IPv6-only. The row then showed a gray dot and offered ▶, which
    /// launched a second instance that could not bind and died silently.
    /// The 300 ms budget is shared across both families, not spent per family.
    static func portLive(_ port: Int) -> Bool {
        guard port > 0, port < 65536 else { return false }
        let deadline = Date().addingTimeInterval(0.3)
        if probe(port, family: AF_INET, deadline: deadline) { return true }
        return probe(port, family: AF_INET6, deadline: deadline)
    }

    private static func probe(_ port: Int, family: Int32, deadline: Date) -> Bool {
        let remaining = Int32(max(0, deadline.timeIntervalSinceNow * 1000))
        guard remaining > 0 else { return false }
        let fd = socket(family, SOCK_STREAM, 0)
        guard fd >= 0 else { return false }
        defer { close(fd) }
        let flags = fcntl(fd, F_GETFL, 0)
        _ = fcntl(fd, F_SETFL, flags | O_NONBLOCK)

        let rc: Int32
        if family == AF_INET {
            var addr = sockaddr_in()
            addr.sin_len = UInt8(MemoryLayout<sockaddr_in>.size)
            addr.sin_family = sa_family_t(AF_INET)
            addr.sin_port = in_port_t(UInt16(port).bigEndian)
            addr.sin_addr.s_addr = inet_addr("127.0.0.1")
            rc = withUnsafePointer(to: &addr) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in>.size))
                }
            }
        } else {
            var addr6 = sockaddr_in6()
            addr6.sin6_len = UInt8(MemoryLayout<sockaddr_in6>.size)
            addr6.sin6_family = sa_family_t(AF_INET6)
            addr6.sin6_port = in_port_t(UInt16(port).bigEndian)
            addr6.sin6_addr = in6addr_loopback
            rc = withUnsafePointer(to: &addr6) { p in
                p.withMemoryRebound(to: sockaddr.self, capacity: 1) {
                    connect(fd, $0, socklen_t(MemoryLayout<sockaddr_in6>.size))
                }
            }
        }
        if rc == 0 { return true }
        guard errno == EINPROGRESS else { return false }

        var pfd = pollfd(fd: fd, events: Int16(POLLOUT), revents: 0)
        guard poll(&pfd, 1, remaining) == 1 else { return false }
        var soErr: Int32 = 0
        var len = socklen_t(MemoryLayout<Int32>.size)
        guard getsockopt(fd, SOL_SOCKET, SO_ERROR, &soErr, &len) == 0 else { return false }
        return soErr == 0
    }

    static func freePort(_ reg: Registry) -> Int {
        var used = Set(reg.ports.values)
        used.formUnion(reg.custom.values.compactMap(\.port))
        var p = 8100
        while used.contains(p) || portLive(p) { p += 1 }
        return p
    }

    /// Assign and persist a port for an entry that has none yet.
    @discardableResult
    static func ensurePort(_ reg: inout Registry, _ entry: inout Entry) -> Int {
        if entry.port > 0 { return entry.port }
        let port = freePort(reg)
        reg.ports[entry.name] = port
        saveRegistry(reg)
        entry.port = port
        return port
    }

    // MARK: - Launching

    /// index.html when present, else the first .html in the folder — how the
    /// codemap renderer ends up served as foglamp.html at "/".
    static func pickIndex(_ path: String) -> String {
        let fm = FileManager.default
        if fm.fileExists(atPath: path + "/index.html") { return "index.html" }
        let pages = ((try? fm.contentsOfDirectory(atPath: path)) ?? [])
            .filter { $0.hasSuffix(".html") }.sorted()
        return pages.first ?? "index.html"
    }

    /// POSIX single-quoting. Real entries include "Web of Relationships app" and
    /// "ambidex (xcode)", so nothing may reach the shell unquoted.
    static func q(_ s: String) -> String {
        "'" + s.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }

    /// What actually has to run for an entry, and where. Split out of `start` so
    /// the detached path and the Terminal Deck path resolve the command the SAME
    /// way — a server started in a deck pane must be the same server, not a
    /// second definition of one that drifts.
    struct LaunchPlan {
        let cwd: String
        /// The command itself, without any detaching, redirection or PORT export.
        let inner: String
        let port: Int
    }

    static func plan(_ reg: inout Registry, _ entry: inout Entry) -> LaunchPlan? {
        let port = ensurePort(&reg, &entry)
        if !entry.cmd.isEmpty {
            return LaunchPlan(cwd: entry.path, inner: entry.cmd, port: port)
        }
        if entry.kind == "pyserver" {
            return LaunchPlan(cwd: entry.path, inner: "python3 server.py", port: port)
        }
        if entry.kind == "next" {
            return LaunchPlan(cwd: entry.path, inner: "npm run dev", port: port)
        }
        guard let script = staticServerScript else { return nil }
        return LaunchPlan(
            cwd: entry.path,
            inner: "python3 \(q(script)) \(port) \(q(entry.path)) \(q(pickIndex(entry.path)))",
            port: port)
    }

    static func start(_ reg: inout Registry, _ entry: inout Entry) {
        let port = ensurePort(&reg, &entry)
        if portLive(port) { return }        // already up — never double-launch

        let fm = FileManager.default
        try? fm.createDirectory(atPath: logsDir, withIntermediateDirectories: true)
        try? fm.createDirectory(atPath: pidsDir, withIntermediateDirectories: true)

        guard let p = plan(&reg, &entry) else { return }
        let inner = p.inner
        let cwd = p.cwd

        let log = q(logsDir + "/\(entry.name).log")
        let pid = q(pidsDir + "/\(entry.name).pid")
        // `nohup … &` inside a login shell detaches the child into its own job,
        // so it outlives the notch app exactly as it outlived the daemon. PORT is
        // exported because pyserver/next entries read it to choose their port.
        let cmd = "cd \(q(cwd)) && PORT=\(port) nohup \(inner) >> \(log) 2>&1 & echo $! > \(pid)"
        shell(cmd)
    }

    /// SIGTERM whatever is listening on the entry's port.
    ///
    /// Kept port-based rather than pid-based on purpose: `running` is a port
    /// probe, so the tab will happily show a server someone started from a
    /// terminal, and stop has to be able to stop that too. The wart is that it
    /// will also kill an unrelated process that happens to hold the port.
    enum StopResult: Equatable {
        case stopped
        case notRunning
        case refusedToDie(pid_t)
        case notOurs(pid_t, String)
    }

    /// SIGTERM the listener, but only when it is ours, then verify and escalate.
    ///
    /// This used to be a bare `lsof … | xargs kill` with no ownership check, no
    /// verification and no feedback: it would happily SIGTERM an unrelated
    /// process that happened to hold the port, and a server that ignores SIGTERM
    /// stayed up while the row kept showing green.
    @discardableResult
    static func stop(_ entry: Entry) -> StopResult {
        guard entry.port > 0 else { return .notRunning }
        switch owner(of: entry) {
        case .free:
            return .notRunning
        case .stranger(let pid, let cmd):
            return .notOurs(pid, cmd)
        case .unknown:
            shell("lsof -ti tcp:\(entry.port) -sTCP:LISTEN | xargs kill 2>/dev/null")
        case .ours(let pid):
            kill(pid, SIGTERM)
        }
        // Verify rather than assume, and escalate once if it refuses.
        for _ in 0..<12 {
            usleep(250_000)
            if !portLive(entry.port) { return .stopped }
        }
        if let pid = listenerPid(entry.port) {
            kill(pid, SIGKILL)
            for _ in 0..<8 {
                usleep(250_000)
                if !portLive(entry.port) { return .stopped }
            }
            return .refusedToDie(pid)
        }
        return .stopped
    }

    /// Who owns the port, as far as we can tell.
    enum Owner: Equatable {
        case ours(pid_t)        // the pid we recorded, still alive and listening
        case stranger(pid_t, String)  // someone else is on this port
        case unknown            // live, but we couldn't resolve a pid
        case free
    }

    /// The pid `start()` recorded, if it is still alive. The launcher had been
    /// writing these files since the daemon was dropped and nothing ever read
    /// them — which is why a green dot could not distinguish "your server" from
    /// "a stranger on your port", and why ■ would SIGTERM that stranger.
    static func recordedPid(_ name: String) -> pid_t? {
        guard let raw = try? String(contentsOfFile: pidsDir + "/\(name).pid", encoding: .utf8),
              let pid = pid_t(raw.trimmingCharacters(in: .whitespacesAndNewlines)),
              pid > 0, kill(pid, 0) == 0
        else { return nil }
        return pid
    }

    /// The pid actually listening on a port, via lsof.
    static func listenerPid(_ port: Int) -> pid_t? {
        let r = Subprocess.run("/usr/sbin/lsof",
                               ["-ti", "tcp:\(port)", "-sTCP:LISTEN"], timeout: 3)
        guard r.ok else { return nil }
        return r.out.split(separator: "\n").compactMap { pid_t($0.trimmingCharacters(in: .whitespaces)) }.first
    }

    /// Resolve ownership so the UI can tell the three states apart, and so stop()
    /// refuses to kill something that isn't ours.
    static func owner(of entry: Entry) -> Owner {
        guard entry.port > 0, portLive(entry.port) else { return .free }
        guard let live = listenerPid(entry.port) else { return .unknown }
        if let mine = recordedPid(entry.name), mine == live { return .ours(live) }
        let cmd = Subprocess.run("/bin/ps", ["-o", "command=", "-p", "\(live)"], timeout: 3)
            .out.trimmingCharacters(in: .whitespacesAndNewlines)
        // A server we started in a PREVIOUS run is still ours by path: the pid
        // file is gone but the command line points at this project. This is what
        // lets a relaunched app re-adopt a server it orphaned on quit.
        if !entry.path.isEmpty, cmd.contains(entry.path) { return .ours(live) }
        return .stranger(live, cmd.isEmpty ? "another process" : cmd)
    }

    static func readLog(_ name: String, limit: Int = 16384) -> String {
        guard let h = FileHandle(forReadingAtPath: logsDir + "/\(name).log") else { return "" }
        defer { try? h.close() }
        let size = (try? h.seekToEnd()) ?? 0
        try? h.seek(toOffset: size > UInt64(limit) ? size - UInt64(limit) : 0)
        let data = (try? h.readToEnd()) ?? Data()
        return String(data: data, encoding: .utf8) ?? ""
    }

    // MARK: - Mutations

    static func toggleFavorite(_ name: String) {
        var reg = loadRegistry()
        if let i = reg.favorites.firstIndex(of: name) { reg.favorites.remove(at: i) }
        else { reg.favorites.append(name) }
        saveRegistry(reg)
    }

    /// Custom entries are deleted; discovered ones are hidden. Never stops the
    /// process — removing is a list action, not a lifecycle one.
    static func remove(_ name: String) {
        var reg = loadRegistry()
        if reg.custom.removeValue(forKey: name) == nil, !reg.hidden.contains(name) {
            reg.hidden.append(name)
        }
        saveRegistry(reg)
    }

    /// Register a folder. Re-adding a hidden discovered folder just unhides it,
    /// which is how the old API behaved and what the remove/undo flow relies on.
    static func add(path rawPath: String, name rawName: String? = nil,
                    kind: String = "", cmd: String = "", port: Int = 0) {
        let path = NSString(string: rawPath).expandingTildeInPath
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir),
              isDir.boolValue else { return }
        let name = rawName?.isEmpty == false
            ? rawName! : URL(fileURLWithPath: path).lastPathComponent

        var reg = loadRegistry()
        reg.hidden.removeAll { $0 == name }
        if reg.custom[name] == nil {
            reg.custom[name] = Registry.Spec(path: path,
                                             kind: kind.isEmpty ? sniffKind(path) : kind,
                                             cmd: cmd,
                                             port: port > 0 ? port : nil)
        }
        saveRegistry(reg)
    }

    // MARK: - Shell

    /// One detached login shell. Login (`-l`) because npm/python live on a PATH
    /// the app doesn't inherit when launched from Finder.
    /// Runs a command in a login shell and hands back its output. The exit
    /// status alone is not a launch verdict: start() backgrounds the real work
    /// with `&`, so zsh exits 0 even when the server binary does not exist —
    /// callers must confirm by probing the port. What this does give them is
    /// stderr, which used to go to /dev/null and took every diagnosable failure
    /// (`cd: no such file or directory`, a missing runtime) with it.
    @discardableResult
    static func shell(_ command: String) -> Subprocess.Result {
        Subprocess.loginShell(command)
    }
}
