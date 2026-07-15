import Darwin
import Foundation

/// Where a Claude Code session's terminal is hosted — resolved from the process
/// tree, drives the row's label and which controls can actually work.
enum TerminalHost: Equatable {
    /// Terminal.app — scriptable by tty (focus/approve via Apple Events).
    case terminalApp
    /// A shell running inside the island's own built-in Terminal tab. Carries
    /// the matched `TerminalSessionsModel` session so Open can select it and
    /// Approve can write straight to its PTY.
    case notch(sessionID: UUID)
    /// Any other recognizable hosting app (iTerm2, Code, WezTerm, …). We can
    /// activate the app but not script its tabs — Open only, no Approve.
    case other(String)
    /// No controlling tty (headless `-p` run) or an unrecognized host — no
    /// terminal actions apply.
    case none
}

/// A session's resolved terminal identity: its controlling tty (short form for
/// display) and hosting app. Resolved once per pid via `sysctl` only — no `ps`,
/// no AppleScript, nothing that spawns a process on the 1.5 s rebuild tick.
///
/// Why `sysctl(KERN_PROC_PID)` and not `proc_pidinfo`: the parent chain from a
/// shell up to Terminal.app passes through a root-owned `login` process, and
/// `proc_pidinfo(PROC_PIDTBSDINFO)` short-reads (EPERM) on a process owned by
/// another user — so the walk would stall before ever reaching the host app.
/// `sysctl`'s kern.proc table is world-readable (it's how `ps` works unprivileged)
/// and hands back ppid, controlling tty (`e_tdev`) and comm in one call.
struct TerminalIdentity: Equatable {
    /// Short controlling-tty name, e.g. `"ttys003"`. `nil` when the process has
    /// no controlling terminal. The full path for control is `/dev/<tty>`.
    var tty: String?
    var host: TerminalHost

    static let none = TerminalIdentity(tty: nil, host: .none)

    /// Resolve `pid`'s controlling tty and hosting app.
    ///
    /// - `selfPid`: this app's own pid (`getpid()`), so a session launched inside
    ///   the island's built-in terminal is recognized as `.notch`.
    /// - `builtinShellPids`: the island's live built-in shells `(sessionID, pid)`,
    ///   used to pick the exact built-in session a `.notch` Claude belongs to.
    static func resolve(pid: Int32, selfPid: Int32,
                        builtinShellPids: [(UUID, Int32)]) -> TerminalIdentity {
        guard let first = kinfo(pid) else { return .none }
        let tty = ttyName(first.kp_eproc.e_tdev)

        // Walk parents (bounded), collecting the lineage, until we reach the
        // island (→ .notch), launchd (→ the top-level hosting app), or the cap.
        var lineage: [Int32] = [pid]
        var current = first
        var topName: String?
        var hitNotch = false
        for _ in 0..<24 {
            let ppid = current.kp_eproc.e_ppid
            if ppid == selfPid { hitNotch = true; break }
            if ppid <= 1 { topName = comm(current); break }   // current = launchd's child
            guard let parent = kinfo(ppid) else { topName = comm(current); break }
            lineage.append(ppid)
            current = parent
        }

        if hitNotch {
            // The built-in session whose shell is (or is an ancestor of) this pid.
            let ancestry = Set(lineage)
            if let match = builtinShellPids.first(where: { ancestry.contains($0.1) }) {
                return TerminalIdentity(tty: tty, host: .notch(sessionID: match.0))
            }
            // Inside the island but no built-in session matched (a transient race
            // before the shell list bubbled in) — return fully-unresolved so the
            // caller declines to cache it and the next tick re-resolves, rather
            // than latching a wrong host for the pid's lifetime.
            return .none
        }

        guard tty != nil else { return TerminalIdentity(tty: nil, host: .none) }
        if let name = topName {
            return name == "Terminal"
                ? TerminalIdentity(tty: tty, host: .terminalApp)
                : TerminalIdentity(tty: tty, host: .other(name))
        }
        return TerminalIdentity(tty: tty, host: .none)
    }

    // MARK: - sysctl helpers

    /// `kinfo_proc` for a pid via the world-readable kern.proc table. `nil` if the
    /// process is gone (`size` comes back 0).
    private static func kinfo(_ pid: Int32) -> kinfo_proc? {
        var mib: [Int32] = [CTL_KERN, KERN_PROC, KERN_PROC_PID, pid]
        var info = kinfo_proc()
        var size = MemoryLayout<kinfo_proc>.stride
        let r = sysctl(&mib, UInt32(mib.count), &info, &size, nil, 0)
        return (r == 0 && size > 0) ? info : nil
    }

    /// The process's accounting name (`p_comm`, ≤16 chars: "Terminal", "iTerm2").
    private static func comm(_ k: kinfo_proc) -> String {
        var proc = k.kp_proc
        return withUnsafeBytes(of: &proc.p_comm) { raw in
            String(cString: raw.bindMemory(to: CChar.self).baseAddress!)
        }
    }

    /// Controlling-tty short name (`"ttys003"`) from a `dev_t`. `nil` for `NODEV`.
    private static func ttyName(_ dev: dev_t) -> String? {
        guard dev != -1, dev != 0 else { return nil }   // NODEV / none
        guard let c = devname(dev, mode_t(S_IFCHR)) else { return nil }
        let name = String(cString: c)
        return name.isEmpty ? nil : name
    }
}
