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
    @EnvironmentObject var spectrum: AudioSpectrum
    let metrics: NotchMetrics

    @FocusState private var editorFocused: Bool
    @State private var dropTargeted = false
    /// Accumulated rotation of the ambient color layers. Advances with each
    /// audio sample — faster when the music is loud, frozen when paused.
    @State private var colorPhase: Double = 0

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
        let expandedSize = state.currentTab == .tray
            ? metrics.trayExpandedSize(itemCount: tray.items.count)
            : metrics.expandedSize(zoomed: state.mirrorZoomed)
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
            // Ambient glow: the album cover, blown up and heavily blurred,
            // tints the whole panel with the artwork's palette (media tab).
            // While music plays it breathes with the song's loudness.
            if state.isExpanded, state.currentTab == .media, let art = media.artwork {
                let pulse = ambientPulse
                // Two counter-rotating copies of the cover: their color
                // regions slide past each other so the palette wanders
                // around the panel instead of sitting still. Square layers
                // bigger than the panel's diagonal never expose an edge.
                ZStack {
                    ambientLayer(art, side: size.width)
                        .scaleEffect(1.6 + 0.25 * pulse)
                        .rotationEffect(.degrees(colorPhase))
                    ambientLayer(art, side: size.width)
                        .scaleEffect(1.95 + 0.3 * pulse)
                        .rotationEffect(.degrees(140 - colorPhase * 1.6))
                        .offset(x: 30 * cos(colorPhase / 40),
                                y: 18 * sin(colorPhase / 47))
                        .opacity(0.6)
                }
                .blur(radius: 46)
                .saturation(1.5 + 0.5 * pulse)
                .opacity(0.32 + 0.2 * pulse)
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
                .animation(.linear(duration: 0.14), value: colorPhase)
                .animation(.easeOut(duration: 0.16), value: pulse)
                .transition(.opacity)
            }
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
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: state.currentTab)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: tray.items.count)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: state.mirrorZoomed)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: hasMedia)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: hasToast)
        .onChange(of: media.nowPlaying?.isPlaying) { playing in
            // The tap only listens while the player itself is playing —
            // paused means a still wave, whatever else the system sounds.
            spectrum.setActive(state.isExpanded && state.currentTab == .media
                               && playing == true)
        }
        .onChange(of: spectrum.levels) { levels in
            // Each fresh audio sample nudges the ambient colors along,
            // loudness sets the pace; no samples (paused) — no motion.
            guard !levels.isEmpty else { return }
            colorPhase += 0.5 + 2.0 * Double(ambientPulse)
        }
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
            spectrum.setActive(expanded && state.currentTab == .media
                               && media.nowPlaying?.isPlaying == true)
            // MirrorTab stays mounted while hidden (the panel is opacity-0,
            // not removed), so its onAppear never re-fires — restart here.
            if expanded && state.currentTab == .mirror {
                mirror.resumeIfAuthorized()
            }
        }
        .onChange(of: state.currentTab) { tab in
            editorFocused = state.isExpanded && tab == .notes
            media.setProgressPolling(state.isExpanded && tab == .media)
            stats.setPolling(state.isExpanded && tab == .stats)
            spectrum.setActive(state.isExpanded && tab == .media
                               && media.nowPlaying?.isPlaying == true)
            if tab == .calendar { calendarModel.load() }
            if tab != .mirror {
                mirror.stop()
                state.mirrorZoomed = false
            }
        }
    }

    /// One oversized square copy of the artwork for the ambient background —
    /// square and larger than the panel's diagonal, so rotation never shows
    /// a corner.
    private func ambientLayer(_ art: NSImage, side: CGFloat) -> some View {
        Image(nsImage: art)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: side, height: side)
    }

    /// Current music loudness (0…1) for the ambient background, averaged over
    /// the newest few samples so the glow breathes rather than strobes. Zero
    /// while paused — the tap is off, so the background settles to its base.
    private var ambientPulse: CGFloat {
        let recent = spectrum.levels.suffix(3)
        guard media.nowPlaying?.isPlaying == true, !recent.isEmpty else { return 0 }
        return CGFloat(recent.reduce(0, +)) / CGFloat(recent.count)
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
