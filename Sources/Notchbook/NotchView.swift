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
    /// Nav-bar reveal progress (0 = melted into the panel, 1 = separated
    /// capsule). Driven off `navShown` on an easeInOutCubic timing curve; drives
    /// the LiquidNav goo morph, the panel's downward shift, and the controls' fade-in.
    @State private var navT: Double = 0
    /// `-LiquidNavDebug 1`: slow the goo morph 8× (paired with the AppDelegate
    /// auto-loop) so the neck can be tuned frame-by-frame with `screencapture`.
    /// Off in normal use.
    private var liquidNavDebug: Bool { UserDefaults.standard.bool(forKey: "LiquidNavDebug") }
    /// `-LiquidNavPink 1`: fill the goo body opaque hot pink and disable the crisp
    /// cross-fade so the raw metaball silhouette is fully visible for geometry
    /// tuning (Phase 1). Off in normal use.
    private var liquidNavPink: Bool { UserDefaults.standard.bool(forKey: "LiquidNavPink") }
    /// `-LiquidNavFreeze <e>`: pin the morph at a STATIC reveal value (0…1) with
    /// no animation, so each beat-sheet frame can be captured deterministically
    /// instead of chasing a slowed loop. Absent in normal use.
    private var navTFreeze: Double? {
        UserDefaults.standard.object(forKey: "LiquidNavFreeze") == nil
            ? nil : UserDefaults.standard.double(forKey: "LiquidNavFreeze")
    }
    /// The reveal value the visual layers actually render — the frozen value when
    /// tuning, otherwise the live animated `navT`.
    private var renderNavT: Double { navTFreeze ?? navT }
    /// Fixed nav-capsule content width: the widest reachable control set (widest
    /// -titled tab selected + trailing pin/settings/power), pre-measured once by
    /// `navWidthProbe` and assigned verbatim (not a running max). It is therefore
    /// identical on every page and every launch, so the capsule never resizes as
    /// you switch pages and the power button is never clipped. Starts at a sane
    /// default until the first probe measurement lands (within one layout pass).
    @State private var navBarWidth: CGFloat = 300
    /// Live glyph centers of the nav controls (in navRow space) + row width,
    /// fed to LiquidNav so each icon-melt dot lands exactly on its real icon.
    @State private var navIconCenters: [CGFloat] = []
    @State private var navRowWidth: CGFloat = 0

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.clear
            island
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
        .environment(\.colorScheme, .dark)
    }

    /// The expanded panel size for the current tab. A struct-level property so
    /// both `island` and the expanded-panel layer helpers can read it. Must stay
    /// in lockstep with AppDelegate.islandRect.
    private var expandedSize: CGSize {
        // Settings pages always use the standard panel size, whatever tab they
        // were opened from (so settings on mirror/tray/terminal isn't oversized).
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
        let onMirror = state.currentTab == .mirror
        return metrics.expandedSize(zoomed: onMirror, large: onMirror && state.mirrorBig)
    }

    private var island: some View {
        let hasMedia = (media.nowPlaying != nil && !media.earHidden)
            || (pomodoro.isRunning && settings.timerCountdownEar)
        let hasToast = state.toast != nil
        let hasAgent = agentSessions.hasActivePill
        let expandedSize = expandedSize
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
        // The black notch bar shows for media only. A toast is its OWN small
        // floating glass capsule beside the notch (like the agent pill), so it
        // no longer fills / widens the bar.
        let collapsedVisible = hasMedia
        // The nav dock appears on hover over its top strip (flush under the
        // notch) or mid tab-swipe; otherwise it retracts and the content panel
        // slides up to fill its height.
        let navShown = state.navHovered || abs(state.tabSwipeProgress) > 0.01
        let gap = NotchMetrics.islandGap
        let totalExpandedHeight = metrics.notchHeight + gap
            + NotchMetrics.navIslandHeight + NotchMetrics.navContentGap + expandedSize.height
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
                .frame(width: metrics.collapsedSize(withMedia: hasMedia).width,
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
                    // Toast + agent pill both float outboard of the media ear;
                    // only one is present at a time (pill hides during a toast).
                    toastCapsule.padding(.leading, hasMedia ? 8 : 2)
                    agentPill.padding(.leading, 6)
                    Spacer(minLength: 0)
                }
                .frame(height: metrics.notchHeight)
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            // Own its constant collapsed anchor (left edge flush at the notch).
            // Nothing here animates horizontally on expand — the bar just fades
            // IN PLACE, killing the old diagonal drag.
            .padding(.leading, metrics.islandLeadingPad(expanded: false))
            .frame(maxWidth: .infinity, alignment: .leading)
            .opacity(state.isExpanded ? 0 : 1)
            // Quick fade, its own curve (closer than the container spring) so the
            // bar never rides the expanded panel's bubble motion.
            .animation(.easeOut(duration: 0.2), value: state.isExpanded)

            // Expanded: nav bar + content panel below the notch. The nav bar
            // "goo merges" — it buds up out of the panel's top edge on a liquid
            // neck that pinches off (LiquidNav), and melts back in on retract.
            // `navT` (0…1, spring-driven) drives the whole morph: the panel
            // shifts down to open the gap, the metaball forms the capsule, and
            // the controls fade in on top of it.
            ZStack(alignment: .top) {
                liquidNavLayer                       // goo capsule + neck (behind)
                expandedPanelLayer                   // content panel (shifts down)
                navControlsLayer                     // tabs/pin/settings/quit (on top)
            }
            // Fixed width: the off-screen probe reports the widest reachable
            // control set (widest-titled tab selected) up front, and the capsule
            // is sized to exactly that on every page and every launch — no
            // monotonic "grow as you visit", no per-page resize. The probe rides
            // as a zero-footprint background so it measures even while collapsed.
            .background(navWidthProbe)
            .onPreferenceChange(NavWidthKey.self) { navBarWidth = $0 }
            // CONSTANT width (this tab's panel), centered by the container's .top
            // alignment. It never changes width on expand — only scale/opacity/
            // offset animate — so the panel drops dead-vertical, no diagonal.
            .frame(width: expandedSize.width)
            .padding(.top, metrics.notchHeight + gap)
            // Bubble pop: start ~82% from the top-center, spring past 100%, settle.
            .scaleEffect(state.isExpanded ? 1 : 0.82, anchor: .top)
            .opacity(state.isExpanded ? 1 : 0)
            // Constant hidden travel (NOT the tab-dependent full height) so every
            // tab drops the same distance at the same perceived speed.
            .offset(y: state.isExpanded ? 0 : -(metrics.notchHeight + NotchMetrics.islandGap + 60))
            .allowsHitTesting(state.isExpanded)
        }
        // Full-window width, non-animating horizontally — each layer owns its own
        // constant anchor, so expand/collapse has zero sideways drift.
        .frame(maxWidth: .infinity,
               minHeight: state.isExpanded ? totalExpandedHeight : size.height,
               maxHeight: state.isExpanded ? totalExpandedHeight : size.height,
               alignment: .top)
        .opacity(state.spaceTransitioning && !state.pinned ? 0 : 1)
        .animation(.easeOut(duration: 0.12), value: state.spaceTransitioning)
        .onDrop(of: [UTType.fileURL], isTargeted: $dropTargeted, perform: handleDrop)
        // Direction-dependent expand curve: bubble-pop OUT (one visible overshoot),
        // crisp IN (no wobble on a tool closed dozens of times a day).
        .animation(state.isExpanded
                   ? .spring(response: 0.40, dampingFraction: 0.66)
                   : .spring(response: 0.28, dampingFraction: 0.90),
                   value: state.isExpanded)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: state.currentTab)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: tray.items.count)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: state.mirrorBig)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: hasMedia)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: hasToast)
        // Drive `navT` on a plain easeInOutCubic timing curve — NO spring or
        // overshoot (that's variant 03): 0.85 s to swell the surface into the
        // capsule, 0.70 s to sink it back. `-LiquidNavDebug` stretches both 8×
        // for screenshot tuning. Collapsing snaps to 0 with no animation so the
        // next expand starts from a flat surface.
        .onChange(of: navShown) { show in
            let base = show ? 0.85 : 0.70
            let dur = base * (liquidNavDebug ? 8 : 1)
            withAnimation(.timingCurve(0.65, 0, 0.35, 1, duration: dur)) {
                navT = show ? 1 : 0
            }
        }
        .onChange(of: state.isExpanded) { expanded in
            if !expanded { navT = 0 }
        }
        .onChange(of: media.nowPlaying?.isPlaying) { playing in
            // The tap only listens while the player itself is playing —
            // paused means a still wave, whatever else the system sounds.
            // Off via settings: never create the audio tap (privacy); the
            // waveform falls back to synthetic bars.
            _ = playing
            spectrum.setActive(spectrumShouldBeActive)
        }
        .onChange(of: media.earHidden) { _ in
            // The collapsed ear's equalizer is live too — toggle the tap as the
            // ear shows/hides so the little bars track real audio, not a sine.
            spectrum.setActive(spectrumShouldBeActive)
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
            spectrum.setActive(spectrumShouldBeActive)
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
            spectrum.setActive(spectrumShouldBeActive)
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

    /// Whether the audio tap should be running: the live-waveform setting is on,
    /// something is actually playing, and a waveform is on screen — the expanded
    /// media panel OR the collapsed ear's little equalizer. (Off via the setting
    /// never creates the tap — privacy; the bars fall back to synthetic motion.)
    private var spectrumShouldBeActive: Bool {
        settings.liveWaveform
            && media.nowPlaying?.isPlaying == true
            && (state.isExpanded || !media.earHidden)
    }

    /// Dynamic Island ears: album art on the left, live activity on the right.
    /// (Toasts moved OUT of the bar into their own floating capsule — `toastCapsule`.)
    private var ears: some View {
        Group {
            if pomodoro.isRunning, settings.timerCountdownEar,
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
                                                      color: media.accent,
                                                      levels: !spectrum.levels.isEmpty
                                                          ? spectrum.levels : nil)
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

    /// Transient notification as its OWN small floating glass capsule beside the
    /// notch — icon + one line, just enough to carry the message. Simple fade/
    /// scale in and out (no morph), driven by `state.toast`. It takes the same
    /// outboard slot as the agent pill (which hides while a toast is up).
    private var toastCapsule: some View {
        Group {
            if let toast = state.toast, !state.isExpanded {
                HStack(spacing: 7) {
                    if toast.useArtwork, let art = media.artwork {
                        Image(nsImage: art)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 16, height: 16)
                            .clipShape(RoundedRectangle(cornerRadius: 4))
                    } else {
                        Image(systemName: toast.icon)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(toast.color)
                    }
                    VStack(alignment: .leading, spacing: 0) {
                        Text(toast.title)
                            .font(.system(size: 10.5, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if let sub = toast.subtitle {
                            Text(sub)
                                .font(.system(size: 8.5))
                                .foregroundStyle(.white.opacity(0.55))
                                .lineLimit(1)
                        }
                    }
                    .frame(maxWidth: 140, alignment: .leading)
                }
                .padding(.horizontal, 9)
                .frame(height: metrics.notchHeight - 8)
                .background { ZStack { VisualEffectBlur(); Color.black.opacity(0.4) } }
                .clipShape(Capsule())
                .overlay(Capsule().strokeBorder(.white.opacity(0.14), lineWidth: 0.5))
                .shadow(color: .black.opacity(0.45), radius: 5, y: 2)
                .transition(.opacity.combined(with: .scale(scale: 0.85, anchor: .leading)))
            }
        }
        .frame(height: metrics.notchHeight, alignment: .center)
        .animation(.spring(response: 0.3, dampingFraction: 0.8), value: state.toast)
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

    /// Animatable relay: SwiftUI interpolates `t` through the transaction and
    /// re-evaluates `content` at every intermediate value. Any layer that
    /// BRANCHES on navT (the goo gate, the staged cross-fades) must render
    /// through this — reading the raw @State inside withAnimation snaps
    /// straight to the end value, so the branch logic never sees mid-flight
    /// t's and the liquid never draws a live frame.
    private struct NavTDriven<Content: View>: View, Animatable {
        var t: Double
        private let content: (Double) -> Content
        init(t: Double, @ViewBuilder content: @escaping (Double) -> Content) {
            self.t = t
            self.content = content
        }
        var animatableData: Double {
            get { t }
            set { t = newValue }
        }
        var body: some View { content(t) }
    }

    /// Each nav control's glyph center-x within the control row ("navRow"
    /// space). The icon-melt dots spread to EXACTLY these positions, so every
    /// icon sharpens out of its own dot — without this the dots landed on an
    /// even grid that matched nothing and the handoff read as two separate
    /// animations.
    private struct NavIconCentersKey: PreferenceKey {
        static var defaultValue: [CGFloat] = []
        static func reduce(value: inout [CGFloat], nextValue: () -> [CGFloat]) {
            value.append(contentsOf: nextValue())
        }
    }
    private struct NavRowWidthKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }
    /// Anchor a control's dot target: reports its center-x in navRow space.
    private func dotAnchor<V: View>(_ view: V) -> some View {
        view.background(GeometryReader { g in
            Color.clear.preference(key: NavIconCentersKey.self,
                                   value: [g.frame(in: .named("navRow")).midX])
        })
    }

    /// Surface-bulge droplet + liquid neck (metaball), behind the panel so the
    /// neck tucks in seamlessly. Only drawn while there's something to reveal.
    /// The blob hugs the measured control width.
    private var liquidNavLayer: some View {
        NavTDriven(t: renderNavT) { navT in
            if navT > 0.02 {
            // Clamp against the STANDARD panel width (a constant), not this
            // tab's panel, so the capsule width can't vary between a wide page
            // (terminal 620) and a standard one (460). navBarWidth is already the
            // fixed widest-control width from the probe; +22 is breathing room.
            let navBlobW = min(metrics.expandedSize().width - 16, navBarWidth + 22)
            // Cross-fade the flat goo out and the real glass capsule in over the
            // last of the settle (e ∈ [0.9,1]): the metaball's flat fill only
            // ever shows in flight; at rest the nav is the same VisualEffectBlur
            // glass as the panel, so materials + shadows match the pre-goo look.
            let s = min(1, max(0, (navT - 0.9) / 0.1))
            // Pink harness: no cross-fade, no dimming — show the raw silhouette.
            let rest = liquidNavPink ? 0 : s * s * (3 - 2 * s)  // 0 mid-flight → 1 settled
            ZStack(alignment: .top) {
                LiquidNav(t: navT,
                          panelWidth: expandedSize.width,
                          navWidth: navBlobW,
                          navHeight: NotchMetrics.navIslandHeight,
                          navSlot: NotchMetrics.navIslandHeight + NotchMetrics.navContentGap,
                          panelTopRadius: state.isExpanded ? 26 : 34,
                          // One dot per real control: every visible page tab
                          // plus the pin, settings, and power buttons — the
                          // dots sharpen into exactly the icons that exist.
                          iconCount: state.visibleTabs.count + 3,
                          iconSpacing: (navBlobW - 70)
                              / CGFloat(max(1, state.visibleTabs.count + 2)),
                          // Measured glyph centers → each dot IS its icon's
                          // position; empty until the first layout lands, then
                          // the uniform fallback above never shows again.
                          iconOffsets: navRowWidth > 0
                              ? navIconCenters.map { $0 - navRowWidth / 2 }
                              : [],
                          debugPink: liquidNavPink)
                    // 18pt taller + shifted up to match LiquidNav's topPad —
                    // gives the droplet overshoot room instead of a flat clip.
                    .frame(width: expandedSize.width,
                           height: NotchMetrics.navIslandHeight + NotchMetrics.navContentGap + 46 + 18)
                    .offset(y: -18)
                    .shadow(color: .black.opacity(0.45), radius: 12, y: 5)
                    .opacity(1 - rest)
                // Real crisp capsule, same footprint as the settled goo capsule.
                RoundedRectangle(cornerRadius: 16, style: .continuous)
                    .fill(.clear)
                    .background(VisualEffectBlur().clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous)))
                    .overlay(RoundedRectangle(cornerRadius: 16, style: .continuous).fill(.black.opacity(0.32)))
                    .frame(width: navBlobW, height: NotchMetrics.navIslandHeight)
                    .shadow(color: .black.opacity(0.45), radius: 12, y: 5)
                    .opacity(rest)
            }
            .frame(width: expandedSize.width,
                   height: NotchMetrics.navIslandHeight + NotchMetrics.navContentGap + 46,
                   alignment: .top)
            .allowsHitTesting(false)
            }
        }
    }

    /// The content panel, shifted down as the nav emerges and up as it melts.
    private var expandedPanelLayer: some View {
        let shift = (NotchMetrics.navIslandHeight + NotchMetrics.navContentGap) * CGFloat(renderNavT)
        return contentIsland(size: expandedSize)
            .frame(width: expandedSize.width, height: expandedSize.height)
            // Corner radius relaxes slightly in flight (34 hidden → 26 open) for
            // the soft "bubble" read; animatable via the spring.
            .clipShape(RoundedRectangle(cornerRadius: state.isExpanded ? 26 : 34,
                                        style: .continuous))
            .shadow(color: .black.opacity(0.55), radius: 18, y: 8)
            .offset(y: shift)
    }

    /// Nav controls riding the liquid capsule, fading + settling in as the
    /// droplet forms. The capsule width is measured separately by `navWidthProbe`
    /// (the widest reachable control set), so these live controls never feed the
    /// width — they just center inside the fixed capsule.
    private var navControlsLayer: some View {
        // The real SF Symbols are the last thing to resolve: the dot metaball
        // carries the icons until the very end, then the crisp controls cross-
        // fade in over iconIn = smooth(0.88, 1) with a slight scale-up, so the
        // dots sharpen INTO the real icons rather than popping over them.
        NavTDriven(t: renderNavT) { navT in
            // Wider handoff window (0.84→1, was 0.88) and a gentler scale ramp:
            // the icons emerge WHILE the dots dissolve at the same positions —
            // one continuous act, not "dots show, then nav bar appears".
            let raw = min(1, max(0, (navT - 0.84) / 0.16))
            let iconIn = raw * raw * (3 - 2 * raw)
            let scale = 0.85 + 0.15 * CGFloat(iconIn)
            navControls()
                .frame(height: NotchMetrics.navIslandHeight)
                .fixedSize(horizontal: true, vertical: false)
                .onPreferenceChange(NavIconCentersKey.self) { navIconCenters = $0 }
                .onPreferenceChange(NavRowWidthKey.self) { navRowWidth = $0 }
                .opacity(iconIn)
                .scaleEffect(scale, anchor: .center)
                // Hit areas live only at rest — mid-morph the buttons aren't there.
                .allowsHitTesting(navT > 0.98)
        }
    }

    /// Off-screen probe that fixes the capsule width. It lays out the FULL
    /// control row once per visible tab as if that tab were selected (the only
    /// thing that changes width between pages is the selected chip's title), and
    /// reports the widest of those via `NavWidthKey`. So the capsule is sized to
    /// the widest reachable control set from the first reveal, identical on every
    /// page and every launch — never the monotonic "grow as you visit" width.
    /// Zero-footprint: rendered at frame 0×0, clipped, hidden, non-interactive;
    /// the `.background(GeometryReader)` still reads each row's natural width.
    private var navWidthProbe: some View {
        ZStack {
            ForEach(state.visibleTabs, id: \.self) { sel in
                navControls(selectedOverride: sel, measuring: true)
                    .fixedSize(horizontal: true, vertical: false)
                    .background(GeometryReader { g in
                        Color.clear.preference(key: NavWidthKey.self, value: g.size.width)
                    })
            }
        }
        .frame(width: 0, height: 0)
        .clipped()
        .opacity(0)
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }

    /// The nav bar controls: tabs + pin + settings + quit. Just the controls —
    /// the capsule background is drawn by LiquidNav (the goo glass), so this
    /// carries no material of its own.
    private func navControls(selectedOverride: NotchTab? = nil,
                             measuring: Bool = false) -> some View {
        HStack(spacing: 10) {
            tabBar(selectedOverride: selectedOverride, measuring: measuring)
            dotAnchor(Button { state.pinned.toggle() } label: {
                Image(systemName: state.pinned ? "pin.fill" : "pin")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(state.pinned ? 0.9 : 0.4))
                    .rotationEffect(.degrees(state.pinned ? 0 : 45))
            })
            .buttonStyle(.plain)
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: state.pinned)
            .help(state.pinned ? "Unpin — collapse when the mouse leaves"
                               : "Pin the panel open")
            dotAnchor(Button {
                // Gear toggles the whole section: open at the root list, or close.
                state.settingsRoute = state.settingsRoute == nil ? .root : nil
            } label: {
                Image(systemName: state.showingSettings ? "gearshape.fill" : "gearshape")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(state.showingSettings ? 0.9 : 0.4))
            })
            .buttonStyle(.plain)
            .help("Settings")
            dotAnchor(Button { state.onQuit?() } label: {
                Image(systemName: "power")
                    .font(.system(size: 11))
                    .foregroundStyle(.white.opacity(0.4))
            })
            .buttonStyle(.plain)
            .help("Quit Notchbook")
        }
        .padding(.horizontal, 12)
        .frame(maxHeight: .infinity)
        .coordinateSpace(name: "navRow")
        .background(GeometryReader { g in
            Color.clear.preference(key: NavRowWidthKey.self, value: g.size.width)
        })
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

    /// `selectedOverride`/`measuring` drive the off-screen width probe: it lays
    /// the bar out as if `selectedOverride` were the current tab, without feeding
    /// the reorder-width plumbing.
    private func tabBar(selectedOverride: NotchTab? = nil,
                        measuring: Bool = false) -> some View {
        let tabs = measuring ? state.visibleTabs : displayTabs
        return HStack(spacing: 2) {
            ForEach(tabs, id: \.self) { tab in
                tabChip(tab, selectedOverride: selectedOverride, emitWidth: !measuring)
            }
        }
        .padding(2)
        .background(Capsule().fill(.white.opacity(0.06)))
        .coordinateSpace(name: "tabbar")
        .onPreferenceChange(TabChipWidthKey.self) { if !measuring { chipWidths = $0 } }
        .animation(measuring ? nil : .spring(response: 0.3, dampingFraction: 0.8), value: state.currentTab)
        .animation(measuring ? nil : .easeOut(duration: 0.12), value: swipeTarget)
    }

    /// `selectedOverride` forces the "selected" (title-showing) chip for the
    /// off-screen width probe; live chips pass nil and read `state.currentTab`.
    /// `emitWidth` is off for probe chips so they don't corrupt the reorder
    /// widths (`chipWidths`) with their forced-selection layout.
    private func tabChip(_ tab: NotchTab,
                         selectedOverride: NotchTab? = nil,
                         emitWidth: Bool = true) -> some View {
        let selected = (selectedOverride ?? state.currentTab) == tab
        let targeted = selectedOverride == nil && swipeTarget == tab
        let isDragging = selectedOverride == nil && draggingTab == tab
        return HStack(spacing: 4) {
            dotAnchor(Image(systemName: tab.icon)
                .font(.system(size: 11, weight: .medium)))
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
            Color.clear.preference(key: TabChipWidthKey.self,
                                   value: emitWidth ? [tab: geo.size.width] : [:])
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
