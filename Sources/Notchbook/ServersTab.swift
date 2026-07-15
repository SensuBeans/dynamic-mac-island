import SwiftUI
import AppKit

// MARK: - Servers

/// Local "Local Starter" dev servers, driven from the notch via its JSON API.
/// Mirrors the Agents tab: a header stat line + scrollable rows with per-row
/// start/stop/open/favorite actions.
struct ServersTab: View {
    @EnvironmentObject var servers: ServersModel
    @EnvironmentObject var state: NotchState

    var body: some View {
        VStack(spacing: 8) {
            if servers.loaded, !servers.reachable {
                unreachable
            } else {
                header
                if servers.loaded, servers.servers.isEmpty {
                    emptyState("No servers yet — tap ＋ to add a folder")
                } else {
                    list
                }
            }
        }
        .onAppear { servers.refresh() }
    }

    private var header: some View {
        HStack(spacing: 8) {
            Text("\(servers.runningCount) running · \(servers.servers.count) total")
                .font(.system(size: 10, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
            if servers.favoriteCount > 0 {
                Button { servers.startFavorites() } label: {
                    Label("Start favorites", systemImage: "star.fill")
                        .font(.system(size: 10, weight: .medium))
                        .padding(.horizontal, 9)
                        .padding(.vertical, 4)
                        .background(Capsule().fill(.white.opacity(0.1)))
                }
                .buttonStyle(.plain)
                .foregroundStyle(.white.opacity(0.85))
                .help("Start every favorited server")
            }
            // Add a server by picking a project folder from Finder.
            Button { pickAndAdd() } label: {
                Label("Add", systemImage: "plus")
                    .font(.system(size: 10, weight: .semibold))
                    .padding(.horizontal, 9)
                    .padding(.vertical, 4)
                    .background(Capsule().fill(.white.opacity(0.14)))
            }
            .buttonStyle(.plain)
            .foregroundStyle(.white)
            .help("Add a server — pick a project folder")
        }
    }

    /// Open a native folder picker and register the chosen folder. The island
    /// panel floats at `.statusBar` level, so a normal open panel renders BEHIND
    /// it — present it non-modally, lift it above the island, and park it right
    /// under the notch (top-center). Hold the island open while it's up.
    private func pickAndAdd() {
        let state = self.state
        let servers = self.servers
        state.menuHoldsOpen = true

        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = false
        panel.prompt = "Add Server"
        panel.message = "Choose a project folder to run as a local server"
        panel.directoryURL = URL(fileURLWithPath: NSHomeDirectory()).appendingPathComponent("Core")

        // Non-modal so we can restyle its window after it's ordered in.
        panel.begin { response in
            state.menuHoldsOpen = false
            if response == .OK, let url = panel.url { servers.addServer(path: url.path) }
        }

        // Above the island (statusBar) and anchored just under the notch.
        panel.level = .popUpMenu
        if let screen = NotchMetrics.notchScreen() ?? NSScreen.main {
            let f = screen.frame
            let w: CGFloat = 680, h: CGFloat = 460
            panel.setContentSize(NSSize(width: w, height: h))
            panel.setFrameTopLeftPoint(NSPoint(x: f.midX - w / 2, y: f.maxY - 40))
        }
        NSApp.activate(ignoringOtherApps: true)
        panel.makeKeyAndOrderFront(nil)
    }

    private var list: some View {
        ScrollView(showsIndicators: true) {
            VStack(spacing: 6) {
                ForEach(servers.servers) { ServerRow(server: $0) }
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
    }

    private var unreachable: some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "bolt.horizontal.circle")
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.25))
            Text("Local Starter isn't running")
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.6))
            Button { servers.launchStarter() } label: {
                Text("Launch Starter")
                    .font(.system(size: 11, weight: .semibold))
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                    .background(Capsule().fill(.orange))
                    .foregroundStyle(.black)
            }
            .buttonStyle(.plain)
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    private func emptyState(_ text: String) -> some View {
        VStack(spacing: 10) {
            Spacer()
            Image(systemName: "server.rack")
                .font(.system(size: 26))
                .foregroundStyle(.white.opacity(0.25))
            Text(text)
                .font(.system(size: 13, weight: .medium))
                .foregroundStyle(.white.opacity(0.5))
            Spacer()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

private struct ServerRow: View {
    @EnvironmentObject var servers: ServersModel
    let server: ServersModel.Server
    @State private var hovered = false

    var body: some View {
        HStack(spacing: 10) {
            Circle()
                .fill(server.running ? Color.green : .white.opacity(0.18))
                .frame(width: 7, height: 7)

            HStack(spacing: 6) {
                Text(server.name)
                    .font(.system(size: 12, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.9))
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(server.kind)
                    .font(.system(size: 8.5, weight: .semibold))
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 5)
                    .padding(.vertical, 1)
                    .background(Capsule().fill(.white.opacity(0.1)))
                Text(":\(server.port)")
                    .font(.system(size: 10, design: .monospaced))
                    .foregroundStyle(.white.opacity(0.4))
            }
            Spacer(minLength: 4)
            actions
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 7)
        .background(RoundedRectangle(cornerRadius: 9)
            .fill(.white.opacity(hovered ? 0.09 : 0.06)))
        .opacity(server.running ? 1 : 0.82)
        .contentShape(Rectangle())
        .onHover { hovered = $0 }
        // Tap the row: open if running, else start it.
        .onTapGesture { server.running ? servers.open(server) : servers.start(server.name) }
        .animation(.easeOut(duration: 0.12), value: hovered)
        .help(server.path)
    }

    private var actions: some View {
        HStack(spacing: 5) {
            // Explicit start/stop matching the rendered state (never toggle).
            Button {
                server.running ? servers.stop(server.name) : servers.start(server.name)
            } label: {
                // Same glass chip as the other row actions — state reads from the
                // glyph + tint (green ▶ start / faint ■ stop), not a heavy fill.
                Image(systemName: server.running ? "stop.fill" : "play.fill")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(server.running ? Color(red: 0.96, green: 0.38, blue: 0.38)
                                                     : Color.green)
                    .frame(width: 30, height: 22)
                    .background(Capsule().fill(.white.opacity(0.12)))
            }
            .buttonStyle(.plain)
            .help(server.running ? "Stop" : "Start")

            if server.running {
                Button { servers.open(server) } label: {
                    Image(systemName: "arrow.up.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(.white.opacity(0.85))
                        .frame(width: 30, height: 22)
                        .background(Capsule().fill(.white.opacity(0.12)))
                }
                .buttonStyle(.plain)
                .help("Open localhost:\(server.port)")
            }

            Button { servers.favorite(server.name) } label: {
                Image(systemName: server.favorite ? "star.fill" : "star")
                    .font(.system(size: 10, weight: .semibold))
                    .foregroundStyle(server.favorite ? .yellow : .white.opacity(hovered ? 0.55 : 0.25))
                    .frame(width: 22, height: 22)
            }
            .buttonStyle(.plain)
            .help(server.favorite ? "Unfavorite" : "Favorite")
        }
    }
}
