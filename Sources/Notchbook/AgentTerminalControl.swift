import Foundation

/// Locates the Terminal.app tab that owns a Claude Code session (by the
/// session process's controlling tty) and either raises it or sends it a
/// Return — the latter accepts the default option of a permission prompt.
///
/// Uses Automation (Apple Events) only, targeting the specific tab by tty, so a
/// keystroke can never land in the wrong window the way a global synthetic
/// keypress could. First use triggers the one-time "control Terminal" prompt.
///
/// Terminal.app only for now — iTerm2/others would match `tty` the same way via
/// their own scripting dictionaries.
enum AgentTerminalControl {

    /// Result of a control attempt, so the caller can surface a "tab not found"
    /// toast instead of a silent no-op.
    enum Outcome { case ok, notFound, noTTY }

    /// The session process's controlling terminal → `/dev/ttysNNN`. Fallback for
    /// when the model hasn't resolved the tty yet; the syscall path in
    /// `TerminalIdentity` is preferred and spawns nothing.
    static func tty(forPID pid: Int) -> String? {
        guard let raw = runProcess("/bin/ps", ["-o", "tty=", "-p", "\(pid)"])?
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !raw.isEmpty, raw != "??", raw != "?" else { return nil }
        return raw.hasPrefix("/dev/") ? raw : "/dev/\(raw)"
    }

    /// Raise Terminal, its window, and select the tab owning `pid`. Prefers the
    /// already-resolved `ttyPath` (`/dev/ttysNNN`); spawns `ps` only if it's nil.
    @discardableResult
    static func focus(pid: Int, ttyPath: String? = nil) -> Outcome {
        run(script: Self.focusScript, pid: pid, ttyPath: ttyPath)
    }

    /// Send a Return to the tab owning `pid` — selects the highlighted (default,
    /// "allow once") option of a Claude Code permission prompt. Does not steal
    /// focus; the keystroke goes straight to that tab's tty.
    @discardableResult
    static func approve(pid: Int, ttyPath: String? = nil) -> Outcome {
        run(script: Self.approveScript, pid: pid, ttyPath: ttyPath)
    }

    private static func run(script: String, pid: Int, ttyPath: String?) -> Outcome {
        guard let tty = ttyPath ?? tty(forPID: pid) else { return .noTTY }
        let out = runOSA(script: script, arg: tty)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return out == "ok" ? .ok : .notFound
    }

    // MARK: - AppleScript

    private static let focusScript = """
    on run argv
      set targetTTY to item 1 of argv
      tell application "Terminal"
        repeat with w in windows
          repeat with t in tabs of w
            if tty of t is targetTTY then
              set selected of t to true
              set index of w to 1
              activate
              return "ok"
            end if
          end repeat
        end repeat
      end tell
      return "notfound"
    end run
    """

    private static let approveScript = """
    on run argv
      set targetTTY to item 1 of argv
      tell application "Terminal"
        repeat with w in windows
          repeat with t in tabs of w
            if tty of t is targetTTY then
              do script "" in t
              return "ok"
            end if
          end repeat
        end repeat
      end tell
      return "notfound"
    end run
    """

    // MARK: - Process helpers

    @discardableResult
    private static func runOSA(script: String, arg: String) -> String? {
        runProcess("/usr/bin/osascript", ["-e", script, arg])
    }

    private static func runProcess(_ launchPath: String, _ args: [String]) -> String? {
        let task = Process()
        task.executableURL = URL(fileURLWithPath: launchPath)
        task.arguments = args
        let pipe = Pipe()
        task.standardOutput = pipe
        task.standardError = FileHandle.nullDevice
        do { try task.run() } catch { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        task.waitUntilExit()
        return String(data: data, encoding: .utf8)
    }
}
