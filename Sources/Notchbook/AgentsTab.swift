import AppKit
import SwiftUI

// MARK: - Agents

/// Live view of running Claude Code sessions. Pure transcript tailing — the
/// model does the parsing; this tab just renders per-session rows in the
/// existing dark-glass idiom (see TabViews.swift: StatTile / progressBar).
struct AgentsTab: View {
    @EnvironmentObject var agents: AgentSessionsModel
    @EnvironmentObject var state: NotchState
    @EnvironmentObject var terminals: TerminalSessionsModel

    /// One shared clock so every row's "time-in-state" and context freshness
    /// advance together without a timer per row.
    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        VStack(spacing: 8) {
            // Account usage limits sit above everything — the 5-hour session
            // window and the weekly window (hidden until the statusline has
            // written them at least once).
            if let usage = agents.usage, !usage.isEmpty {
                UsageHeader(usage: usage, now: now)
            }
            sessionList
        }
        .onReceive(timer) { now = $0 }
        .onAppear { agents.acknowledgeCompletes() }
    }

    @ViewBuilder
    private var sessionList: some View {
        if agents.sessions.isEmpty {
            emptyState
        } else {
            // Always a ScrollView so any overflow scrolls; when the rows fit, it
            // simply doesn't scroll. maxHeight:.infinity bounds the scroll region.
            ScrollView(showsIndicators: true) {
                VStack(spacing: 6) { rows }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
    }

    private var rows: some View {
        ForEach(agents.sessions) { session in
            AgentRow(session: session, now: now)
        }
    }

    private var emptyState: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "sparkles")
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.25))
            Text("No Claude Code sessions running")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            // Neutral launch button (not an accent fill — green/amber/orange are
            // reserved for session state in this tab). Opens the notch's own
            // terminal so a `claude` started there comes back as a .notch row.
            LaunchButton(icon: "plus", label: "Launch Terminal") {
                state.currentTab = .terminal
                terminals.newSession()
            }
            .help("New terminal in the notch — start a Claude session")
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Usage header (account rate limits)

/// The 5-hour "session" window and the weekly window, side by side. Each is a
/// thin meter that ramps amber→red as the account approaches its limit, with a
/// reset countdown. Mirrors the statusline's own session/weekly readout.
private struct UsageHeader: View {
    let usage: AgentUsage
    let now: Date

    var body: some View {
        HStack(spacing: 10) {
            meter(title: "SESSION", pct: usage.sessionPct, resetsAt: usage.sessionResetsAt)
            meter(title: "WEEKLY", pct: usage.weeklyPct, resetsAt: usage.weeklyResetsAt)
        }
    }

    @ViewBuilder
    private func meter(title: String, pct: Int?, resetsAt: Date?) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            HStack(spacing: 5) {
                Text(title)
                    .font(.system(size: 8, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.4))
                    .kerning(0.5)
                Spacer(minLength: 2)
                if let reset = resetsCountdown(resetsAt) {
                    Text(reset)
                        .font(.system(size: 8))
                        .foregroundStyle(.white.opacity(0.35))
                        .monospacedDigit()
                }
                Text(pct.map { "\($0)%" } ?? "—")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(tint(pct))
                    .monospacedDigit()
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.14)).frame(height: 4)
                    Capsule().fill(tint(pct))
                        .frame(width: max(2, geo.size.width * CGFloat(pct ?? 0) / 100),
                               height: 4)
                }
                .frame(height: geo.size.height, alignment: .center)
            }
            .frame(height: 4)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity)
        .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(0.06)))
    }

    /// Higher usage = closer to the ceiling = hotter. Matches the context-meter
    /// thresholds elsewhere (amber ≥70, red ≥90).
    private func tint(_ pct: Int?) -> Color {
        guard let pct else { return .white.opacity(0.5) }
        if pct >= 90 { return .red }
        if pct >= 70 { return .orange }
        return .white.opacity(0.85)
    }

    private func resetsCountdown(_ date: Date?) -> String? {
        guard let date else { return nil }
        let secs = Int(date.timeIntervalSince(now))
        guard secs > 0 else { return nil }
        let d = secs / 86_400, h = (secs % 86_400) / 3600, m = (secs % 3600) / 60
        if d > 0 { return "resets \(d)d \(h)h" }
        if h > 0 { return "resets \(h)h \(m)m" }
        return "resets \(m)m"
    }
}

// MARK: - Row

private struct AgentRow: View {
    @EnvironmentObject var agents: AgentSessionsModel
    @EnvironmentObject var terminals: TerminalSessionsModel
    @EnvironmentObject var state: NotchState
    let session: AgentSession
    let now: Date

    @State private var hovered = false
    /// Auto-resume chip: showing the "undo" grace after a cancel click, plus the
    /// pending work item that consumes the cancel when the grace lapses.
    @State private var resumeCancelling = false
    @State private var resumeCancelWork: DispatchWorkItem?

    var body: some View {
        HStack(spacing: 10) {
            // State glyph, tinted by the state. A working session gets a
            // gentle pulse so the row reads as live at a glance.
            Image(systemName: session.state.glyph)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(session.state.tint)
                .frame(width: 16)
                .opacity(session.state == .working ? pulse : 1)
                .animation(session.state == .working
                           ? .easeInOut(duration: 0.8).repeatForever(autoreverses: true)
                           : .default,
                           value: pulse)
                // Rows are reused by id across state changes, so .onAppear alone
                // misses idle→working; drive the pulse off the state directly.
                .onAppear { pulse = session.state == .working ? 0.35 : 1 }
                .onChange(of: session.state) { pulse = $0 == .working ? 0.35 : 1 }

            VStack(alignment: .leading, spacing: 3) {
                // Project + dim branch, then model badge trailing.
                HStack(spacing: 6) {
                    Text(session.project)
                        .font(.system(size: 12, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.9))
                        .lineLimit(1)
                        .truncationMode(.middle)
                    // Session name ("core-00") — the primary discriminator when
                    // several sessions share one cwd (the user's parallel-terminal
                    // workflow). Dim + mono so it reads as an identifier, distinct
                    // from the branch beside it.
                    if let name = session.name, name != session.project {
                        Text(name)
                            .font(.system(size: 10, design: .monospaced))
                            .foregroundStyle(.white.opacity(0.5))
                            .lineLimit(1)
                            .fixedSize()
                    }
                    if let branch = session.gitBranch {
                        Text(branch)
                            .font(.system(size: 10))
                            .foregroundStyle(.white.opacity(0.35))
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    modelBadge
                }

                // State label + time-in-state, or output tokens on hover.
                HStack(spacing: 5) {
                    if hovered {
                        Text("↑ \(tokenString(session.outputTokens)) out")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.5))
                            .monospacedDigit()
                    } else {
                        Text(session.state.label)
                            .font(.system(size: 9, weight: .medium))
                            .foregroundStyle(session.state.tint.opacity(0.9))
                        Text("· \(timeInState)")
                            .font(.system(size: 9))
                            .foregroundStyle(.white.opacity(0.4))
                            .monospacedDigit()
                    }
                    terminalTag
                    Spacer(minLength: 4)
                    contextLabel
                }

                contextMeter
            }

            actions
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 9).fill(.white.opacity(hovered ? 0.09 : 0.06)))
        .opacity(session.state == .idle ? 0.55 : 1)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .help(session.cwd)
    }

    // Working-state pulse target (animates between 0.35 and 1).
    @State private var pulse: Double = 1

    /// The session's terminal identity — a small mono tty tag (`⌗ ttys003`) or
    /// `notch` for a session hosted in the island's own Terminal tab. Nothing for
    /// a headless / unknown host (`.none`).
    @ViewBuilder
    private var terminalTag: some View {
        if let tag = terminalTagText {
            HStack(spacing: 2) {
                Image(systemName: tag.symbol).font(.system(size: 8))
                Text(tag.text).font(.system(size: 9, design: .monospaced))
            }
            .foregroundStyle(.white.opacity(0.4))
            .padding(.leading, 4)
        }
    }

    private var terminalTagText: (symbol: String, text: String)? {
        switch session.host {
        case .notch:                       return ("sparkle", "notch")
        case .terminalApp, .other:         return session.tty.map { ("terminal", $0) }
        case .none:                        return nil
        }
    }

    /// Whether a green Approve makes sense: only hosts we can actually send a
    /// Return to — Terminal.app (Apple Events) or the built-in notch tab (PTY).
    private var canApprove: Bool {
        switch session.host {
        case .terminalApp, .notch: return true
        case .other, .none:        return false
        }
    }

    /// Whether Open can do anything: Terminal.app tab, the notch tab, or (as an
    /// activate-the-app fallback) another recognized host. Not for `.none`.
    private var canOpen: Bool {
        session.pid != nil && session.host != .none
    }

    /// Trailing actions, host-aware. A waiting session gets a prominent green
    /// Approve (only where a Return can land); any hosted session gets Open. For
    /// `.other` Open just activates the app; for `.none` no buttons render, so a
    /// headless session shows no dead controls.
    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 5) {
            autoResumeChip
            if session.state == .waiting, canApprove {
                Button { approve() } label: {
                    Image(systemName: "checkmark")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(.black)
                        .frame(width: 30, height: 22)
                        .background(Capsule().fill(.green))
                }
                .buttonStyle(.plain)
                .help("Approve — send Return to accept the prompt")
            }
            if canOpen, hovered || session.needsAttention {
                Button { open() } label: {
                    Image(systemName: "arrow.up.forward")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 30, height: 22)
                        .background(Capsule().fill(.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help(openHelp)
            }
        }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: session.autoResumeAt)
        .animation(.spring(response: 0.3, dampingFraction: 0.75), value: resumeCancelling)
    }

    private var openHelp: String {
        if case .other(let app) = session.host { return "Open \(app)" }
        return "Jump to this session's terminal"
    }

    // MARK: Auto-resume chip

    /// Auto-resume can only ever fire on a host we can type into.
    private var hostAutoTypeable: Bool {
        switch session.host {
        case .terminalApp, .notch: return true
        case .other, .none:        return false
        }
    }

    /// Trailing auto-resume affordance. On auto-typeable hosts: a dim ⚡ when not
    /// armed (display-only, revealed on hover like the other inactive controls);
    /// an amber countdown capsule when armed (always visible — a countdown must be
    /// seen). Clicking the armed capsule flips to a ~5 s "undo" grace before the
    /// cancel actually reaches the model. Hidden entirely on `.other`/`.none`.
    @ViewBuilder
    private var autoResumeChip: some View {
        if hostAutoTypeable {
            if let fireAt = session.autoResumeAt {
                Button { toggleResumeCancel() } label: {
                    if resumeCancelling { cancellingCapsule } else { armedCapsule(fireAt) }
                }
                .buttonStyle(.plain)
                .help(resumeCancelling
                      ? "Auto-resume cancelled — click to undo"
                      : "Auto-resumes at \(Self.clock.string(from: fireAt)) — click to cancel")
                .transition(.scale.combined(with: .opacity))
            } else if hovered {
                Image(systemName: "bolt.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.35))
                    .frame(width: 20, height: 22)
                    .help("Auto-resume — arms if this session is cut off by the usage limit")
            }
        }
    }

    private func armedCapsule(_ fireAt: Date) -> some View {
        HStack(spacing: 3) {
            Image(systemName: "bolt.fill").font(.system(size: 8, weight: .bold))
            Text(resumeCountdown(fireAt))
                .font(.system(size: 9, weight: .medium))
                .monospacedDigit()
        }
        .foregroundStyle(Self.amber)
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(Capsule().fill(Self.amber.opacity(0.13)))
        .overlay(Capsule().stroke(Self.amber.opacity(0.55), lineWidth: 1))
    }

    private var cancellingCapsule: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.uturn.backward").font(.system(size: 8, weight: .bold))
            Text("undo").font(.system(size: 9, weight: .medium))
        }
        .foregroundStyle(.white.opacity(0.6))
        .padding(.horizontal, 7)
        .frame(height: 22)
        .background(Capsule().fill(.white.opacity(0.1)))
    }

    /// First click on the armed capsule ⇒ show "undo" and start a 5 s grace; the
    /// model stays armed the whole time. Grace lapses ⇒ tell the model to cancel.
    /// Click again within grace ⇒ just cancel the pending work, back to armed.
    private func toggleResumeCancel() {
        if resumeCancelling {
            resumeCancelWork?.cancel()
            resumeCancelWork = nil
            resumeCancelling = false
        } else {
            let id = session.id
            // Too close to fire time for the undo grace to be safe: the wall-clock
            // fire timer would beat a 5 s-delayed cancel and resume anyway. Cancel
            // NOW (a brief "cancelled" flash instead of an undo window).
            if let fireAt = session.autoResumeAt, fireAt.timeIntervalSince(now) < 6 {
                agents.cancelAutoResume(id)
                resumeCancelling = true
                let flash = DispatchWorkItem {
                    resumeCancelling = false
                    resumeCancelWork = nil
                }
                resumeCancelWork = flash
                DispatchQueue.main.asyncAfter(deadline: .now() + 1.2, execute: flash)
                return
            }
            resumeCancelling = true
            let work = DispatchWorkItem {
                agents.cancelAutoResume(id)
                resumeCancelling = false
                resumeCancelWork = nil
            }
            resumeCancelWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 5, execute: work)
        }
    }

    /// "resuming in 42m" under an hour, else "resuming at 5:00 PM". Ticks off the
    /// tab's shared `now`.
    private func resumeCountdown(_ fireAt: Date) -> String {
        let secs = Int(fireAt.timeIntervalSince(now))
        if secs <= 0 { return "resuming…" }
        if secs < 3600 { return "resuming in \(max(1, (secs + 59) / 60))m" }
        return "resuming at \(Self.clock.string(from: fireAt))"
    }

    private static let amber = Color(red: 0.98, green: 0.74, blue: 0.20)
    private static let clock: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "h:mm a"; return f
    }()

    // MARK: Host-aware actions

    /// Jump to the session's terminal. Terminal.app raises the tab (toast if it's
    /// gone); the notch switches to its Terminal tab and selects the session;
    /// `.other` activates the hosting app as a best-effort fallback.
    private func open() {
        switch session.host {
        case .terminalApp:
            agents.focus(session) { missed in if missed { missedToast() } }
        case .notch(let sid):
            state.currentTab = .terminal
            terminals.selectedID = sid
        case .other(let app):
            activateApp(named: app)
        case .none:
            break
        }
    }

    /// Answer the pending permission prompt in place — Return to the Terminal.app
    /// tab, or a carriage return straight to the built-in notch session's PTY.
    private func approve() {
        switch session.host {
        case .terminalApp:
            agents.approve(session) { missed in if missed { missedToast() } }
        case .notch(let sid):
            terminals.sendReturn(to: sid)
        case .other, .none:
            break
        }
    }

    private func missedToast() {
        state.showToast(NotchToast(icon: "terminal", title: "Terminal tab not found",
                                   color: .gray))
    }

    /// Best-effort activate a recognized non-scriptable host app (iTerm2, Code…).
    private func activateApp(named app: String) {
        let match = NSWorkspace.shared.runningApplications.first {
            $0.activationPolicy == .regular &&
            ($0.localizedName == app || $0.executableURL?.lastPathComponent == app)
        }
        match?.activate(options: [.activateIgnoringOtherApps])
    }

    private var modelBadge: some View {
        Text(session.modelDisplay)
            .font(.system(size: 8.5, weight: .semibold))
            .foregroundStyle(.white.opacity(0.7))
            .lineLimit(1)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(Capsule().fill(.white.opacity(0.1)))
    }

    // MARK: Context meter

    /// Fraction of the context window in use, clamped 0…1. nil when the
    /// window is unknown (unknown model id) — then we show raw tokens instead.
    private var contextFraction: Double? {
        guard let window = session.contextWindow, window > 0 else { return nil }
        return min(1, Double(session.contextTokens) / Double(window))
    }

    @ViewBuilder
    private var contextLabel: some View {
        if let f = contextFraction {
            Text("\(Int((f * 100).rounded()))%")
                .font(.system(size: 9, weight: .medium))
                .monospacedDigit()
                .foregroundStyle(meterColor.opacity(0.95))
        } else {
            Text("\(tokenString(session.contextTokens)) ctx")
                .font(.system(size: 9))
                .monospacedDigit()
                .foregroundStyle(.white.opacity(0.5))
        }
    }

    /// A thin capsule fill, exactly the progress-bar idiom. When the window is
    /// unknown there is no meaningful fraction — omit the bar (the raw token
    /// count in `contextLabel` carries the info instead).
    @ViewBuilder
    private var contextMeter: some View {
        if let f = contextFraction {
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    Capsule().fill(.white.opacity(0.15))
                    Capsule().fill(meterColor)
                        .frame(width: max(3, geo.size.width * f))
                }
            }
            .frame(height: 3)
        }
    }

    /// Amber at ≥70%, red at ≥90%, calm otherwise.
    private var meterColor: Color {
        guard let f = contextFraction else { return .white.opacity(0.6) }
        if f >= 0.9 { return .red }
        if f >= 0.7 { return .orange }
        return .green
    }

    // MARK: Time / tokens

    /// Compact "time in current state": seconds under a minute, then minutes,
    /// then hours. e.g. "12s", "2m", "1h".
    private var timeInState: String {
        let secs = max(0, Int(now.timeIntervalSince(session.stateSince)))
        if secs < 60 { return "\(secs)s" }
        if secs < 3600 { return "\(secs / 60)m" }
        return "\(secs / 3600)h"
    }

    /// 328_545 -> "329k", 1_240 -> "1.2k", 812 -> "812".
    private func tokenString(_ n: Int) -> String {
        if n < 1000 { return "\(n)" }
        if n < 100_000 {
            let k = Double(n) / 1000
            return String(format: "%.1fk", k)
        }
        return "\(Int((Double(n) / 1000).rounded()))k"
    }
}
