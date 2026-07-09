import SwiftUI
import UniformTypeIdentifiers

struct NotchView: View {
    @EnvironmentObject var state: NotchState
    @EnvironmentObject var media: MediaWatcher
    @EnvironmentObject var tray: FilesTray
    @EnvironmentObject var calendarModel: CalendarModel
    @EnvironmentObject var mirror: MirrorController
    @EnvironmentObject var toggles: TogglesModel
    @EnvironmentObject var stats: StatsModel
    @EnvironmentObject var pomodoro: PomodoroModel
    let metrics: NotchMetrics

    @FocusState private var editorFocused: Bool
    @State private var dropTargeted = false

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            island
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
    }

    private var island: some View {
        let hasMedia = (media.nowPlaying != nil && !media.earHidden) || pomodoro.isRunning
        let hasToast = state.toast != nil
        let expandedSize = metrics.expandedSize(zoomed: state.mirrorZoomed)
        let size = state.isExpanded
            ? expandedSize
            : metrics.collapsedSize(withMedia: hasMedia, toast: hasToast)
        // Everything lives inside one container clipped to the notch
        // silhouette, so nothing can ever paint outside the shape.
        // Fully invisible when idle — the hardware notch already covers those
        // pixels, and a visible black bar looks bad during Space swipes. The
        // island only materializes when it has something to show.
        let collapsedVisible = hasMedia || hasToast
        return ZStack(alignment: .top) {
            // Apple-style frosted glass: black fades from opaque (collapsed
            // island matches the physical notch) to a dark tint over blur.
            if state.isExpanded || collapsedVisible {
                VisualEffectBlur()
            }
            Color.black.opacity(state.isExpanded ? 0.32 : (collapsedVisible ? 1 : 0))
            expandedContent
                .frame(width: expandedSize.width,
                       height: expandedSize.height, alignment: .top)
                .opacity(state.isExpanded ? 1 : 0)
                .offset(y: state.isExpanded ? 0 : -expandedSize.height)
                .allowsHitTesting(state.isExpanded)
        }
        .frame(width: size.width, height: size.height)
        .overlay(alignment: .top) { ears }
        .clipShape(NotchShape(topRadius: NotchMetrics.topFlare,
                              bottomRadius: state.isExpanded ? 26 : 10))
        .shadow(color: .black.opacity(state.isExpanded ? 0.55 : 0), radius: 18, y: 8)
        .opacity(state.spaceTransitioning ? 0 : 1)
        .animation(.easeOut(duration: 0.12), value: state.spaceTransitioning)
        .padding(.leading, metrics.islandLeadingPad(expanded: state.isExpanded,
                                                    zoomed: state.mirrorZoomed))
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: state.isExpanded)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: state.mirrorZoomed)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: hasMedia)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: hasToast)
        .onChange(of: dropTargeted) { targeted in
            if targeted && !state.isExpanded {
                state.currentTab = .tray
                state.onExpandRequest?()
            }
        }
        .onChange(of: state.isExpanded) { expanded in
            editorFocused = expanded && state.currentTab == .notes
            media.setProgressPolling(expanded && state.currentTab == .media)
            stats.setPolling(expanded && state.currentTab == .stats)
        }
        .onChange(of: state.currentTab) { tab in
            editorFocused = state.isExpanded && tab == .notes
            media.setProgressPolling(state.isExpanded && tab == .media)
            stats.setPolling(state.isExpanded && tab == .stats)
            if tab == .calendar { calendarModel.load() }
            if tab != .mirror {
                mirror.stop()
                state.mirrorZoomed = false
            }
        }
    }

    /// Dynamic Island ears: album art on the left, live activity on the right.
    private var ears: some View {
        Group {
            if let toast = state.toast, !state.isExpanded {
                HStack(spacing: 8) {
                    Spacer()
                    if toast.useArtwork, let art = media.artwork {
                        Image(nsImage: art)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: metrics.notchHeight - 10,
                                   height: metrics.notchHeight - 10)
                            .clipShape(RoundedRectangle(cornerRadius: 5))
                    } else {
                        Image(systemName: toast.icon)
                            .font(.system(size: 12))
                            .foregroundStyle(toast.color)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(toast.title)
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if let sub = toast.subtitle {
                            Text(sub)
                                .font(.system(size: 8.5))
                                .foregroundStyle(.white.opacity(0.55))
                                .lineLimit(1)
                        }
                    }
                    .frame(width: 150, alignment: .leading)
                }
                .padding(.trailing, 10)
                .frame(maxWidth: .infinity)
                .frame(height: metrics.notchHeight)
                .transition(.opacity)
            } else if pomodoro.isRunning, media.nowPlaying == nil || media.earHidden,
                      !state.isExpanded {
                // Live countdown while the pomodoro runs.
                HStack(spacing: 5) {
                    Spacer()
                    ZStack {
                        Circle().stroke(.white.opacity(0.25), lineWidth: 2)
                        Circle()
                            .trim(from: 0, to: max(0.02, pomodoro.progress))
                            .stroke(pomodoro.phase == .focus ? Color.orange : .green,
                                    style: StrokeStyle(lineWidth: 2, lineCap: .round))
                            .rotationEffect(.degrees(-90))
                    }
                    .frame(width: 13, height: 13)
                    Text(pomodoro.timeString)
                        .font(.system(size: 11, weight: .semibold))
                        .monospacedDigit()
                        .foregroundStyle(pomodoro.phase == .focus ? Color.orange : .green)
                }
                .padding(.trailing, 10)
                .frame(maxWidth: .infinity)
                .frame(height: metrics.notchHeight)
                .transition(.opacity)
            } else if let np = media.nowPlaying, !media.earHidden, !state.isExpanded {
                // Right ear only: never cover the frontmost app's menu items.
                HStack(spacing: 6) {
                    Spacer()
                    // The ear: art + waves normally; hovering morphs it into
                    // mini transport controls without opening the panel.
                    Group {
                        if state.earHovered {
                            HStack(spacing: 9) {
                                Button { media.previousTrack() } label: {
                                    Image(systemName: "backward.fill")
                                        .font(.system(size: 9))
                                }
                                Button { media.playPause() } label: {
                                    Image(systemName: np.isPlaying ? "pause.fill" : "play.fill")
                                        .font(.system(size: 12))
                                }
                                Button { media.nextTrack() } label: {
                                    Image(systemName: "forward.fill")
                                        .font(.system(size: 9))
                                }
                            }
                            .buttonStyle(.plain)
                            .foregroundStyle(media.accent)
                            .transition(.opacity.combined(with: .scale(scale: 0.85)))
                        } else {
                            HStack(spacing: 6) {
                                artworkThumb(side: metrics.notchHeight - 10)
                                Group {
                                    if np.isPlaying {
                                        EqualizerBars(barCount: 4, maxHeight: 14,
                                                      color: media.accent)
                                    } else {
                                        Image(systemName: "play.fill")
                                            .font(.system(size: 10))
                                            .foregroundStyle(media.accent)
                                    }
                                }
                                .frame(width: 30)
                            }
                            .transition(.opacity.combined(with: .scale(scale: 0.85)))
                        }
                    }
                    .animation(.easeOut(duration: 0.15), value: state.earHovered)
                }
                .padding(.trailing, 8)
                .frame(maxWidth: .infinity)
                .frame(height: metrics.notchHeight)
                .transition(.opacity)
            }
        }
    }

    private func artworkThumb(side: CGFloat) -> some View {
        Group {
            if let art = media.artwork {
                Image(nsImage: art)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
            } else {
                RoundedRectangle(cornerRadius: 5)
                    .fill(.white.opacity(0.12))
                    .overlay(
                        Image(systemName: "music.note")
                            .font(.system(size: side * 0.45))
                            .foregroundStyle(.orange)
                    )
            }
        }
        .frame(width: side, height: side)
        .clipShape(RoundedRectangle(cornerRadius: 5))
    }

    // MARK: - Expanded panel

    private var expandedContent: some View {
        VStack(spacing: 10) {
            ZStack {
                tabBar
                HStack {
                    Spacer()
                    Button { state.onQuit?() } label: {
                        Image(systemName: "power")
                            .font(.system(size: 11))
                            .foregroundStyle(.white.opacity(0.4))
                    }
                    .buttonStyle(.plain)
                    .help("Quit Notchbook")
                }
            }

            Group {
                switch state.currentTab {
                case .notes: NotesTab(focus: $editorFocused)
                case .timer: TimerTab()
                case .media: MediaTab()
                case .tray: TrayTab()
                case .calendar: CalendarTab()
                case .mirror: MirrorTab()
                case .stats: StatsTab()
                case .toggles: TogglesTab()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
        }
        .padding(.horizontal, 16)
        .padding(.top, metrics.notchHeight + 8)
        .padding(.bottom, 14)
    }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(NotchTab.allCases, id: \.self) { tab in
                let selected = state.currentTab == tab
                Button { state.currentTab = tab } label: {
                    HStack(spacing: 4) {
                        Image(systemName: tab.icon)
                            .font(.system(size: 11, weight: .medium))
                        if selected {
                            Text(tab.title)
                                .font(.system(size: 11, weight: .semibold))
                        }
                    }
                    .foregroundStyle(selected ? .white : .white.opacity(0.45))
                    .padding(.horizontal, selected ? 10 : 8)
                    .frame(height: 24)
                    .background(
                        Capsule().fill(selected ? .white.opacity(0.16) : .clear)
                    )
                }
                .buttonStyle(.plain)
                .help(tab.title)
            }
        }
        .padding(2)
        .background(Capsule().fill(.white.opacity(0.06)))
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: state.currentTab)
    }

    private struct VisualEffectBlur: NSViewRepresentable {
        func makeNSView(context: Context) -> NSVisualEffectView {
            let view = NSVisualEffectView()
            view.material = .hudWindow
            view.blendingMode = .behindWindow
            view.state = .active
            return view
        }

        func updateNSView(_ nsView: NSVisualEffectView, context: Context) {}
    }

    private func handleDrop(_ providers: [NSItemProvider]) -> Bool {
        var accepted = false
        for provider in providers
        where provider.hasItemConformingToTypeIdentifier(UTType.fileURL.identifier) {
            accepted = true
            provider.loadItem(forTypeIdentifier: UTType.fileURL.identifier, options: nil) { item, _ in
                var url: URL?
                if let data = item as? Data {
                    url = URL(dataRepresentation: data, relativeTo: nil)
                } else if let u = item as? URL {
                    url = u
                }
                if let url {
                    DispatchQueue.main.async {
                        tray.add([url])
                        state.currentTab = .tray
                    }
                }
            }
        }
        return accepted
    }
}
