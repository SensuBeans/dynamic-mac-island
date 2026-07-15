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
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var agentSessions: AgentSessionsModel
    @EnvironmentObject var servers: ServersModel
    let metrics: NotchMetrics

    @FocusState private var editorFocused: Bool
    @State private var dropTargeted = false

    // Nav-dock tab reordering (click-and-hold a chip, drag to a new slot).
    @State private var draggingTab: NotchTab?
    /// Live order while a drag is in flight; committed to state on release so we
    /// don't thrash UserDefaults on every micro-move.
    @State private var dragOrder: [NotchTab]?
    /// Finger x in the tab bar's coordinate space, and each chip's measured
    /// width (stable — independent of position, so it never lags the layout).
    @State private var dragFingerX: CGFloat = 0
    @State private var chipWidths: [NotchTab: CGFloat] = [:]
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
        let hasMedia = (media.nowPlaying != nil && !media.earHidden)
            || (pomodoro.isRunning && settings.timerCountdownEar)
        let hasToast = state.toast != nil
        let hasAgent = agentSessions.hasActivePill
        // The mirror always gets the big panel — a postage-stamp selfie
        // preview isn't useful, so the old zoom toggle is gone. Its overlay
        // button doubles it again (mirrorBig).
        let onMirror = state.currentTab == .mirror
        let expandedSize: CGSize = {
            // Settings pages always use the standard panel size, whatever tab
            // they were opened from (so settings on mirror/tray/terminal isn't
            // oversized). Must stay in lockstep with AppDelegate.islandRect.
            if state.showingSettings {
                return metrics.expandedSize()
            }
            if state.currentTab == .tray {
                return metrics.trayExpandedSize(itemCount: tray.items.count,
                                                cell: settings.trayTileSize)
            } else if state.currentTab == .terminal {
                return NotchMetrics.terminalIslandSize
            } else if state.currentTab == .agents {
                return NotchMetrics.agentsIslandSize
            } else if state.currentTab == .servers {
                return NotchMetrics.serversIslandSize
            } else if state.currentTab == .calendar {
                return metrics.calendarExpandedSize(monthMode: state.calendarMonthMode)
            }
            return metrics.expandedSize(zoomed: onMirror, large: onMirror && state.mirrorBig)
        }()
        let size = state.isExpanded
            ? expandedSize
            : metrics.collapsedSize(withMedia: hasMedia, toast: hasToast, withAgent: hasAgent)
        // Everything lives inside one container clipped to the notch
        // silhouette, so nothing can ever paint outside the shape.
        // Fully invisible when idle — the hardware notch already covers those
        // pixels, and a visible black bar looks bad during Space swipes. The
        // island only materializes when it has something to show.
        // The black notch bar materializes only for media/toast now — the agent
        // pill floats as its own capsule (below), so it no longer widens the bar.
        let collapsedVisible = hasMedia || hasToast
        // The nav dock appears on hover over its strip or mid tab-swipe.
        let navShown = state.navHovered || abs(state.tabSwipeProgress) > 0.01
        let gap = NotchMetrics.islandGap
        let totalExpandedHeight = metrics.notchHeight + gap
            + NotchMetrics.navIslandHeight + gap + expandedSize.height
        return ZStack(alignment: .top) {
            // Collapsed island. Two SEPARATE layers so content can never hide
            // under the notch: (1) the dark notch-shaped backing, clipped to the
            // silhouette and sized to notch+ear; (2) the content row (ear + agent
            // pill) ANCHORED at the notch's RIGHT edge (leading pad = notchWidth)
            // with intrinsic width and NO clip — its position is a fixed offset,
            // not derived from an animating bar width, so it cannot drift left
            // under the notch or be truncated by the silhouette.
            ZStack(alignment: .topLeading) {
                ZStack {
                    if collapsedVisible, !state.isExpanded { VisualEffectBlur() }
                    Color.black.opacity(!state.isExpanded && collapsedVisible ? 1 : 0)
                }
                .frame(width: metrics.collapsedSize(withMedia: hasMedia,
                                                    toast: hasToast).width,
                       height: metrics.notchHeight)
                .clipShape(NotchShape(topRadius: NotchMetrics.topFlare,
                                      bottomRadius: 10))

                HStack(spacing: 0) {
                    // Fixed notch-width block reserves the hardware notch; content
                    // starts exactly at the notch's right edge and a trailing
                    // Spacer keeps the whole row hard against the left. This can't
                    // right-drift the way a padding+alignment combo did.
                    Color.clear.frame(width: metrics.notchWidth + 4, height: 1)
                    ears
                    agentPill.padding(.leading, 6)
                    Spacer(minLength: 0)
                }
                .frame(height: metrics.notchHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .opacity(state.isExpanded ? 0 : 1)

            // Expanded: the nav bar and the content panel are each their
            // OWN floating island, stacked below the notch.
            VStack(spacing: gap) {
                contentIsland(size: expandedSize)
                    .frame(width: expandedSize.width, height: expandedSize.height)
                    .clipShape(RoundedRectangle(cornerRadius: 26, style: .continuous))
                    .shadow(color: .black.opacity(0.55), radius: 18, y: 8)
                navIsland
                    .frame(height: NotchMetrics.navIslandHeight)
                    .opacity(navShown ? 1 : 0)
                    .offset(y: navShown ? 0 : -10)
                    .allowsHitTesting(navShown)
                    .animation(.easeOut(duration: 0.18), value: navShown)
            }
            // Pin the (wider) expanded content to the island's current width so
            // it can't inflate the ZStack when collapsed — otherwise the outer
            // centered frame would shift the collapsed bar left under the notch.
            .frame(width: size.width)
            .padding(.top, metrics.notchHeight + gap)
            .opacity(state.isExpanded ? 1 : 0)
            .offset(y: state.isExpanded ? 0 : -totalExpandedHeight)
            .allowsHitTesting(state.isExpanded)
        }
        .frame(width: size.width,
               height: state.isExpanded ? totalExpandedHeight : size.height,
               alignment: .top)
        .opacity(state.spaceTransitioning && !state.pinned ? 0 : 1)
        .animation(.easeOut(duration: 0.12), value: state.spaceTransitioning)
        .padding(.leading, state.isExpanded
                 ? metrics.expandedLeadingPad(width: expandedSize.width)
                 : metrics.islandLeadingPad(expanded: false))
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
        .animation(.spring(response: 0.28, dampingFraction: 0.85), value: state.isExpanded)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: state.currentTab)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: tray.items.count)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: state.mirrorBig)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: hasMedia)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: hasToast)
        .onChange(of: media.nowPlaying?.isPlaying) { playing in
            // The tap only listens while the player itself is playing —
            // paused means a still wave, whatever else the system sounds.
            // Off via settings: never create the audio tap (privacy); the
            // waveform falls back to synthetic bars.
            spectrum.setActive(settings.liveWaveform && state.isExpanded && playing == true)
        }
        .onChange(of: spectrum.levels) { levels in
            // Each fresh audio sample nudges the ambient colors along,
            // loudness sets the pace; no samples (paused) — no motion.
            guard !levels.isEmpty else { return }
            colorPhase += 0.5 + 2.0 * Double(ambientPulse)
        }
        .onChange(of: dropTargeted) { targeted in
            if targeted && !state.isExpanded && settings.trayOpenOnDrag {
                state.currentTab = .tray
                state.onExpandRequest?()
            }
        }
        .onChange(of: state.isExpanded) { expanded in
            editorFocused = expanded && state.currentTab == .notes
            media.setProgressPolling(expanded && state.currentTab == .media)
            stats.setPolling(expanded && state.currentTab == .stats)
            servers.setPolling(expanded && state.currentTab == .servers)
            spectrum.setActive(settings.liveWaveform && expanded && media.nowPlaying?.isPlaying == true)
            // MirrorTab stays mounted while hidden (the panel is opacity-0,
            // not removed), so its onAppear never re-fires — restart here.
            if expanded && state.currentTab == .mirror {
                mirror.resumeIfAuthorized()
            }
        }
        .onChange(of: state.showingSettings) { showing in
            // The overlay replaces the tab's content — pause the camera under
            // it and hand focus/polling back when it closes.
            editorFocused = state.isExpanded && !showing && state.currentTab == .notes
            if state.currentTab == .mirror {
                showing ? mirror.stop() : mirror.resumeIfAuthorized()
            }
        }
        .onChange(of: state.currentTab) { tab in
            editorFocused = state.isExpanded && tab == .notes
            media.setProgressPolling(state.isExpanded && tab == .media)
            stats.setPolling(state.isExpanded && tab == .stats)
            servers.setPolling(state.isExpanded && tab == .servers)
            spectrum.setActive(settings.liveWaveform && state.isExpanded && media.nowPlaying?.isPlaying == true)
            if tab == .calendar { calendarModel.load() }
            if tab != .mirror {
                mirror.stop()
                if !settings.mirrorRememberBig { state.mirrorBig = false }
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
                .frame(height: metrics.notchHeight)
                .transition(.opacity)
            } else if pomodoro.isRunning, settings.timerCountdownEar,
                      media.nowPlaying == nil || media.earHidden,
                      !state.isExpanded {
                // Live countdown while the pomodoro runs.
                HStack(spacing: 5) {
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
                .frame(height: metrics.notchHeight)
                .transition(.opacity)
            } else if let np = media.nowPlaying, !media.earHidden, !state.isExpanded {
                // Right ear only: never cover the frontmost app's menu items.
                HStack(spacing: 6) {
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
                .frame(height: metrics.notchHeight)
                .transition(.opacity)
            }
        }
    }

    /// Collapsed agent-status pill: its OWN floating glass capsule at the far
    /// right of the island, separate from the notch bar. Priority comes from
    /// `agentSessions.collapsedPill`: any waiting (orange ⚠ N) beats any working
    /// (pulsing dot ● N) beats a recent complete (green ✓ N). A tap expands
    /// straight into the Agents tab. Suppressed while a toast is up (the toast
    /// reuses the same right slot).
    private var agentPill: some View {
        Group {
            if let pill = agentSessions.collapsedPill, !state.isExpanded, state.toast == nil {
                Button {
                    state.currentTab = .agents
                    state.onExpandRequest?()
                } label: {
                    AgentPillLabel(pill: pill)
                }
                .buttonStyle(.plain)
                .transition(.opacity.combined(with: .scale(scale: 0.8, anchor: .leading)))
                .animation(.spring(response: 0.3, dampingFraction: 0.78), value: pill)
            }
        }
        .frame(height: metrics.notchHeight, alignment: .center)
    }

    /// The pill's glyph + count capsule; `.working` gets a gently pulsing dot.
    private struct AgentPillLabel: View {
        let pill: AgentSessionsModel.CollapsedPill
        @State private var pulse = false

        private var count: Int {
            switch pill {
            case .waiting(let n), .working(let n), .complete(let n): return n
            }
        }
        /// Bounded so a big fan-out ("● 14") can't overflow the reserved
        /// `agentEar` width and clip into the media ear.
        private var countLabel: String { count > 9 ? "9+" : "\(count)" }
        private var tint: Color {
            switch pill {
            case .waiting:  return .orange
            case .working:  return .blue
            case .complete: return .green
            }
        }

        var body: some View {
            HStack(spacing: 3) {
                switch pill {
                case .working:
                    Circle()
                        .fill(tint)
                        .frame(width: 7, height: 7)
                        .opacity(pulse ? 0.3 : 1)
                        .onAppear { pulse = true }
                        .animation(.easeInOut(duration: 0.75).repeatForever(autoreverses: true),
                                   value: pulse)
                case .waiting:
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 9, weight: .bold))
                        .foregroundStyle(tint)
                case .complete:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(tint)
                }
                Text(countLabel)
                    .font(.system(size: 11, weight: .semibold))
                    .monospacedDigit()
                    .foregroundStyle(.white)
            }
            .padding(.horizontal, 9)
            .frame(height: 20)
            // Its own frosted-glass capsule that floats — matching the nav/content
            // islands rather than sitting inside the black notch bar.
            .background { ZStack { VisualEffectBlur(); Color.black.opacity(0.4) } }
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
            .shadow(color: .black.opacity(0.45), radius: 5, y: 2)
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

    /// The nav bar as its own floating capsule island: tabs + pin + quit.
    private var navIsland: some View {
        HStack(spacing: 10) {
            tabBar
            Button { state.pinned.toggle() } label: {
                Image(systemName: state.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(state.pinned ? 0.9 : 0.4))
                    .rotationEffect(.degrees(state.pinned ? 0 : 45))
            }
            .buttonStyle(.plain)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: state.pinned)
            .help(state.pinned ? "Unpin — collapse when the mouse leaves"
                               : "Pin the panel open")
            Button {
                // Gear toggles the whole section: open at the root list, or close.
                state.settingsRoute = state.settingsRoute == nil ? .root : nil
            } label: {
                Image(systemName: state.showingSettings ? "gearshape.fill" : "gearshape")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(state.showingSettings ? 0.9 : 0.4))
            }
            .buttonStyle(.plain)
            .help("Settings")
            Button { state.onQuit?() } label: {
                Image(systemName: "power")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            }
            .buttonStyle(.plain)
            .help("Quit Notchbook")
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .background { ZStack { VisualEffectBlur(); Color.black.opacity(0.32) } }
        .clipShape(Capsule())
        .shadow(color: .black.opacity(0.45), radius: 12, y: 5)
    }

    /// The content panel island: frosted glass, ambient album glow, the tab.
    private func contentIsland(size: CGSize) -> some View {
        ZStack(alignment: .top) {
            VisualEffectBlur()
            Color.black.opacity(0.32)
            // Ambient glow: the album cover, blown up and heavily blurred,
            // tints the panel with the artwork's palette on every tab.
            // While music plays it breathes with the song's loudness. The
            // glow-intensity setting scales the whole layer's opacity.
            if let art = media.artwork, settings.ambientGlow {
                let pulse = ambientPulse
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
                .opacity((0.32 + 0.2 * pulse) * settings.glowIntensity)
                .frame(width: size.width, height: size.height)
                .allowsHitTesting(false)
                .animation(.linear(duration: 0.14), value: colorPhase)
                .animation(.easeOut(duration: 0.16), value: pulse)
            }
            expandedContent
                .frame(width: size.width, height: size.height, alignment: .top)
        }
    }

    private var expandedContent: some View {
        VStack(spacing: 10) {
            Group {
                if let route = state.settingsRoute {
                    SettingsContainer(route: route)
                } else {
                    switch state.currentTab {
                    case .notes: NotesTab(focus: $editorFocused)
                    case .timer: TimerTab()
                    case .media: MediaTab()
                    case .tray: TrayTab()
                    case .terminal: TerminalTab()
                    case .agents: AgentsTab()
                    case .servers: ServersTab()
                    case .calendar: CalendarTab()
                    case .mirror: MirrorTab()
                    case .stats: StatsTab()
                    case .toggles: TogglesTab()
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .top)
            // A horizontal swipe drags the content a few points toward the
            // tab it will land on; it springs back if the swipe bails.
            .offset(x: state.tabSwipeProgress * 16)
            .opacity(1 - 0.25 * abs(state.tabSwipeProgress))
            .animation(.spring(response: 0.25, dampingFraction: 0.9),
                       value: state.tabSwipeProgress)
        }
        .padding(.horizontal, 16)
        .padding(.top, 12)
        .padding(.bottom, 14)
    }

    /// Tab the in-flight swipe will land on once it passes the commit
    /// threshold (half of full progress), wrapping at the ends.
    private var swipeTarget: NotchTab? {
        guard abs(state.tabSwipeProgress) >= 0.5 else { return nil }
        let tabs = state.visibleTabs
        guard let i = tabs.firstIndex(of: state.currentTab) else { return nil }
        let step = state.tabSwipeProgress < 0 ? 1 : -1
        return tabs[(i + step + tabs.count) % tabs.count]
    }

    /// Tabs to render — the live drag order while reordering, else the real one.
    private var displayTabs: [NotchTab] { dragOrder ?? state.visibleTabs }

    private var tabBar: some View {
        HStack(spacing: 2) {
            ForEach(displayTabs, id: \.self) { tab in
                tabChip(tab)
            }
        }
        .padding(2)
        .background(Capsule().fill(.white.opacity(0.06)))
        .coordinateSpace(name: "tabbar")
        .onPreferenceChange(TabChipWidthKey.self) { chipWidths = $0 }
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: state.currentTab)
        .animation(.easeOut(duration: 0.12), value: swipeTarget)
    }

    private func tabChip(_ tab: NotchTab) -> some View {
        let selected = state.currentTab == tab
        let targeted = swipeTarget == tab
        let isDragging = draggingTab == tab
        return HStack(spacing: 4) {
            Image(systemName: tab.icon)
                .font(.system(size: 11, weight: .medium))
            if selected {
                Text(tab.title)
                    .font(.system(size: 11, weight: .semibold))
            }
        }
        .foregroundStyle(selected ? .white
                         : .white.opacity(targeted ? 0.9 : 0.45))
        .padding(.horizontal, selected ? 10 : 8)
        .frame(height: 24)
        .background(
            Capsule().fill(.white.opacity(
                isDragging ? 0.3 : (selected ? 0.16 : (targeted ? 0.09 : 0))))
        )
        // Measure width (stable, position-independent) for the reorder math.
        .background(GeometryReader { geo in
            Color.clear.preference(key: TabChipWidthKey.self, value: [tab: geo.size.width])
        })
        .scaleEffect(isDragging ? 1.12 : 1)
        .offset(x: chipOffset(tab))
        .zIndex(isDragging ? 1 : 0)
        .shadow(color: .black.opacity(isDragging ? 0.35 : 0),
                radius: isDragging ? 6 : 0, y: 2)
        // The lifted chip repositions INSTANTLY (glued to the finger); every
        // other chip springs to its new slot. Separating the two is what kills
        // the wobble — the dragged chip never animates its own layout.
        .animation(isDragging ? nil
                   : .spring(response: 0.3, dampingFraction: 0.82),
                   value: displayTabs)
        .animation(.spring(response: 0.24, dampingFraction: 0.7), value: isDragging)
        .contentShape(Capsule())
        .onTapGesture {
            state.currentTab = tab
            state.settingsRoute = nil
        }
        .gesture(reorderGesture(tab))
        .help(tab.title)
    }

    /// The lifted chip sits exactly under the finger; everyone else at offset 0.
    private func chipOffset(_ tab: NotchTab) -> CGFloat {
        guard draggingTab == tab else { return 0 }
        return dragFingerX - slotCenterX(of: tab, in: displayTabs)
    }

    /// Resting center x of a chip in the tab-bar coordinate space, from measured
    /// widths (2 pt leading pad + 2 pt inter-chip spacing) — stable during the
    /// reflow animation, unlike live frame reads.
    private func slotCenterX(of tab: NotchTab, in order: [NotchTab]) -> CGFloat {
        var x: CGFloat = 2
        for t in order {
            let w = chipWidths[t] ?? 30
            if t == tab { return x + w / 2 }
            x += w + 2
        }
        return x
    }

    /// Click-and-hold a chip (0.3 s) to pick it up, then drag left/right; the
    /// others slide aside and the order commits on release.
    private func reorderGesture(_ tab: NotchTab) -> some Gesture {
        LongPressGesture(minimumDuration: 0.3)
            .sequenced(before: DragGesture(minimumDistance: 0,
                                           coordinateSpace: .named("tabbar")))
            .onChanged { value in
                guard case .second(true, let drag) = value else { return }
                if draggingTab == nil {
                    draggingTab = tab
                    dragOrder = state.visibleTabs
                    dragFingerX = slotCenterX(of: tab, in: state.visibleTabs)
                    NSHapticFeedbackManager.defaultPerformer
                        .perform(.alignment, performanceTime: .now)
                }
                if let drag {
                    dragFingerX = drag.location.x
                    reorder(dragging: tab, toFingerX: drag.location.x)
                }
            }
            .onEnded { _ in
                if let order = dragOrder { state.setVisibleOrder(order) }
                draggingTab = nil
                dragOrder = nil
            }
    }

    /// Insertion index = how many OTHER chips have their center left of the
    /// finger, laid out as if the dragged chip were lifted out of the row.
    private func reorder(dragging: NotchTab, toFingerX x: CGFloat) {
        guard var order = dragOrder, let from = order.firstIndex(of: dragging) else { return }
        var target = 0
        var cx: CGFloat = 2
        for t in order where t != dragging {
            let w = chipWidths[t] ?? 30
            if cx + w / 2 < x { target += 1 }
            cx += w + 2
        }
        guard target != from else { return }
        order.remove(at: from)
        order.insert(dragging, at: min(target, order.count))
        dragOrder = order
    }

    /// Collects each nav-dock chip's measured width so the reorder drag can lay
    /// out resting slot positions without reading mid-animation frames.
    private struct TabChipWidthKey: PreferenceKey {
        static var defaultValue: [NotchTab: CGFloat] = [:]
        static func reduce(value: inout [NotchTab: CGFloat],
                           nextValue: () -> [NotchTab: CGFloat]) {
            value.merge(nextValue()) { _, new in new }
        }
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
