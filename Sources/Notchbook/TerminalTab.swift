import SwiftUI
import AppKit
import SwiftTerm

// MARK: - Terminal tab

/// The Terminal tab: a row of session chips over the current session's live
/// shell. The terminal views themselves live in `TerminalSessionsModel`; this
/// view only hosts the selected one, so switching chips or tabs never disturbs
/// scrollback or the running process.
struct TerminalTab: View {
    @EnvironmentObject var sessions: TerminalSessionsModel

    var body: some View {
        VStack(spacing: 8) {
            sessionChips
            ZStack {
                // A flat scrim behind the (transparent) terminal keeps text
                // legible over the island's ambient album glow, while the
                // frosted glass still reads through at the edges.
                TerminalContainer(model: sessions)
                    .background(Color.black.opacity(0.35))
                    .clipShape(RoundedRectangle(cornerRadius: 12))
                if let sel = sessions.selected, !sel.isAlive {
                    deadHint
                }
            }
        }
        .onAppear {
            // First open with no sessions spins one up.
            if sessions.sessions.isEmpty { sessions.newSession() }
        }
    }

    private var deadHint: some View {
        VStack {
            Spacer()
            Text("process exited — press ⏎ to close")
                .font(.system(size: 10, weight: .medium, design: .monospaced))
                .foregroundStyle(.white.opacity(0.55))
                .padding(.horizontal, 10)
                .padding(.vertical, 5)
                .background(Capsule().fill(.black.opacity(0.55)))
                .padding(.bottom, 8)
        }
        .allowsHitTesting(false)
    }

    private var sessionChips: some View {
        HStack(spacing: 5) {
            ForEach(sessions.sessions) { session in
                TerminalChip(session: session, model: sessions)
            }
            if sessions.sessions.count < TerminalSessionsModel.maxSessions {
                Button { sessions.newSession() } label: {
                    Image(systemName: "plus")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(.white.opacity(0.65))
                        .frame(width: 22, height: 18)
                        .background(RoundedRectangle(cornerRadius: 5)
                            .fill(.white.opacity(0.08)))
                }
                .buttonStyle(.plain)
                .help("New session")
            }
            Spacer()
        }
    }
}

/// One session chip — mirrors the notes page-tab styling: selected = white
/// fill/black text, a live session gets a green dot, a finished one dims, and
/// hovering reveals an × to close it.
private struct TerminalChip: View {
    let session: TerminalSessionsModel.Session
    @ObservedObject var model: TerminalSessionsModel
    @State private var hovered = false

    private var selected: Bool { session.id == model.selectedID }

    private var label: String {
        let t = session.title
        return t.count > 12 ? String(t.prefix(11)) + "…" : t
    }

    var body: some View {
        Button { model.selectedID = session.id } label: {
            HStack(spacing: 4) {
                if session.isAlive {
                    Circle()
                        .fill(Color.green)
                        .frame(width: 4, height: 4)
                }
                Text(label)
                    .font(.system(size: 9, weight: selected ? .semibold : .regular,
                                  design: .monospaced))
                    .lineLimit(1)
                if hovered {
                    Button { model.closeSession(id: session.id) } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 7, weight: .bold))
                    }
                    .buttonStyle(.plain)
                    .help("Close session")
                }
            }
            .foregroundStyle(selected ? .black
                             : .white.opacity(session.isAlive ? 0.8 : 0.4))
            .padding(.horizontal, 7)
            .frame(height: 18)
            .background(RoundedRectangle(cornerRadius: 5)
                .fill(.white.opacity(selected ? 0.85 : 0.08)))
        }
        .buttonStyle(.plain)
        .onHover { hovered = $0 }
        .help(session.isAlive ? session.title : "\(session.title) — exited")
    }
}

// MARK: - Persistent terminal host

/// Hosts the model's current terminal view as a subview. The view is created
/// once (in the model) and merely reparented here, so SwiftUI re-renders can
/// never drop scrollback or PTY state.
private struct TerminalContainer: NSViewRepresentable {
    @ObservedObject var model: TerminalSessionsModel

    func makeNSView(context: Context) -> TerminalContainerView {
        let v = TerminalContainerView()
        v.model = model
        v.showSelected()
        return v
    }

    func updateNSView(_ nsView: TerminalContainerView, context: Context) {
        nsView.model = model
        nsView.showSelected()
    }

    /// Leaving the Terminal tab tears this host down. Detach the persistent
    /// terminal view first — while its superview is still alive — so it is
    /// cleanly re-hostable next time and never left with a dangling superview.
    static func dismantleNSView(_ nsView: TerminalContainerView, coordinator: ()) {
        nsView.detachHosted()
    }
}

final class TerminalContainerView: NSView {
    weak var model: TerminalSessionsModel?
    private weak var hosted: NSView?

    override var isFlipped: Bool { true }

    /// Reparent the selected session's view if it changed; keep it filling the
    /// container otherwise. Focuses the freshly shown view so switching chips
    /// hands the keyboard to the new session.
    func showSelected() {
        let view = model?.selected?.view
        if hosted === view {
            hosted?.frame = bounds
            return
        }
        hosted?.removeFromSuperview()
        hosted = view
        guard let view else { return }
        view.removeFromSuperview()
        view.frame = bounds
        view.autoresizingMask = [.width, .height]
        addSubview(view)
        window?.makeFirstResponder(view)
    }

    /// Remove the hosted view without touching the model — used when this
    /// container is being dismantled so the model's view survives with a clean
    /// (nil) superview, ready to be re-hosted.
    func detachHosted() {
        hosted?.removeFromSuperview()
        hosted = nil
    }

    override func layout() {
        super.layout()
        hosted?.frame = bounds
    }
}
