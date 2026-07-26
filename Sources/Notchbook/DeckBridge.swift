import AppKit
import Foundation

/// Talks to Terminal Deck over its `terminaldeck://` scheme.
///
/// The island has always driven **Terminal.app** through Apple Events
/// (`AgentTerminalControl`) and started dev servers as detached `nohup` children
/// (`LocalStarter`). Terminal Deck is the replacement environment, and the
/// Configurations setting picks which one the Agents and Servers pages target.
///
/// Deliberately a URL scheme rather than Apple Events or a socket: opening a URL
/// **launches the deck if it isn't running**, which is what makes "start a
/// server" or "launch a terminal" work from a collapsed notch with the deck
/// closed. It also needs no Automation (Apple Events) permission — the grant
/// that makes the Terminal.app path fragile.
enum DeckBridge {

    static let bundleID = "org.sensubeans.terminaldeck"

    /// Is the deck installed at all? Gates the Configurations toggle, so the
    /// setting can't be switched to a host that doesn't exist.
    static var isInstalled: Bool { appURL != nil }

    static var appURL: URL? {
        NSWorkspace.shared.urlForApplication(withBundleIdentifier: bundleID)
    }

    static var isRunning: Bool {
        !NSRunningApplication.runningApplications(withBundleIdentifier: bundleID).isEmpty
    }

    /// The deck's per-launch capability token, written owner-readable into its
    /// Application Support directory. Any action that starts a process carries
    /// it, so a stray `terminaldeck://run?cmd=…` from a web page is refused —
    /// see the deck's own `DeckBridge` for the reasoning.
    private static var token: String? {
        let url = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent("Library/Application Support/TerminalDeck/bridge-token")
        guard let s = try? String(contentsOf: url, encoding: .utf8) else { return nil }
        let trimmed = s.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }

    // MARK: - Actions

    /// Raise the deck, focused on a Claude session if one is named.
    @discardableResult
    static func open(sessionID: String? = nil) -> Bool {
        var q: [URLQueryItem] = []
        if let sessionID, !sessionID.isEmpty { q.append(.init(name: "session", value: sessionID)) }
        return send(verb: "open", query: q, needsToken: false)
    }

    /// A fresh login shell in `cwd`.
    @discardableResult
    static func newSession(cwd: String? = nil) -> Bool {
        var q: [URLQueryItem] = []
        if let cwd, !cwd.isEmpty { q.append(.init(name: "cwd", value: cwd)) }
        return send(verb: "new", query: q)
    }

    /// Run a command in a new deck session — how a dev server starts when the
    /// deck is the chosen host: visible in a real pane, with its output on
    /// screen and Ctrl-C available, instead of a detached child logging to a
    /// file nobody opens.
    @discardableResult
    static func run(command: String, cwd: String?, title: String?) -> Bool {
        var q = [URLQueryItem(name: "cmd", value: command)]
        if let cwd, !cwd.isEmpty { q.append(.init(name: "cwd", value: cwd)) }
        if let title, !title.isEmpty { q.append(.init(name: "title", value: title)) }
        return send(verb: "run", query: q)
    }

    // MARK: - Plumbing

    private static func send(verb: String, query: [URLQueryItem],
                             needsToken: Bool = true) -> Bool {
        guard isInstalled else { return false }
        var comps = URLComponents()
        comps.scheme = "terminaldeck"
        comps.host = verb
        var items = query
        if needsToken {
            guard let token else { return false }   // no token ⇒ the deck would refuse anyway
            items.append(.init(name: "token", value: token))
        }
        comps.queryItems = items
        guard let url = comps.url else { return false }
        NSWorkspace.shared.open(url)
        return true
    }
}
