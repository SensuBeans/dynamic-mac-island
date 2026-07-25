import Foundation

/// One correct way to run a child process.
///
/// Three mistakes this exists to prevent, all of which shipped at least once:
///
///   * **Waiting before draining.** A child that writes more than the 64 KiB
///     pipe buffer blocks in `write`, and a parent sitting in `waitUntilExit`
///     never drains it — both sides wedge forever. Draining stdout *then*
///     stderr sequentially has the same failure on the second pipe, so both
///     are read concurrently here.
///   * **No timeout.** One hung Apple Event (Terminal busy, an undismissed
///     permission dialog) otherwise wedges a serial queue for the rest of the
///     process lifetime.
///   * **Discarding the exit status and stderr**, which turns every launch
///     failure into a silent no-op with nothing to show the user.
enum Subprocess {

    struct Result {
        var out: String
        var err: String
        var status: Int32
        /// True when the child overran its deadline and was killed.
        var timedOut: Bool

        /// Exited cleanly and in time. Callers that only care whether the work
        /// happened should test this rather than `status` alone.
        var ok: Bool { status == 0 && !timedOut }

        /// The most useful one-line explanation of a failure, for surfacing in
        /// the UI. Empty when `ok`.
        var failureReason: String? {
            if ok { return nil }
            if timedOut { return "timed out" }
            let firstErrLine = err.split(separator: "\n").first.map(String.init)
            return firstErrLine?.trimmingCharacters(in: .whitespaces).nilIfEmpty
                ?? "exited \(status)"
        }
    }

    private static let drainQueue = DispatchQueue(
        label: "com.sensubeans.notchbook.subprocess", attributes: .concurrent)

    /// Runs a child to completion (or to `timeout`) and returns everything the
    /// caller needs to explain a failure. Never traps and never throws: a
    /// launch failure comes back as `status == -1` with the reason in `err`.
    @discardableResult
    static func run(_ launchPath: String,
                    _ args: [String],
                    timeout: TimeInterval = 15,
                    environment: [String: String]? = nil) -> Result {
        let p = Process()
        p.executableURL = URL(fileURLWithPath: launchPath)
        p.arguments = args
        if let environment { p.environment = environment }
        let outPipe = Pipe(), errPipe = Pipe()
        p.standardOutput = outPipe
        p.standardError = errPipe

        do { try p.run() } catch {
            return Result(out: "", err: "\(error)", status: -1, timedOut: false)
        }

        // Both pipes are drained on their own queue so neither can back up
        // while the other is being read.
        var outData = Data(), errData = Data()
        let lock = NSLock()
        let group = DispatchGroup()
        for (pipe, isOut) in [(outPipe, true), (errPipe, false)] {
            group.enter()
            drainQueue.async {
                let d = pipe.fileHandleForReading.readDataToEndOfFile()
                lock.lock()
                if isOut { outData = d } else { errData = d }
                lock.unlock()
                group.leave()
            }
        }

        var timedOut = false
        if group.wait(timeout: .now() + timeout) == .timedOut {
            timedOut = true
            p.terminate()                                   // SIGTERM
            if group.wait(timeout: .now() + 1) == .timedOut {
                kill(p.processIdentifier, SIGKILL)          // uncatchable backstop
                _ = group.wait(timeout: .now() + 1)
            }
        }
        p.waitUntilExit()   // safe now: the pipes are closed, so this returns

        return Result(out: String(decoding: outData, as: UTF8.self),
                      err: String(decoding: errData, as: UTF8.self),
                      status: p.terminationStatus,
                      timedOut: timedOut)
    }

    /// `osascript -e <source> [args…]`. AppleScript against another app can
    /// block indefinitely when the target is busy, so the default deadline is
    /// deliberately short.
    @discardableResult
    static func osascript(_ source: String,
                          _ args: [String] = [],
                          timeout: TimeInterval = 10) -> Result {
        run("/usr/bin/osascript", ["-e", source] + args, timeout: timeout)
    }

    /// A login shell, which is what dev-server launch lines assume (they need
    /// the user's PATH from their profile).
    @discardableResult
    static func loginShell(_ command: String, timeout: TimeInterval = 15) -> Result {
        run("/bin/zsh", ["-lc", command], timeout: timeout)
    }
}

private extension String {
    var nilIfEmpty: String? { isEmpty ? nil : self }
}
