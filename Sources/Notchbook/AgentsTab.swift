import SwiftUI

// MARK: - Agents

/// Live view of running Claude Code sessions. Pure transcript tailing — the
/// model does the parsing; this tab just renders per-session rows in the
/// existing dark-glass idiom (see TabViews.swift: StatTile / progressBar).
struct AgentsTab: View {
    @EnvironmentObject var agents: AgentSessionsModel
    @EnvironmentObject var state: NotchState

    /// One shared clock so every row's "time-in-state" and context freshness
    /// advance together without a timer per row.
    @State private var now = Date()
    private let timer = Timer.publish(every: 1, on: .main, in: .common).autoconnect()

    var body: some View {
        Group {
            if agents.sessions.isEmpty {
                emptyState
            } else {
                // Always a ScrollView so any overflow scrolls; when the rows
                // fit, it simply doesn't scroll. `.frame(maxHeight:.infinity)`
                // pins it to the panel height so the scroll region is bounded.
                ScrollView(showsIndicators: true) {
                    VStack(spacing: 6) { rows }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            }
        }
        .onReceive(timer) { now = $0 }
        .onAppear { agents.acknowledgeCompletes() }
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
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - Row

private struct AgentRow: View {
    let session: AgentSession
    let now: Date

    @State private var hovered = false

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
                    Spacer(minLength: 4)
                    contextLabel
                }

                contextMeter
            }
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
