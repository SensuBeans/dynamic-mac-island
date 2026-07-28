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

extension TerminalHost {
    /// Hosted inside Terminal Deck. The deck is a separate app, so the process
    /// walk lands on `.other` with the deck's accounting name — but the island
    /// CAN drive it (focus the exact pane over `terminaldeck://`), which plain
    /// `.other` hosts don't allow. Matching on `p_comm` keeps this a pure
    /// process-tree fact, no bundle lookup on the rebuild tick.
    var isDeck: Bool {
        if case .other(let app) = self { return app == "TerminalDeck" }
        return false
    }
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
        var currentPid = pid
        var topName: String?
        var topPid: Int32 = 0
        var hitNotch = false
        for _ in 0..<24 {
            let ppid = current.kp_eproc.e_ppid
            if ppid == selfPid { hitNotch = true; break }
            if ppid <= 1 {                                   // current = launchd's child
                topName = comm(current); topPid = currentPid; break
            }
            guard let parent = kinfo(ppid) else {
                topName = comm(current); topPid = currentPid; break
            }
            lineage.append(ppid)
            current = parent
            currentPid = ppid
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
            if name == "Terminal" { return TerminalIdentity(tty: tty, host: .terminalApp) }
            // A deck pane's shell is no longer a child of the deck: since the
            // deck moved its panes onto a private tmux server so they survive a
            // relaunch, the walk from `claude` goes shell → tmux server →
            // launchd, and the deck is a SIBLING of that server, never an
            // ancestor. So the honest top-level name is "tmux", and every deck
            // session was landing here as a generic `.other("tmux")` — which
            // means no Approve, no auto-resume, and an Open button that tried to
            // activate an app called tmux and did nothing at all.
            //
            // The server's own argv says whose it is (`-L deck` is the deck's
            // private socket), and argv is readable with a syscall — no spawn, so
            // this still holds the rule that identity resolution never shells out.
            if name == "tmux", isDeckTmuxServer(topPid) {
                return TerminalIdentity(tty: tty, host: .other("TerminalDeck"))
            }
            return TerminalIdentity(tty: tty, host: .other(name))
        }
        return TerminalIdentity(tty: tty, host: .none)
    }

    /// The deck's private tmux socket, mirrored from `DeckSessionsModel.tmuxSocket`.
    /// A copy rather than a shared constant for the same reason the deck's port of
    /// this file is a copy: the two apps are not a shared dependency yet.
    private static let deckTmuxSocket = "deck"

    /// Is `pid` the tmux server backing Terminal Deck's panes?
    ///
    /// Matches `-L deck` as two ADJACENT argv elements, which is what the deck
    /// passes. Argument vectors are null-separated in the `KERN_PROCARGS2` blob,
    /// so the flag and its value are the exact byte run `-L\0deck\0` — a plain
    /// substring search would also match a directory called `…-L deck…` in some
    /// unrelated tmux's command line.
    private static func isDeckTmuxServer(_ pid: Int32) -> Bool {
        guard pid > 0, let blob = procArgs(pid) else { return false }
        var needle = Array("-L".utf8); needle.append(0)
        needle.append(contentsOf: Array(deckTmuxSocket.utf8)); needle.append(0)
        guard blob.count >= needle.count else { return false }
        for start in 0...(blob.count - needle.count) {
            if Array(blob[start..<(start + needle.count)]) == needle { return true }
        }
        return false
    }

    /// Raw `KERN_PROCARGS2` bytes for a pid, or nil. World-readable for processes
    /// owned by the same user, which every tmux server we care about is.
    private static func procArgs(_ pid: Int32) -> [UInt8]? {
        var mib: [Int32] = [CTL_KERN, KERN_PROCARGS2, pid]
        var size = 0
        guard sysctl(&mib, 3, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buf = [UInt8](repeating: 0, count: size)
        guard sysctl(&mib, 3, &buf, &size, nil, 0) == 0 else { return nil }
        return Array(buf.prefix(size))
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
