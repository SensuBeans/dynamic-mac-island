import AppKit
import Combine
import SwiftTerm

/// Owns the real interactive shell sessions hosted in the Terminal tab.
///
/// CRITICAL — same lesson as the camera preview layer: the terminal views live
/// HERE, in the model, created once per session and never recreated. The
/// SwiftUI layer only *hosts* the current session's existing view. If SwiftUI
/// rebuilt the views per render, sessions would lose scrollback and PTY state.
/// Sessions keep running while the island is collapsed or on another tab —
/// that is the whole point (long-running commands).
final class TerminalSessionsModel: ObservableObject {
    struct Session: Identifiable {
        let id = UUID()
        var title: String
        var isAlive = true
        /// The persistent terminal view + its PTY and process. A reference
        /// type, so copying the struct never duplicates the session.
        let view: LocalProcessTerminalView
    }

    @Published var sessions: [Session] = []
    @Published var selectedID: UUID?

    static let maxSessions = 6

    var selected: Session? { sessions.first { $0.id == selectedID } }

    private var loginShell: String {
        ProcessInfo.processInfo.environment["SHELL"] ?? "/bin/zsh"
    }

    /// Spawn a fresh login shell. Capped at `maxSessions`; the new session
    /// becomes selected.
    func newSession() {
        guard sessions.count < Self.maxSessions else { return }
        let view = LocalProcessTerminalView(frame: CGRect(x: 0, y: 0, width: 620, height: 300))
        view.processDelegate = self

        // Apple-native look: system mono, light-on-dark. The background is
        // clear so the island's glass shows through; a flat scrim behind the
        // terminal area (in the SwiftUI layer) keeps text legible over the
        // ambient album glow.
        view.font = NSFont.monospacedSystemFont(ofSize: 11, weight: .regular)
        view.nativeForegroundColor = NSColor(calibratedWhite: 0.92, alpha: 1)
        view.nativeBackgroundColor = .clear
        view.caretColor = NSColor(calibratedWhite: 0.95, alpha: 1)

        let shell = loginShell
        let env = Terminal.getEnvironmentVariables(termName: "xterm-256color", trueColor: true)
        view.startProcess(executable: shell,
                          args: ["-l"],
                          environment: env,
                          currentDirectory: FileManager.default.homeDirectoryForCurrentUser.path)

        sessions.append(Session(title: (shell as NSString).lastPathComponent, view: view))
        selectedID = sessions.last?.id
    }

    /// Send a carriage return to a built-in session's shell — accepts the
    /// highlighted (default) option of a Claude Code permission prompt running
    /// inside the island's own Terminal tab, the in-app analogue of
    /// `AgentTerminalControl.approve`.
    func sendReturn(to id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }), session.isAlive else { return }
        session.view.send(txt: "\r")
    }

    /// Auto-resume a Claude session running inside this built-in tab after a
    /// usage-limit reset: clear any half-typed line (Ctrl-U, `\u{15}`) then type
    /// `continue` + Return straight to the PTY. The clear rides in the same write
    /// so a leftover partial prompt is never submitted as `<partial>continue`.
    func resume(id: UUID) {
        guard let session = sessions.first(where: { $0.id == id }), session.isAlive else { return }
        session.view.send(txt: "\u{15}continue\r")
    }

    /// Terminate a session's shell and drop it, reselecting a neighbour.
    func closeSession(id: UUID) {
        guard let idx = sessions.firstIndex(where: { $0.id == id }) else { return }
        signal(sessions[idx].view, SIGHUP)
        sessions[idx].view.terminate()   // closes the PTY fds + SIGTERM
        sessions.remove(at: idx)
        if selectedID == id {
            selectedID = sessions.isEmpty ? nil
                : sessions[min(idx, sessions.count - 1)].id
        }
    }

    /// SIGHUP every live shell and close its PTY — called from
    /// `applicationWillTerminate` so quitting leaves no orphaned shells.
    func shutdown() {
        for session in sessions {
            signal(session.view, SIGHUP)
            signal(session.view, SIGKILL)
            session.view.terminate()
        }
        sessions.removeAll()
    }

    private func signal(_ view: LocalProcessTerminalView, _ sig: Int32) {
        let pid = view.process.shellPid
        if pid > 0 { kill(pid, sig) }
    }
}

extension TerminalSessionsModel: LocalProcessTerminalViewDelegate {
    func sizeChanged(source: LocalProcessTerminalView, newCols: Int, newRows: Int) {}

    func setTerminalTitle(source: LocalProcessTerminalView, title: String) {
        // The shell's title escape names the chip; ignore empty titles so the
        // fallback (the shell name) stays put.
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty,
              let idx = sessions.firstIndex(where: { $0.view === source }) else { return }
        sessions[idx].title = trimmed
    }

    func hostCurrentDirectoryUpdate(source: TerminalView, directory: String?) {}

    func processTerminated(source: TerminalView, exitCode: Int32?) {
        guard let idx = sessions.firstIndex(where: { $0.view === source }) else { return }
        sessions[idx].isAlive = false
    }
}
