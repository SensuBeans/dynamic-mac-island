import SwiftUI
import UniformTypeIdentifiers

struct NotchView: View {
    @EnvironmentObject var state: NotchState
    @EnvironmentObject var media: MediaWatcher
    @EnvironmentObject var tray: FilesTray
    @EnvironmentObject var calendarModel: CalendarModel
    @EnvironmentObject var mirror: MirrorController
    @EnvironmentObject var earReveal: EarRevealModel
    /// Camera was live when the settings overlay opened — the only case where
    /// closing settings may restart it (the placeholder default is opt-in).
    @State private var mirrorPausedForSettings = false
    @EnvironmentObject var toggles: TogglesModel
    @EnvironmentObject var stats: StatsModel
    @EnvironmentObject var pomodoro: PomodoroModel
    @EnvironmentObject var settings: SettingsStore
    @EnvironmentObject var agentSessions: AgentSessionsModel
    @EnvironmentObject var servers: ServersModel
    let metrics: NotchMetrics
    /// A PLAIN reference, deliberately not `@EnvironmentObject`.
    ///
    /// The root only ever calls `setActive` on this; it reads nothing published.
    /// Observing it would re-invalidate the whole tree on every audio sample
    /// (17 Hz) — the exact cost `AmbientGlow` was extracted to remove — because
    /// SwiftUI observation is per-object, not per-property. The views that DO
    /// need the levels take their own `@EnvironmentObject`.
    let spectrum: AudioSpectrum

    /// The material every floating island is painted with, resolved once here so
    /// each call site passes a value instead of re-reading the store. `resolve`
    /// downgrades a Liquid Glass preference on a pre-26 machine.
    private var surfaceStyle: IslandSurfaceStyle {
        IslandSurfaceStyle.resolve(settings.surfaceStyle)
    }

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
    /// A glass ball that rides the selected page's glyph and slides to whichever
    /// page you pick next (Settings → General → "Page bead").
    ///
    /// Needs macOS 26 for `.glassEffect`, but deliberately NOT tied to the Liquid
    /// Glass surface style: the bead sits in its own layer behind the chips, so it
    /// works over a Frosted capsule too — and with one less layer of glass under it
    /// the ball actually reads slightly cleaner there.
    private var pageBead: Bool {
        settings.pageBead && IslandSurfaceStyle.liquidGlassAvailable
    }
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
    /// Fixed pages-pill width — the same probe measurement as `navBarWidth`, but
    /// the tab bar alone. The live pill is LOCKED to it, which is what stops the
    /// bar reshuffling on every page switch: only the selected chip's title
    /// changes width, and today that resizes the whole row, which a center-
    /// aligned container then re-centers — so every chip AND the trailing
    /// pin/gear/power slide by ±Δ/2, by an amount that depends on how long the
    /// two page names happen to be. Pinning the pill makes the row's total width
    /// constant, so both of the bar's edges become fixed points and the only
    /// motion left is chips parting INSIDE the pill, to the right of the one you
    /// tapped. 0 until the first probe measurement lands (one layout pass) —
    /// until then the pill sizes naturally rather than collapsing to nothing.
    @State private var tabBarWidth: CGFloat = 0
    /// Width reserved for the selected chip's title — the widest of every page's,
    /// so the chip row measures the same no matter which page is on.
    ///
    /// Without this, locking the pill to its widest reachable width leaves dead
    /// pill past the last chip whenever a shorter title is selected: ~11pt of empty
    /// pill on "Media" versus "Calendar", which reads as a lopsided gap between the
    /// pages and the pin. The slack has to go somewhere — dead pill, or motion if
    /// the pill hugs instead, or smeared into the chip gaps. Reserving the widest
    /// title is the only option with neither: the content width simply never
    /// changes, so the pill hugs it exactly AND nothing moves.
    @State private var titleSlot: CGFloat = 0
    /// Measured glyph centres in the chip row's space — where the travelling bead
    /// aims. See `pageBead`.
    @State private var tabIconCenters: [NotchTab: CGFloat] = [:]
    /// Live glyph centers of the nav controls (in navRow space) + row width,
    /// fed to LiquidNav so each icon-melt dot lands exactly on its real icon.
    @State private var navIconCenters: [CGFloat] = []
    @State private var navRowWidth: CGFloat = 0

    /// Media-ear reveal progress (0 = bare notch, 1 = ear resting). Driven off
    /// `showMediaEar` on an easeInOutCubic curve; drives the LiquidEar "Side
    /// Bulge" morph (E1). Its rest window hands off to the crisp backing + real
    /// ear content, so the goo is gone once settled.
    @State private var earT: Double = 0
    /// Debounced ear-reveal trigger. On music start the media state arrives in
    /// separate ticks (nowPlaying nil→"Unknown"→track, artwork decodes later,
    /// isPlaying flips late, a now-playing toast fires, the island width springs).
    /// Kicking off `earT` on the FIRST tick animated the goo while all of that
    /// churned underneath it — the reported open stutter. This work item defers
    /// the reveal until the state settles, so the ear opens ONCE, cleanly.
    // Ear reveal timing lives in EarRevealModel now (single owner) — the view
    // holds no ear debounce state and maps the model's edges 1:1 onto earT.

    /// Latched media content: the ear row renders these, NEVER raw player
    /// state — raw `nowPlaying`/`artwork` churn through nil on track changes,
    /// which used to blink the mounted content and pop layout width before
    /// the reveal (the residual "activates twice"). Latches only ever move
    /// from value to value; nil ticks keep the outgoing content.
    @State private var lastNowPlaying: MediaWatcher.NowPlaying?
    @State private var lastArtwork: NSImage?
    /// Keeps the ear row MOUNTED through the hide morph so the liquid owns
    /// the exit (content is already faded by the iconIn window); the row
    /// unmounts invisibly once this clears.
    @State private var earLinger = false
    /// LiquidAgent's donor geometry latched at the morph edge — reading live
    /// hasMedia mid-flight teleported the in-flight pill goo when the ear
    /// settled during a bud.
    @State private var agentEarLatch = false
    /// `-LiquidEarFreeze <e>`: pin the ear morph at a static value for
    /// deterministic beat-sheet capture (mirrors `LiquidNavFreeze`).
    private var earTFreeze: Double? {
        UserDefaults.standard.object(forKey: "LiquidEarFreeze") == nil
            ? nil : UserDefaults.standard.double(forKey: "LiquidEarFreeze")
    }
    private var renderEarT: Double { earTFreeze ?? earT }
    /// `-LiquidEarPink 1`: flood the ear goo silhouette flat pink for geometry tuning.
    private var liquidEarPink: Bool { UserDefaults.standard.bool(forKey: "LiquidEarPink") }

    /// Agent-pill reveal progress (0 = absorbed into the island body, 1 = the
    /// detached pill resting). Driven off `showAgentPill` on the same
    /// easeInOutCubic curve as the ear; drives the LiquidAgent bud-and-pinch.
    /// State changes (waiting→working→complete) keep the label's own spring — the
    /// liquid runs ONLY on appear/disappear.
    @State private var agentT: Double = 0
    /// True only while the pill sits fully at REST (the bud-and-pinch morph has
    /// completed and it is shown). The subtle state-change spring
    /// (waiting→working→complete) is gated on this instead of `renderAgentT`,
    /// which the view body can only read as the animation ENDPOINT (1 the instant
    /// an appear starts) — so the spring used to run through the whole appear
    /// morph, double-animating the label on top of the liquid bud.
    @State private var agentSettled = false
    /// Keeps the crisp agent-pill label mounted through the DISAPPEAR leg
    /// (mirrors earLinger). The mount condition read renderAgentT — the endpoint,
    /// 0 the instant a disappear starts — so the label unmounted at frame 0 while
    /// the goo melts, leaving a blank beat then an empty capsule (S8).
    @State private var agentLinger = false
    /// The pill's measured resting capsule rect (island space), fed to LiquidAgent
    /// so the morph targets the exact rest geometry. Persisted so the disappear leg
    /// can still draw after the real label unmounts.
    @State private var agentPillFrame: CGRect = .zero
    /// The goo's TARGET rest rect, frozen for the duration of a bud/pinch flight
    /// (S7). `agentPillFrame` is measured live and, while layout is opacity-
    /// independent, a media-ear toggle mid-flight REFLOWS the row and jumps it —
    /// re-aiming the flying capsule while the donor side stays pinned
    /// (agentEarLatch). Re-seeded at each reveal edge, then held until the pill
    /// settles, so the goo aims at one fixed rect for the whole morph.
    @State private var agentPillFrameLatch: CGRect = .zero
    /// The last non-nil pill, kept so the disappear flight renders the label/tint
    /// that is melting away (the live `activePill` is already nil by then).
    @State private var lastAgentPill: AgentSessionsModel.CollapsedPill?
    /// `-LiquidAgentFreeze <e>`: pin the pill morph at a static value.
    private var agentTFreeze: Double? {
        UserDefaults.standard.object(forKey: "LiquidAgentFreeze") == nil
            ? nil : UserDefaults.standard.double(forKey: "LiquidAgentFreeze")
    }
    private var renderAgentT: Double { agentTFreeze ?? agentT }
    /// `-LiquidAgentPink 1`: flood the pill goo silhouette flat pink.
    private var liquidAgentPink: Bool { UserDefaults.standard.bool(forKey: "LiquidAgentPink") }
    /// `-LiquidAgentDebug 1`: auto-loop the pill show/hide (6× slow) with a
    /// synthetic injected pill, so the morph can be captured frame-by-frame.
    private var liquidAgentDebug: Bool { UserDefaults.standard.bool(forKey: "LiquidAgentDebug") }
    /// The pill to show. Under the debug loop OR a freeze, the harness owns it
    /// FULLY — the synthetic pill only (nil ⇒ hidden), so a stray real session
    /// can't keep the pill alive through the loop's hide beat. Real pill otherwise.
    private var activePill: AgentSessionsModel.CollapsedPill? {
        if liquidAgentDebug || agentTFreeze != nil { return state.liquidAgentDebugPill }
        return agentSessions.collapsedPill
    }
    /// Whether the pill should be revealed. Excludes `isExpanded` on purpose
    /// (mirroring `showMediaEar`): the collapsed layer's opacity hides the pill on
    /// expand and the goo host has its own `!isExpanded` guard, so the reveal
    /// doesn't re-fire on every expand/collapse — only on real appear/disappear
    /// and the toast handoff (toast owns the slot, so the pill melts away for it).
    private var showAgentPill: Bool {
        activePill != nil && state.toast == nil && !fullscreenHidden
    }
    /// Tint for a pill state (matches AgentPillLabel).
    private func pillTint(_ pill: AgentSessionsModel.CollapsedPill) -> Color {
        switch pill {
        case .waiting:  return .orange
        case .working:  return .blue
        case .complete: return .green
        }
    }

    /// Island close/open progress (0 = fully expanded, 1 = collapsed). Driven off
    /// `state.isExpanded` on an easeInOutCubic curve (0.85 s close / 0.70 s open);
    /// drives the LiquidClose "Surface Return" morph while the logic triggers
    /// (expand/collapse) stay untouched.
    @State private var closeT: Double = 1
    /// `-LiquidCloseFreeze <e>`: pin the close morph at a static value.
    private var closeTFreeze: Double? {
        UserDefaults.standard.object(forKey: "LiquidCloseFreeze") == nil
            ? nil : UserDefaults.standard.double(forKey: "LiquidCloseFreeze")
    }
    private var renderCloseT: Double { closeTFreeze ?? closeT }
    /// `-LiquidClosePink 1`: flood the close goo silhouette flat pink.
    private var liquidClosePink: Bool { UserDefaults.standard.bool(forKey: "LiquidClosePink") }
    /// While the Surface Return close runs, the container must KEEP its expanded
    /// height — the legacy 0.28s collapse spring was crushing the liquid's canvas
    /// mid-flight (the reported "janky, fast, fades instead of merging"). Set on
    /// close, released just after the morph's duration; the height snap at
    /// release is invisible (everything but the notch is black/absorbed by then).
    @State private var morphHoldExpanded = false
    /// Pending debounced nav melt — cancelled whenever the nav is re-wanted, so
    /// gesture flicker (swipe ratchet zero-crossings) can't restart the morph.
    @State private var navHideWork: DispatchWorkItem?
    /// Whether the current reveal was gesture-driven (swipe) — those pop in
    /// statically and linger, instead of running the full liquid morph.
    @State private var navShowWasSwipe = false
    /// `-LiquidIslandDebug 1`: slow BOTH island morphs 6× (paired with the
    /// AppDelegate auto-loop) so ear + close can be captured frame-by-frame.
    private var liquidIslandDebug: Bool { UserDefaults.standard.bool(forKey: "LiquidIslandDebug") }
    /// The media ear the liquid owns — album now-playing, ignoring the pomodoro
    /// countdown ear (which keeps its plain fade). Independent of `isExpanded`:
    /// the collapsed container's own opacity hides it on expand. Under
    /// `-LiquidIslandDebug` the auto-loop drives it via a forced flag (no player).
    private var showMediaEar: Bool {
        if fullscreenHidden { return false }
        if liquidIslandDebug { return state.liquidEarDebugForced }
        return earReveal.earVisible
    }

    /// A native-fullscreen app owns the notch's screen AND the user wants the
    /// collapsed adornments hidden there. ANDed into the collapsed choke points
    /// (showMediaEar / hasMedia / showAgentPill / toast) so entering fullscreen
    /// drives them false→true through the existing liquid `.onChange` animators,
    /// and leaving restores them. Only ever bites while collapsed — the collapsed
    /// layer is already opacity-0 while expanded — so hover-to-expand is untouched.
    private var fullscreenHidden: Bool {
        state.frontmostIsFullscreen && settings.hideInFullscreen
    }

    /// Smoothstep a→b at x, clamped (the mock's `smooth`, for view-level windows).
    private func smoothstep(_ a: Double, _ b: Double, _ x: Double) -> Double {
        guard b != a else { return x < a ? 0 : 1 }
        let t = min(1, max(0, (x - a) / (b - a)))
        return t * t * (3 - 2 * t)
    }

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
        // Settings pages match the Agents page footprint (470×300), whatever
        // tab they were opened from — one constant size for every route.
        if state.showingSettings {
            return NotchMetrics.agentsIslandSize
        }
        if state.currentTab == .tray {
            return metrics.trayExpandedSize(itemCount: tray.items.count,
                                            cell: settings.trayTileSize)
        } else if state.currentTab == .agents {
            return Self.hugSize(cap: NotchMetrics.agentsIslandSize,
                                natural: state.tabHugHeight)
        } else if state.currentTab == .servers {
            return Self.hugSize(cap: NotchMetrics.serversIslandSize,
                                natural: state.tabHugHeight)
        } else if state.currentTab == .calendar {
            return metrics.calendarExpandedSize(monthMode: state.calendarMonthMode)
        }
        // Mirror rests at the STANDARD (media-sized) panel showing the
        // "Show Mirror" placeholder; only once the user opts in (wantsRunning)
        // does it expand to the zoomed footprint — and shrinks back on stop.
        let mirrorLive = state.currentTab == .mirror && mirror.wantsRunning
        return metrics.expandedSize(zoomed: mirrorLive, large: mirrorLive && state.mirrorBig)
    }

    /// Hug-sized tab panels (Agents/Servers): content height + the panel's
    /// vertical chrome (12 top + 14 bottom), clamped between a sane floor and
    /// the tab's cap. Before the first measurement lands, use the cap (a brief
    /// too-big beat beats a jump from tiny). SHARED MATH with AppDelegate's
    /// islandRect — change both or the hover rect drifts from the render.
    static func hugSize(cap: CGSize, natural: CGFloat?) -> CGSize {
        guard let natural else { return cap }
        return CGSize(width: cap.width,
                      height: min(cap.height, max(120, ceil(natural) + 26)))
    }

    private var island: some View {
        // GROUND-UP RULE: everything the collapsed island presents for media
        // keys off the SETTLED reveal signal (showMediaEar ← EarRevealModel),
        // never raw player state. Keying off raw `nowPlaying` popped the black
        // bar at full ear width the instant a track was detected — an
        // unliquified first "activation" — and the liquid morph then ran when
        // the state settled: the original "activates and animates twice",
        // present since before every debounce patch. One signal, one reveal.
        // (The pomodoro countdown ear keeps its plain fade, as before.)
        // `!fullscreenHidden` gates the pomodoro-countdown term too (showMediaEar
        // already carries it); one flag suppresses every collapsed adornment.
        let hasMedia = !fullscreenHidden
            && (showMediaEar || (pomodoro.isRunning && settings.timerCountdownEar))
        let hasToast = state.toast != nil && !fullscreenHidden
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
        // no longer fills / widens the bar. In pill mode there is no notch to
        // hide behind, so the standby pill is always visible and waiting to be
        // hovered (there, a toast grows the pill itself into a bubble).
        let collapsedVisible = hasMedia || !metrics.hasNotch
        // The nav dock appears ONLY on hover over its top strip (flush under
        // the notch); otherwise it retracts and the content panel slides up to
        // fill its height. Tab-swipes deliberately do NOT reveal it (user:
        // gesturing between pages needs no bar unless hovered) — the content
        // nudge + step haptics are the swipe feedback.
        let navShown = state.navHovered
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
            if metrics.hasNotch {
                ZStack(alignment: .topLeading) {
                    // The crisp backing owns the RESTING look. For the media ear the
                    // LiquidEar goo owns the flight and the backing only fades in over
                    // the last 10% (its full width is invisible until then, so there's
                    // no width-spring). The opacity window is NONLINEAR, so it MUST
                    // render through an Animatable relay — a plain `.opacity(f(earT))`
                    // interpolates linearly and fades the bar in from the very start.
                    NavTDriven(t: renderEarT) { e in
                        ZStack {
                            if collapsedVisible, !state.isExpanded { VisualEffectBlur() }
                            Color.black.opacity(!state.isExpanded && collapsedVisible ? 1 : 0)
                        }
                        .frame(width: metrics.collapsedSize(withMedia: hasMedia).width,
                               height: metrics.notchHeight)
                        .clipShape(NotchShape(topRadius: NotchMetrics.topFlare,
                                              bottomRadius: 10))
                        // Backing presence = the media-ear reveal OR the pomodoro
                        // countdown, taken independently (S1). The media term rides
                        // the goo morph (fades in over the last 10%); the pomodoro
                        // term is a steady 1. Keying opacity on `showMediaEar ? … : 1`
                        // conflated them: when music started over a running countdown
                        // the term jumped to smoothstep(0.9,1,~0)=0 for a frame — the
                        // countdown bar blinked out before the ear budded — and when
                        // music stopped with the countdown on, the `: 1` else pinned
                        // the bar fully opaque so the retracting goo had nothing to
                        // recede against. max() decouples the two: the countdown holds
                        // the bar steady while the media goo reveals/hides on top.
                        .opacity(max(showMediaEar ? smoothstep(0.9, 1, e) : 0,
                                     (pomodoro.isRunning && settings.timerCountdownEar) ? 1 : 0))
                    }

                    // E1 "Side Bulge": the notch's right flank swells into the ear.
                    // The mount branch is a STRUCTURAL decision on progress, so it
                    // MUST live inside the relay — evaluated in NotchView's body it
                    // sees only earT's END value (1), which fails `< 0.999`, and the
                    // morph never mounts during a real animation (the dead-ear bug).
                    NavTDriven(t: renderEarT) { e in
                        if !state.isExpanded, e > 0.02, e < 0.999 {
                            LiquidEar(t: e,
                                      notchWidth: metrics.notchWidth,
                                      notchHeight: metrics.notchHeight,
                                      earWidth: metrics.mediaEarWidth,
                                      debugPink: liquidEarPink)
                                .frame(width: metrics.notchWidth + metrics.mediaEarWidth
                                               + LiquidEar.rightPad,
                                       height: metrics.notchHeight
                                               + LiquidEar.vPadTop + LiquidEar.vPadBottom,
                                       alignment: .topLeading)
                                .offset(y: -LiquidEar.vPadTop)
                                .allowsHitTesting(false)
                        }
                    }

                    // Agent pill: horizontal bud-and-pinch off the island body (ear
                    // cap when music plays, else the notch flank). Same relay
                    // discipline as the ear — the mount branch reads mid-flight `e`, so
                    // it MUST live inside the NavTDriven. Drawn above the backing, below
                    // the HStack content, so the real label sharpens in on top at rest.
                    NavTDriven(t: renderAgentT) { e in
                        if !state.isExpanded, e > 0.02, e < 0.999, agentPillFrameLatch != .zero,
                           let pill = activePill ?? lastAgentPill {
                            LiquidAgent(t: e,
                                        notchWidth: metrics.notchWidth,
                                        notchHeight: metrics.notchHeight,
                                        earWidth: metrics.mediaEarWidth,
                                        hasEar: agentEarLatch,
                                        pillRect: agentPillFrameLatch,
                                        glyphCenterX: nil,
                                        countCenterX: nil,
                                        tint: pillTint(pill),
                                        debugPink: liquidAgentPink)
                                .frame(width: metrics.collapsedSize(withMedia: agentEarLatch,
                                                                    withAgent: true).width
                                               + LiquidAgent.rightPad,
                                       height: metrics.notchHeight
                                               + LiquidAgent.vPadTop + LiquidAgent.vPadBottom,
                                       alignment: .topLeading)
                                .offset(y: -LiquidAgent.vPadTop)
                                .allowsHitTesting(false)
                        }
                    }

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
                // The pill morph measures + draws in this space (island top-left).
                .coordinateSpace(name: "agentIsland")
                // Keep the LAST good measurement — when the pill fully hides the
                // GeometryReader unmounts and the preference reverts to .zero, which
                // would wipe the rect and leave the NEXT open with no rest target
                // until it re-measures (a late/again goo mount — the double-open).
                .onPreferenceChange(AgentPillFrameKey.self) { rect in
                    guard rect != .zero else { return }
                    agentPillFrame = rect
                    // Feed the goo a FROZEN target: seed it once per reveal (when the
                    // reveal edge cleared it to .zero), then only refresh it while the
                    // pill sits at rest. During a flight the last-seeded rect is held,
                    // so a mid-morph row reflow can't re-aim the capsule (S7).
                    if agentSettled || agentPillFrameLatch == .zero { agentPillFrameLatch = rect }
                }
                // Own its constant collapsed anchor (left edge flush at the notch).
                // Nothing here animates horizontally on expand — the bar just fades
                // IN PLACE, killing the old diagonal drag.
                .padding(.leading, metrics.islandLeadingPad(expanded: false))
                .frame(maxWidth: .infinity, alignment: .leading)
                // Hidden while expanded AND while the close liquid is still traveling
                // — the ears/pill may only appear after the mass has been absorbed
                // into the notch, not fade in over the morph (the reported ghost).
                .opacity((state.isExpanded || morphHoldExpanded) ? 0 : 1)
                // Quick fade, its own curve (closer than the container spring) so the
                // bar never rides the expanded panel's bubble motion.
                .animation(.easeOut(duration: 0.2), value: state.isExpanded)
                .animation(.easeOut(duration: 0.2), value: morphHoldExpanded)
            } else {
                // Pill mode (no notch — external display or clamshell): a
                // centered floating capsule sitting in the menu bar. Media grows
                // it into the now-playing pill; a toast grows it into the
                // two-line bubble (both rendered by `ears`). The agent pill
                // floats as its own glass capsule beside it, mirroring the notch
                // bar's layout. Centered by the container's .top alignment —
                // matches the `collapsed:` leading pad AppDelegate hit-tests on.
                ZStack {
                    if collapsedVisible, !state.isExpanded { VisualEffectBlur() }
                    Color.black.opacity(!state.isExpanded && collapsedVisible ? 1 : 0)
                }
                .frame(width: collapsedPillSize.width, height: collapsedPillSize.height)
                .overlay(alignment: .top) { ears }
                .clipShape(Capsule())
                .overlay {
                    // A hairline lifts the floating pill off the wallpaper.
                    if !state.isExpanded {
                        Capsule().strokeBorder(.white.opacity(0.08), lineWidth: 0.5)
                    }
                }
                .shadow(color: .black.opacity(0.35), radius: 6, y: 2)
                // The agent pill hangs OFF the pill's right edge as an overlay
                // rather than joining a centered HStack. Laid out as a pair the
                // two capsules shared the centering, which pushed the pill
                // itself ~20pt left of screen centre — while the close morph,
                // the hover zone and the hit rect all still aimed at dead
                // centre. An overlay takes no layout width, so the pill owns
                // the centre and extras grow rightward, exactly like the notch.
                .overlay(alignment: .trailing) {
                    agentPill
                        .fixedSize()
                        .alignmentGuide(.trailing) { d in d[.leading] - 6 }
                }
                // The pill rides vertically centered in the menu-bar strip.
                .offset(y: metrics.pillDrop)
                .opacity(state.isExpanded ? 0 : 1)
                .animation(.easeOut(duration: 0.2), value: state.isExpanded)
            }

            // Expanded: nav bar + content panel below the notch. The nav bar
            // "goo merges" — it buds up out of the panel's top edge on a liquid
            // neck that pinches off (LiquidNav), and melts back in on retract.
            // `navT` (0…1, spring-driven) drives the whole morph: the panel
            // shifts down to open the gap, the metaball forms the capsule, and
            // the controls fade in on top of it.
            // C4 "Surface Return": the liquid panel body that climbs into the
            // notch during close. Behind the real panel (which cross-fades out
            // early), it carries the travel; the nav capsule melt is LiquidNav.
            liquidCloseLayer

            ZStack(alignment: .top) {
                // Nav placement, one offset for goo AND controls:
                //  • Bottom mode (setting): the whole liquid nav hangs BELOW the
                //    panel; the goo runs MIRRORED (scaleEffect y:-1) so the same
                //    choreography bulges out of the panel's bottom edge.
                //  • Parked (pinned, top mode): rides up into the strip above
                //    the panel (free space — no hardware notch on a parked
                //    island). Full strip height buys a 4–9pt float gap; the
                //    droplet overshoot may kiss the window's top edge, which
                //    beats a merged rest state.
                let navOffsetY: CGFloat = settings.navAtBottom
                    ? expandedSize.height + NotchMetrics.navContentGap
                    : (state.parked ? -(metrics.notchHeight + NotchMetrics.islandGap) : 0)
                liquidNavLayer                       // goo capsule + neck (behind)
                    .scaleEffect(x: 1, y: settings.navAtBottom ? -1 : 1)
                    // Bottom mode: mirror the 89pt layer frame about the real
                    // panel's bottom edge — offset = panelH − frameH, so the
                    // canvas's internal surface line (outer row 0 with navSlot
                    // 0, flipped to row 89) lands exactly ON the panel bottom:
                    // the panel-wide swell tucks behind the real panel (it was
                    // fully exposed before — the "bigger bar"), and the rest
                    // capsule derives to the same 9pt slot as the crisp one.
                    .offset(y: settings.navAtBottom
                        ? expandedSize.height - (NotchMetrics.navIslandHeight
                                                 + NotchMetrics.navContentGap + 46)
                        : navOffsetY)
                // Real glass panel: cross-fades OUT early on close (the liquid
                // stand-in takes over) and IN over the last stretch on open. The
                // nonlinear window must live in an Animatable relay so it renders
                // every mid-flight value (rule: withAnimation snaps @State).
                NavTDriven(t: renderCloseT) { e in
                    expandedPanelLayer
                        .opacity(1 - smoothstep(0.10, 0.26, e))
                }
                navControlsLayer                     // tabs/pin/settings/quit (on top)
                    .offset(y: navOffsetY)
            }
            // Fixed width: the off-screen probe reports the widest reachable
            // control set (widest-titled tab selected) up front, and the capsule
            // is sized to exactly that on every page and every launch — no
            // monotonic "grow as you visit", no per-page resize. The probe rides
            // as a zero-footprint background so it measures even while collapsed.
            .background(navWidthProbe)
            .onPreferenceChange(NavWidthKey.self) { navBarWidth = $0 }
            // Same probe, the pill alone — locks the live pill's width so the
            // row stops breathing on page switches (see `tabBarWidth`).
            .onPreferenceChange(NavTabBarWidthKey.self) { tabBarWidth = $0 }
            .onPreferenceChange(NavTitleWidthKey.self) { titleSlot = $0 }
            .onPreferenceChange(TabIconCenterKey.self) { tabIconCenters = $0 }
            // Hug-sized tabs report their natural content height; published on
            // NotchState so AppDelegate's hover rect tracks the same height.
            .onPreferenceChange(TabHugHeightKey.self) { state.tabHugHeight = $0 }
            // CONSTANT width (this tab's panel), centered by the container's .top
            // alignment. It never changes width on expand — the Surface Return
            // choreography (LiquidClose) carries all vertical motion.
            .frame(width: expandedSize.width)
            .padding(.top, metrics.notchHeight + gap)
            // Interactivity gated to rest — mid-morph the controls aren't there.
            // `renderCloseT` here is the @State endpoint (closeT is set to its
            // target inside withAnimation), not the mid-morph value — the body
            // can't observe the animation. When open it is pinned at 0, so the
            // old `renderCloseT < 0.05` term was always true during open; when
            // closing, collapse() flips isExpanded false up-front so the `&&`
            // already short-circuits. The term therefore never gated anything —
            // the gate is exactly state.isExpanded.
            .allowsHitTesting(state.isExpanded)
            // Pinned = parkable: grab any non-interactive part of the panel or
            // nav capsule and drag the island anywhere (native window drag —
            // buttons/sliders/editors still win the gesture). Unpinning snaps
            // the window back to its notch home (AppDelegate's $pinned sink).
            // Availability-gated only for the deployment target — this Mac
            // (macOS 26) always takes the drag branch.
            .modifier(PinnedWindowDrag(enabled: state.pinned))
        }
        // Full-window width, non-animating horizontally — each layer owns its own
        // constant anchor, so expand/collapse has zero sideways drift.
        .frame(maxWidth: .infinity,
               minHeight: (state.isExpanded || morphHoldExpanded) ? totalExpandedHeight : size.height,
               maxHeight: (state.isExpanded || morphHoldExpanded) ? totalExpandedHeight : size.height,
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
        // Settings now swaps to the roomier zoomed panel — spring the resize
        // (there was no size change here before, so no key existed).
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: state.showingSettings)
        // Docked↔parked layout swap (nav strip placement, panel shift) springs
        // instead of snapping when the drag crosses the home threshold.
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: state.parked)
        // Hug-sized tabs (Agents/Servers) grow/shrink per row — spring it.
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: state.tabHugHeight)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: tray.items.count)
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: state.mirrorBig)
        // The placeholder→live mirror growth (standard → zoomed panel) rides
        // the click, keyed on intent so it starts before the camera does.
        .animation(.spring(response: 0.32, dampingFraction: 0.85), value: mirror.wantsRunning)
        .animation(.spring(response: 0.35, dampingFraction: 0.82), value: hasMedia)
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: hasToast)
        // Drive `navT` on a plain easeInOutCubic timing curve — NO spring or
        // overshoot (that's variant 03): 0.85 s to swell the surface into the
        // capsule, 0.70 s to sink it back. `-LiquidNavDebug` stretches both 8×
        // for screenshot tuning. Collapsing snaps to 0 with no animation so the
        // next expand starts from a flat surface.
        .onChange(of: navShown) { show in
            // Any pending melt dies the moment the nav is wanted again.
            navHideWork?.cancel()
            navHideWork = nil
            if show {
                // GESTURE-driven reveals don't liquid-morph: while swiping,
                // the bar is a tab indicator and must be there NOW, static —
                // the full bulge is for deliberate hover reveals. A swipe
                // gets a quick pop-in instead of an 0.85s goo cycle.
                let swipeDriven = abs(state.tabSwipeProgress) > 0.01
                navShowWasSwipe = swipeDriven
                let dur = swipeDriven ? 0.12 : 0.85 * (liquidNavDebug ? 8 : 1)
                withAnimation(.timingCurve(0.65, 0, 0.35, 1, duration: dur)) {
                    navT = 1
                }
            } else {
                // DEBOUNCED melt: the tab-swipe ratchet passes tabSwipeProgress
                // through ZERO at every committed step, flickering navShown
                // false for a frame — which restarted the full 0.85s morph over
                // and over mid-gesture (the reported glitching). Only melt after
                // navShown has been continuously false for a beat; a flicker
                // cancels it and the capsule stays put under the gesture.
                let work = DispatchWorkItem {
                    withAnimation(.timingCurve(0.65, 0, 0.35, 1,
                                               duration: 0.70 * (liquidNavDebug ? 8 : 1))) {
                        navT = 0
                    }
                }
                navHideWork = work
                // Swipe-revealed bars LINGER (1s) so back-to-back swipes never
                // cycle melt/reveal; hover-away melts on the short fuse.
                let linger = navShowWasSwipe ? 1.0 : 0.25
                DispatchQueue.main.asyncAfter(deadline: .now() + linger, execute: work)
            }
        }
        // Drive `earT` (E1 Side Bulge) on easeInOutCubic: 0.70 s show / 0.55 s
        // hide, per the motion contract. `-LiquidIslandDebug` stretches both 6×.
        // DUMB BY DESIGN: all settling/artwork/absence timing lives in
        // EarRevealModel, which emits only true edges — every edge here is a
        // real morph, and nothing can restart one mid-flight.
        .onChange(of: showMediaEar) { show in
            let dur = (show ? 0.70 : 0.55) * (liquidIslandDebug ? 6 : 1)
            withAnimation(.timingCurve(0.65, 0, 0.35, 1, duration: dur)) {
                earT = show ? 1 : 0
            }
            if show {
                earLinger = false
            } else {
                // Keep the row mounted while the liquid hide plays; unmount
                // happens after, invisibly (content opacity is long at 0).
                earLinger = true
                DispatchQueue.main.asyncAfter(deadline: .now() + dur + 0.1) {
                    if !showMediaEar { earLinger = false }
                }
            }
        }
        // Content latches: value→value only, so churn-nil ticks and async
        // artwork decodes can never blink the mounted ear row.
        .onChange(of: media.nowPlaying) { np in
            guard let np else { return }   // keep the last through nil churn ticks
            // Drop the cached cover when the TRACK changes so `?? lastArtwork`
            // can't pair a fresh title with the previous track's art (S2). Within
            // a track (metadata refresh / churn) the cached art is kept — that's
            // what stops the thumbnail blinking on nil ticks.
            if np.title != lastNowPlaying?.title || np.artist != lastNowPlaying?.artist {
                lastArtwork = nil
            }
            lastNowPlaying = np
        }
        .onChange(of: media.artwork) { art in
            if let art { lastArtwork = art }   // only non-nil: nil churn keeps the last
        }
        // Drive `agentT` (LiquidAgent bud-and-pinch) on the same easeInOutCubic:
        // 0.60 s show / 0.50 s hide, 6× under the debug harness. Keyed on
        // `showAgentPill` (pill present, no toast), so waiting→working→complete
        // state changes never re-run the liquid — only appear/disappear + the
        // toast handoff (toast steals the slot → melt; toast clears → re-bud).
        .onChange(of: showAgentPill) { show in
            // Latch the donor geometry at the edge — the goo must not re-aim
            // mid-flight if the media ear settles during the bud.
            agentEarLatch = showMediaEar
            // Re-seed the goo's TARGET rect for this reveal: clearing it makes the
            // next AgentPillFrameKey measurement (this reveal's rest frame, which
            // matches the ear state just latched) the frozen target for the whole
            // flight (S7).
            if show { agentPillFrameLatch = .zero }
            let base = show ? 0.60 : 0.50
            let dur = base * (liquidAgentDebug ? 6 : 1)
            agentSettled = false   // morph in flight — suppress the label spring
            // Keep the crisp label mounted through the disappear leg (mirrors
            // earLinger) so it hands off to the goo instead of popping to blank.
            if show {
                agentLinger = false
            } else {
                agentLinger = true
                DispatchQueue.main.asyncAfter(deadline: .now() + dur + 0.1) {
                    if !showAgentPill { agentLinger = false }
                }
            }
            withAnimation(.timingCurve(0.65, 0, 0.35, 1, duration: dur)) {
                agentT = show ? 1 : 0
            }
            // Mark settled when the morph finishes (the withAnimation completion
            // API needs macOS 14; this deployment target is lower). Re-check the
            // intent on fire: a newer toggle may have superseded this leg, in
            // which case it already reset agentSettled and scheduled its own.
            DispatchQueue.main.asyncAfter(deadline: .now() + dur) {
                if show == showAgentPill { agentSettled = show }
            }
        }
        // Remember the pill that's melting away so the disappear leg can still
        // render its label/tint after `activePill` has already gone nil.
        .onChange(of: activePill) { pill in
            if let pill { lastAgentPill = pill }
        }
        // Seed the ear + pill at rest if already present at launch (onChange
        // never fires for the initial value, so it would otherwise never reveal).
        .onAppear {
            if showMediaEar { earT = 1 }
            if showAgentPill { agentT = 1; agentSettled = true; lastAgentPill = activePill }
            closeT = state.isExpanded ? 0 : 1
        }
        // Drive `closeT` (C4 Surface Return) on easeInOutCubic: 0.85 s close /
        // 0.70 s open. The nav capsule's melt (navT→0, animated below) is chained
        // as the opening beat, not duplicated here. 6× under LiquidIslandDebug.
        .onChange(of: state.isExpanded) { expanded in
            let base = expanded ? 0.70 : 0.85
            let dur = base * (liquidIslandDebug ? 6 : 1)
            withAnimation(.timingCurve(0.65, 0, 0.35, 1, duration: dur)) {
                closeT = expanded ? 0 : 1
            }
            // Hold the container at expanded height for the whole close morph so
            // the legacy collapse spring can't crush the liquid's canvas; release
            // just past the duration (the snap is invisible — all mass is inside
            // the notch by then). Expanding cancels any pending hold instantly.
            if expanded {
                morphHoldExpanded = false
            } else {
                morphHoldExpanded = true
                DispatchQueue.main.asyncAfter(deadline: .now() + dur + 0.05) {
                    guard !state.isExpanded else { return }
                    morphHoldExpanded = false
                    // No exhale replay (ground-up simplification): the ear kept
                    // earT=1 while the panel was open, so the collapsed bar
                    // returns WHOLE with its own 0.2s fade — one calm entrance.
                    // The old reset-and-replay was a deliberate second ear
                    // animation and read as part of "it animates twice".
                }
            }
            // Animate the nav melt (was a hard snap) so it reads as the capsule-
            // melt beat of the close, then rests flat for the next expand.
            if !expanded {
                withAnimation(.timingCurve(0.65, 0, 0.35, 1, duration: 0.30 * (liquidIslandDebug ? 6 : 1))) {
                    navT = 0
                }
            }
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
        .onChange(of: state.frontmostIsFullscreen) { _ in
            // Entering/leaving fullscreen hides the collapsed ear (fullscreenHidden),
            // so drop/restore the system-audio tap with it — no purple recording
            // indicator over fullscreen video.
            spectrum.setActive(spectrumShouldBeActive)
        }
        .onChange(of: settings.hideInFullscreen) { _ in
            // Toggling the "Hide in fullscreen" setting flips fullscreenHidden while
            // already in fullscreen — re-evaluate the tap to match.
            spectrum.setActive(spectrumShouldBeActive)
        }
        .onChange(of: dropTargeted) { targeted in
            if targeted && !state.isExpanded && settings.trayOpenOnDrag {
                state.currentTab = .tray
                state.onExpandRequest?()
            }
        }
        .onChange(of: state.isExpanded) { expanded in
            applyGating(expanded: expanded, tab: state.currentTab,
                        settingsShowing: state.showingSettings)
            // No mirror auto-restart on expand: the tab DEFAULTS to the
            // "Show Mirror" placeholder at standard size — the camera runs
            // only after the user's click (collapse stops it and clears the
            // intent, so every fresh open is opt-in again).
        }
        .onChange(of: state.showingSettings) { showing in
            // The overlay replaces the tab's content — pause the camera under
            // it and hand focus/polling back when it closes. Resume ONLY a
            // camera that was live before the overlay: the opt-in placeholder
            // must never auto-start on settings close.
            // The settings overlay hides the tab's content, so the tab's work
            // should stop too — this handler used to leave stats/servers/media
            // polling behind an overlay that showed none of their output.
            applyGating(expanded: state.isExpanded, tab: state.currentTab,
                        settingsShowing: showing)
            if state.currentTab == .mirror {
                if showing {
                    mirrorPausedForSettings = mirror.wantsRunning
                    mirror.stop()
                } else if mirrorPausedForSettings {
                    mirrorPausedForSettings = false
                    mirror.resumeIfAuthorized()
                }
            }
        }
        .onChange(of: state.currentTab) { tab in
            applyGating(expanded: state.isExpanded, tab: tab,
                        settingsShowing: state.showingSettings)
            if tab != .mirror {
                mirror.stop()
                if !settings.mirrorRememberBig { state.mirrorBig = false }
            }
        }
    }

    /// The single place that decides which per-tab work is allowed to run.
    ///
    /// This used to be three handlers that each applied their own subset: none
    /// of them accounted for the settings overlay, and eight of the eleven
    /// models were never mentioned at all, so their timers and observers ran
    /// forever regardless of what was on screen.
    private func applyGating(expanded: Bool, tab: NotchTab, settingsShowing: Bool) {
        // Visible = expanded AND not buried under the settings overlay.
        let live = expanded && !settingsShowing
        editorFocused = live && tab == .notes
        media.setProgressPolling(live && tab == .media)
        media.setYouTubePolling(live && tab == .media)
        stats.setPolling(live && tab == .stats)
        servers.setPolling(live && tab == .servers)
        calendarModel.setVisible(live && tab == .calendar)
        toggles.setPolling(live && tab == .toggles)
        // Not a hard gate: the agents model also drives the collapsed pill, so it
        // only steps DOWN to a slower cadence off-screen (see setForeground).
        agentSessions.setForeground(live && tab == .agents)
        spectrum.setActive(spectrumShouldBeActive)
    }

    /// Whether the audio tap should be running: the live-waveform setting is on,
    /// something is actually playing, and a waveform is on screen — the expanded
    /// media panel OR the collapsed ear's little equalizer. (Off via the setting
    /// never creates the tap — privacy; the bars fall back to synthetic motion.)
    private var spectrumShouldBeActive: Bool {
        settings.liveWaveform
            && media.nowPlaying?.isPlaying == true
            && (state.isExpanded || (!media.earHidden && !fullscreenHidden))
    }

    /// Dynamic Island ears: album art on the left, live activity on the right.
    /// (Toasts moved OUT of the bar into their own floating capsule — `toastCapsule`.)
    private var ears: some View {
        // Arbitration + mounting keyed on the SETTLED signal (showMediaEar /
        // earLinger), never raw player state: raw keys made this row pop
        // layout width at detection time (before the reveal), blink on
        // track-churn nil ticks, and vanish instantly on stop while the
        // liquid hide ran on an empty bar — all read as double activations.
        let mediaEarMounted = (showMediaEar || earLinger) && !state.isExpanded
        return Group {
            if let toast = state.toast, !state.isExpanded, !metrics.hasNotch {
                // Pill mode: a centered song-change bubble — artwork + two
                // lines of text, filling the taller toast pill. (With a notch
                // the toast is its own floating capsule — `toastCapsule`.)
                HStack(spacing: 10) {
                    if toast.useArtwork, let art = media.artwork {
                        Image(nsImage: art)
                            .resizable()
                            .aspectRatio(contentMode: .fill)
                            .frame(width: 30, height: 30)
                            .clipShape(RoundedRectangle(cornerRadius: 7))
                    } else {
                        Image(systemName: toast.icon)
                            .font(.system(size: 15))
                            .foregroundStyle(toast.color)
                    }
                    VStack(alignment: .leading, spacing: 1) {
                        Text(toast.title)
                            .font(.system(size: 11, weight: .semibold))
                            .foregroundStyle(.white)
                            .lineLimit(1)
                        if let sub = toast.subtitle {
                            Text(sub)
                                .font(.system(size: 9))
                                .foregroundStyle(.white.opacity(0.6))
                                .lineLimit(1)
                        }
                    }
                }
                .padding(.horizontal, 14)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .transition(.opacity)
            } else if pomodoro.isRunning, settings.timerCountdownEar,
                      !mediaEarMounted,
                      !fullscreenHidden,
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
            } else if mediaEarMounted, let np = media.nowPlaying ?? lastNowPlaying {
                // Right ear only: never cover the frontmost app's menu items.
                // Wrapped in the Animatable relay so the crisp content fade-in
                // (nonlinear iconIn window) renders every mid-flight value —
                // otherwise it ghosts in linearly over the whole reveal, on top
                // of the goo, instead of sharpening in only at the end.
                NavTDriven(t: renderEarT) { earE in
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
                                artworkThumb(side: collapsedEarHeight - 10)
                                Group {
                                    if np.isPlaying {
                                        // A dead tap must not animate: the
                                        // synthetic sine is indistinguishable
                                        // from a live waveform, so a denied
                                        // permission would look like it works.
                                        LiveEqualizer(barCount: 4,
                                                      maxHeight: metrics.hasNotch ? 14 : 12,
                                                      color: media.accent)
                                    } else {
                                        Image(systemName: "play.fill")
                                            .font(.system(size: metrics.hasNotch ? 10 : 11))
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
                 .frame(height: collapsedEarHeight)
                 // The dots carry the content through flight; the real views
                 // sharpen in only over the last 16% (the goo's `iconIn` window).
                 // At rest this is 1, so the hover→transport morph works normally.
                 .opacity(smoothstep(0.84, 1, earE))
                }
                // The LiquidEar goo + the relay opacity above OWN both the
                // reveal AND the exit (earLinger keeps this mounted through
                // the hide morph; content opacity is already 0 at unmount).
                // Any transition here fires a competing fade on top of the
                // goo — that was the reported activation glitch.
                .transition(.identity)
            }
        }
    }

    /// Transient notification as its OWN small floating glass capsule beside the
    /// notch — icon + one line, just enough to carry the message. Simple fade/
    /// scale in and out (no morph), driven by `state.toast`. It takes the same
    /// outboard slot as the agent pill (which hides while a toast is up).
    private var toastCapsule: some View {
        Group {
            if let toast = state.toast, !state.isExpanded, !fullscreenHidden {
                HStack(spacing: 7) {
                    // Latched art (value→value): a churn-nil or late decode
                    // must not swap the capsule's leading image mid-display.
                    if toast.useArtwork, let art = media.artwork ?? lastArtwork {
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
                .islandSurface(Capsule(), style: surfaceStyle, dim: 0.4)
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
            // Mounted through the whole morph — including the disappear leg, when
            // `activePill` is already nil (we render the melting `lastAgentPill`).
            if showAgentPill || agentLinger || renderAgentT > 0.001, let pill = activePill ?? lastAgentPill {
                NavTDriven(t: renderAgentT) { e in
                    Button {
                        state.currentTab = .agents
                        state.onExpandRequest?()
                    } label: {
                        AgentPillLabel(pill: pill, surfaceStyle: surfaceStyle)
                    }
                    .buttonStyle(.plain)
                    // Invisible during flight — the LiquidAgent goo carries the
                    // capsule + glyph; the crisp label sharpens in only at rest
                    // (same iconIn window as the ear/nav). Rendered through the
                    // relay so the nonlinear window draws every mid-flight value.
                    .opacity(smoothstep(0.86, 1, e))
                    // Measure the resting capsule (island space) for the goo target.
                    // Layout is opacity-independent, so this stays the rest frame
                    // throughout the flight.
                    .background(GeometryReader { g in
                        Color.clear.preference(key: AgentPillFrameKey.self,
                            value: g.frame(in: .named("agentIsland")))
                    })
                    // Tappable only once settled — mid-flight there's no real pill.
                    .allowsHitTesting(e > 0.98)
                }
                // State changes (waiting→working→complete) keep this subtle spring —
                // but ONLY once the pill is settled. While the liquid morph runs the
                // spring is disabled (nil), so it can't ALSO animate the label's
                // appearance on mount: that double motion (goo bud + spring pop) was
                // the reported "double open". The liquid owns appear/disappear alone.
                .animation(agentSettled ? .spring(response: 0.3, dampingFraction: 0.78) : nil,
                           value: pill)
            }
        }
        .frame(height: metrics.notchHeight, alignment: .center)
    }

    /// The pill's glyph + count capsule; `.working` gets a gently pulsing dot.
    private struct AgentPillLabel: View {
        let pill: AgentSessionsModel.CollapsedPill
        /// Passed down rather than resolved here: this is a nested type, so it
        /// can't reach `NotchView.surfaceStyle`, and giving it its own
        /// `@EnvironmentObject` would make it re-render on every settings change.
        let surfaceStyle: IslandSurfaceStyle
        /// Drives the one-second entry pulse and then stops. Not a ticker.
        @State private var entered = false

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
                    // A STATIC dot after a brief entry pulse — nothing here may
                    // tick at steady state.
                    //
                    // Two earlier shapes both got this wrong. `.repeatForever`
                    // kept a live animator in the view graph; replacing it with
                    // a 20 Hz TimelineView Canvas cut the redraw cost but kept
                    // the update rate, and the update is what hurts: each tick
                    // schedules a view-graph pass through the single hosting
                    // view, which relayouts the whole current tab — mounted at
                    // opacity 0 behind the closed notch. Twenty of those a
                    // second is the entire C4 burn.
                    //
                    // Apple's own island signals background state with colour
                    // and glyph, not perpetual motion (visual advice §9-1).
                    Circle()
                        .fill(tint)
                        .frame(width: 7, height: 7)
                        .opacity(entered ? 1 : 0.35)
                        .onAppear {
                            // Bounded: 4 half-cycles at 0.25 s = 1 s, then it
                            // settles and schedules nothing further.
                            withAnimation(.easeInOut(duration: 0.25)
                                .repeatCount(4, autoreverses: true)) {
                                entered = true
                            }
                        }
                        .onDisappear { entered = false }
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
            // Its own capsule that floats — matching the nav/content islands
            // rather than sitting inside the black notch bar.
            .islandSurface(Capsule(), style: surfaceStyle, dim: 0.4)
            .shadow(color: .black.opacity(0.45), radius: 5, y: 2)
        }
    }

    private func artworkThumb(side: CGFloat) -> some View {
        Group {
            if let art = media.artwork ?? lastArtwork {
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
    /// Where each page's glyph actually sits in the chip row. MEASURED, not
    /// derived: the icons are SF Symbols whose widths differ per symbol, so
    /// accumulating paddings and gaps would drift a point or two per chip and the
    /// bead would sit visibly off-centre on some pages.
    private struct TabIconCenterKey: PreferenceKey {
        static var defaultValue: [NotchTab: CGFloat] = [:]
        static func reduce(value: inout [NotchTab: CGFloat],
                           nextValue: () -> [NotchTab: CGFloat]) {
            value.merge(nextValue()) { _, new in new }
        }
    }

    /// The travelling bead, in its own layer BEHIND the chips.
    ///
    /// This is the arrangement that satisfies both constraints at once. The
    /// container may keep drawing its glass above its own siblings — there are no
    /// glyphs in here to ruin, only the bead — while the chips, glyphs and titles
    /// live entirely OUTSIDE it and stay crisp. Same shape as the fix for the
    /// nav-pearling washout: glass in the container, content above it.
    ///
    /// ONE bead that persists and slides, NOT a per-chip bead morphed by a shared
    /// `glassEffectID`. That was the first attempt and it crossfades rather than
    /// travels: filmed at 10×, the bead sat on the old glyph while a second one
    /// formed on the new one. `glassEffectID` only reads as movement when the two
    /// shapes are within the container's merge distance, and adjacent glyphs here
    /// are ~55pt apart with the far ends ~180pt — nothing to morph through.
    ///
    /// A single view whose `offset` animates does travel, and it rides the row's own
    /// spring, so the bead and the chips move on exactly one curve. No container
    /// either: without `glassEffectID` it buys nothing, and less machinery in the
    /// glass path is strictly better.
    @available(macOS 26.0, *)
    private struct BeadLayer: View {
        let selected: NotchTab
        let centers: [NotchTab: CGFloat]

        var body: some View {
            // Nothing until the first layout reports where the glyphs are —
            // otherwise the bead would start at x=0 and fly in from the pill's edge.
            if let cx = centers[selected] {
                Color.clear
                    .frame(width: 22, height: 22)
                    .glassEffect(.regular, in: Circle())
                    // Leading-aligned layer, so centre − radius puts the bead's
                    // middle on the glyph.
                    .offset(x: cx - 11)
                    .allowsHitTesting(false)
            }
        }
    }

    /// The selected page's title arriving.
    ///
    /// A bare `if selected { Text(…) }` drops the label in at full size and full
    /// weight the instant the chip has room for it, which is the fast sideways pop:
    /// the chip's capsule is still springing open rightward while the finished
    /// label is already sitting there, so the label reads as being shoved out
    /// sideways by the growing pill rather than as belonging to it.
    ///
    /// This resolves it out of nothing instead. Anchored at the LEADING edge, so
    /// the growth runs the same direction the pill is opening and the glyph beside
    /// it never appears to shift; blurred at the start, so it condenses into focus
    /// the way the glass settles rather than snapping to sharp. `.blurReplace`
    /// would be the stock equivalent but it is macOS 14+, and this ships to 13.
    /// No horizontal scale here — the chip's `.clipShape(Capsule())` already does
    /// the sideways reveal, and doing both made the glyphs stretch. This is only
    /// the softness: the label condenses out of a blur as the capsule uncovers it,
    /// so it resolves into focus rather than arriving finished.
    private struct TitleReveal: ViewModifier {
        let shown: Bool
        func body(content: Content) -> some View {
            content
                .blur(radius: shown ? 0 : 2.5)
                .opacity(shown ? 1 : 0)
        }
    }

    /// Window-drag for the pinned island. `WindowDragGesture` is macOS 15+;
    /// below that the modifier is inert (pin still holds the island open, it
    /// just isn't parkable).
    private struct PinnedWindowDrag: ViewModifier {
        let enabled: Bool
        func body(content: Content) -> some View {
            if #available(macOS 15.0, *) {
                content.gesture(WindowDragGesture(), isEnabled: enabled)
            } else {
                content
            }
        }
    }

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
    /// Widest reachable pages-pill width, reported by the off-screen probe only
    /// (one layout per visible tab, max-reduced) and used to LOCK the live pill
    /// to that width. See `tabBarWidth`.
    private struct NavTabBarWidthKey: PreferenceKey {
        static var defaultValue: CGFloat = 0
        static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
            value = max(value, nextValue())
        }
    }
    /// Widest page TITLE, again from the probe only. The selected chip reserves
    /// exactly this much for its label whatever page it is, which is what keeps the
    /// chip row's total width constant. See `titleSlot`.
    private struct NavTitleWidthKey: PreferenceKey {
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
            // Clamp against the STANDARD panel width (a constant), not this tab's
            // panel, so the capsule can't vary between a wide page (terminal 620)
            // and a standard one (460) — and so the pill is never WIDER than the
            // island it sits under. navBarWidth is the fixed widest-control width
            // from the probe; +22 is breathing room. The chip metrics below are
            // sized so a full tab set still measures under this ceiling instead of
            // overflowing it (which used to chop the end controls off).
            let navBlobW = min(metrics.expandedSize().width - 16, navBarWidth + 22)
            // Cross-fade the flat goo out and the real glass capsule in over the
            // last of the settle (e ∈ [0.9,1]): the metaball's flat fill only
            // ever shows in flight; at rest the nav is the same VisualEffectBlur
            // glass as the panel, so materials + shadows match the pre-goo look.
            let s = min(1, max(0, (navT - 0.9) / 0.1))
            // Pink harness: no cross-fade, no dimming — show the raw silhouette.
            let rest = liquidNavPink ? 0 : s * s * (3 - 2 * s)  // 0 mid-flight → 1 settled
            // CONSTANT canvas world: framed to the STANDARD panel width, never
            // this tab's. Tabs differ in panel size (media 460 / agents 470 /
            // terminal 620), so a swipe's per-step tab commits were resizing
            // the goo canvas through the container spring — the capsule
            // convulsed on every ratchet step (the reported gesture glitching).
            let stdW = metrics.expandedSize().width
            ZStack(alignment: .top) {
                LiquidNav(t: navT,
                          panelWidth: stdW,
                          navWidth: navBlobW,
                          navHeight: NotchMetrics.navIslandHeight,
                          // Full slot in BOTH modes — identical choreography
                          // (dots, droplet, travel). Bottom mode compensates
                          // the baked-in surface motion with the animated
                          // counter-offset below, not by shortening the morph
                          // (navSlot 0 compressed the travel — user-flagged
                          // "the dots animation is better in the top nav").
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
                    .frame(width: stdW,
                           height: NotchMetrics.navIslandHeight + NotchMetrics.navContentGap + 46 + 18)
                    .offset(y: -18)
                    .shadow(color: .black.opacity(0.45), radius: 12,
                            // Negate in bottom mode: the whole layer is mirrored
                            // (scaleEffect y:-1), which would flip a y:5 shadow to
                            // y:-5 and cast it UP into the panel. Pre-negating puts
                            // it back to +5 post-flip, so the capsule shadow falls
                            // DOWNWARD like the panel's own shadow in both modes.
                            y: settings.navAtBottom ? -5 : 5)
                    .opacity(1 - rest)
                // Real crisp capsule, same footprint as the settled goo capsule
                // (flip-invariant; the whole layer mirrors in bottom mode).
                // Hairline rim so the glass capsule reads as ONE bounded surface
                // enclosing every control (tabs + pin/gear/power). The capsule
                // already encloses them geometrically, but the dark frosted fill
                // is near-invisible against the desktop, so pin/gear/power looked
                // orphaned past the tab-bar's own inner pill. Every other frosted
                // island — the track toast, the count badge, the content panel —
                // carries this same .14 white stroke; the nav capsule was the lone
                // exception. `islandSurface` now paints all of them.
                Color.clear
                    .islandSurface(RoundedRectangle(cornerRadius: 16, style: .continuous),
                                   style: surfaceStyle)
                    .frame(width: navBlobW, height: NotchMetrics.navIslandHeight)
                    .shadow(color: .black.opacity(0.45), radius: 12,
                            // Negate in bottom mode: the whole layer is mirrored
                            // (scaleEffect y:-1), which would flip a y:5 shadow to
                            // y:-5 and cast it UP into the panel. Pre-negating puts
                            // it back to +5 post-flip, so the capsule shadow falls
                            // DOWNWARD like the panel's own shadow in both modes.
                            y: settings.navAtBottom ? -5 : 5)
                    .opacity(rest)
            }
            // Bottom mode's ANIMATED mirror anchor: the canvas bakes the
            // panel-shift into its surface line (43·navT downward). Counter it
            // pre-flip (−43·navT; the call-site mirror negates it to +43·navT),
            // which pins the flipped surface line ON the real panel's bottom
            // edge for EVERY morph value — full choreography, zero drift.
            // Lives inside the relay so it renders each mid-flight frame.
            .offset(y: settings.navAtBottom
                ? -(NotchMetrics.navIslandHeight + NotchMetrics.navContentGap) * navT
                : 0)
            .frame(width: stdW,
                   height: NotchMetrics.navIslandHeight + NotchMetrics.navContentGap + 46,
                   alignment: .top)
            .allowsHitTesting(false)
            }
        }
    }

    /// C4 Surface Return stand-in: spans the notch down to the panel bottom, one
    /// window-centered canvas so its center aligns with the notch. Wrapped in the
    /// Animatable relay so its close-progress branch + opacity window render every
    /// mid-flight frame. Fades in as the real glass fades out, and fades out at the
    /// very end as the collapsed island (bare notch) takes over.
    /// The collapsed pill's LIVE resting size in pill mode — standby, taller
    /// now-playing, or toast bubble. Read off the same settled signals the pill
    /// renders from (`showMediaEar`, not raw player state), so anything aiming
    /// at the pill — the close morph, the hit rect — can never target a size the
    /// pill won't actually be.
    private var collapsedPillSize: CGSize {
        let media = !fullscreenHidden
            && (showMediaEar || (pomodoro.isRunning && settings.timerCountdownEar))
        return metrics.collapsedSize(withMedia: media,
                                     toast: state.toast != nil && !fullscreenHidden)
    }

    /// Height the collapsed media row lays out in: the notch strip on a MacBook,
    /// the taller now-playing pill on a notchless display. Art and waveform size
    /// off this, so the row fills the pill instead of floating in it.
    private var collapsedEarHeight: CGFloat {
        metrics.hasNotch ? metrics.notchHeight : NotchMetrics.pillMediaHeight
    }

    private var liquidCloseLayer: some View {
        // Prefer the size latched at collapse start (S11): a zoomed Mirror has
        // already reverted `expandedSize` to standard by the time this renders,
        // so recomputing it would start the Surface Return from the wrong rect.
        // `.zero` (every non-mirror close) falls back to the live expandedSize.
        let panel = state.closePanelSize == .zero ? expandedSize : state.closePanelSize
        // Pill mode: the mass has to land ON the resting pill, and the pill's
        // size is LIVE — a close while music plays settles onto the wider
        // now-playing pill, a close at standby onto the small one. Read it from
        // the same settled signals the pill itself renders off, so the goo can
        // never aim at a size the pill won't be.
        let canvasW: CGFloat = panel.width + 2 * LiquidClose.hPad
        let pillRest: CGRect? = metrics.hasNotch ? nil : {
            let s = collapsedPillSize
            return CGRect(x: (canvasW - s.width) / 2, y: metrics.pillDrop,
                          width: s.width, height: s.height)
        }()
        let stack: CGFloat = metrics.notchHeight + NotchMetrics.islandGap
            + NotchMetrics.navIslandHeight + NotchMetrics.navContentGap
        let canvasH: CGFloat = stack + panel.height + LiquidClose.botPad
        // The real panel's rest position depends on the nav reveal
        // (expandedPanelLayer shifts down by navShift·navT), and navT is
        // ANIMATING during the close's first beat (the 0.30 s melt) — so the
        // shift must ride its own Animatable relay, nested with the close's,
        // for the goo to track the panel it replaces frame by frame.
        return NavTDriven(t: renderNavT) { navE in
            NavTDriven(t: renderCloseT) { e in
            if e > 0.02, e < 0.999 {
                // Fade IN as the real glass fades out; then hold FULL opacity all
                // the way into the notch — the body is geometrically fused to the
                // notch from e≈0.72 (topY reaches the underside), so any earlier
                // fade turns the already-merged mass into a ghost (user-flagged).
                // The only fade is the final 0.97→1 swap to the real black notch,
                // which the body has already coincided with — imperceptible.
                let bodyOp = smoothstep(0.06, 0.20, e) * (1 - smoothstep(0.97, 1.0, e))
                LiquidClose(t: e,
                            notchWidth: metrics.notchWidth,
                            notchHeight: metrics.notchHeight,
                            gap: NotchMetrics.islandGap,
                            // Bottom-nav mode never shifts the panel, so the
                            // goo's rest geometry is the unshifted layout.
                            navShift: settings.navAtBottom ? 0
                                : (NotchMetrics.navIslandHeight
                                   + NotchMetrics.navContentGap) * CGFloat(navE),
                            panelWidth: panel.width,
                            panelHeight: panel.height,
                            pillRest: pillRest,
                            debugPink: liquidClosePink)
                    .frame(width: canvasW, height: canvasH, alignment: .top)
                    .opacity(bodyOp)
                    .allowsHitTesting(false)
            }
            }
        }
        .frame(maxWidth: .infinity, alignment: .top)
    }

    /// The content panel, shifted down as the nav emerges and up as it melts.
    /// PINNED the panel never shifts (user: an out-of-position island must not
    /// move when the bar comes and goes) — the capsule keeps its full bulge
    /// choreography and simply rests OVER the panel's top edge, a transient
    /// floating toolbar instead of a space-maker.
    private var expandedPanelLayer: some View {
        // No shift when parked (island must not move) NOR in bottom-nav mode
        // (the bar grows downward below the panel — nothing needs the room).
        let shift = (state.parked || settings.navAtBottom) ? 0
            : (NotchMetrics.navIslandHeight + NotchMetrics.navContentGap) * CGFloat(renderNavT)
        return contentIsland(size: expandedSize)
            .frame(width: expandedSize.width, height: expandedSize.height)
            // The panel's material lives here rather than inside `contentIsland`
            // because this is where the shape is: `islandSurface` paints the
            // ground, clips to it, and (rim off — the panel has never carried the
            // .14 hairline the smaller islands do) leaves the edge bare.
            // Corner radius relaxes slightly in flight (34 hidden → 26 open) for
            // the soft "bubble" read; animatable via the spring.
            .islandSurface(RoundedRectangle(cornerRadius: state.isExpanded ? 26 : 34,
                                            style: .continuous),
                           style: surfaceStyle, rim: false)
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
            // The dot metaball carries the icons until the very end, then the
            // crisp controls cross-fade in over iconIn = smooth(0.84, 1) with a
            // gentle scale-up, so the dots sharpen INTO the real icons.
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
        HStack(spacing: 8) {
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
            // Optically center the pin/gear/power trio in its own section (the
            // frosted band between the pages pill's right edge and the capsule's
            // right glass edge). The pages pill is drawn +6pt past its measured
            // row (the −6 capsule overhang below), so the visual gap from pill to
            // pin is only 8−6 = 2pt, while the right side has the 12pt trailing pad
            // PLUS the capsule's clamp breathing (~6.75pt at the 10-tab width) =
            // ~18.75pt — the trio hugged the pill. Shifting it right by (18.75−2)/2
            // ≈ 8pt equalizes the two gaps. This +8 leading is REDISTRIBUTED, not
            // added: the row's trailing pad drops 12→4 by the same 8pt, so
            // navBarWidth (and the 444 ceiling / capsule size) is unchanged, and
            // the tab dock stays put — only the trio moves.
                .padding(.leading, 8)
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
        // Asymmetric to bank the +8 leading the pin trio spends (see above): the
        // leading stays 12, the trailing drops to 4 so the row's total width — and
        // thus navBarWidth and the capsule — is byte-for-byte the same as symmetric
        // 12/12. The measuring/probe path runs this identical code, so the fixed
        // capsule width never moves.
        .padding(.leading, 12)
        .padding(.trailing, 4)
        .frame(maxHeight: .infinity)
        .coordinateSpace(name: "navRow")
        .background(GeometryReader { g in
            Color.clear.preference(key: NavRowWidthKey.self, value: g.size.width)
        })
    }

    /// The content panel island: frosted glass, ambient album glow, the tab.
    private func contentIsland(size: CGSize) -> some View {
        ZStack(alignment: .top) {
            // The frosted/glass ground is painted by `expandedPanelLayer`, which
            // owns the panel's shape; everything here composites on top of it.
            // Ambient glow: the album cover, blown up and heavily blurred,
            // tints the panel with the artwork's palette on every tab.
            // While music plays it breathes with the song's loudness. The
            // glow-intensity choice (Subtle/Normal/Vivid) applies on the
            // Media tab only; every other tab is pinned to Subtle so the
            // artwork never upstages the page being read.
            if let art = media.artwork, settings.ambientGlow {
                AmbientGlow(art: art, size: size,
                            intensity: state.currentTab == .media
                                ? settings.glowIntensity : 0.6)
                    // Tab switches crossfade the intensity change — no pop when
                    // entering/leaving Media.
                    .animation(.easeInOut(duration: 0.35), value: state.currentTab)
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

    /// Adaptive tab-chip metrics — the SINGLE source of truth for inter-chip
    /// spacing and unselected-chip horizontal padding, keyed off how many tabs are
    /// actually visible. The nav capsule is sized by `navWidthProbe` from the
    /// CURRENT visible set (never the 11-tab worst case), so a trimmed-down bar has
    /// real slack under the 444pt ceiling (= panel 460 − 16). We spend that slack
    /// on visibly more breathing room: gap 3 / pad 6 for 10-or-fewer tabs. Only the
    /// FULL 11-tab set has to fall back to the compact gap 2 / pad 5, because at
    /// gap 3 / pad 6 the full row overflows 444 and would clip the end controls
    /// (measured: 11 @ 3/6 ≈ 461pt vs 431pt @ 2/5; 10 @ 3/6 fits with headroom).
    /// Both `tabBar` (live + probe) and `slotCenterX` (drag-reorder math) read
    /// these, so the geometry never desyncs between what's drawn and what's dragged.
    private var chipGap: CGFloat { state.visibleTabs.count >= 11 ? 2 : 3 }
    private var chipPadUnselected: CGFloat { state.visibleTabs.count >= 11 ? 5 : 6 }

    /// `selectedOverride`/`measuring` drive the off-screen width probe: it lays
    /// the bar out as if `selectedOverride` were the current tab, without feeding
    /// the reorder-width plumbing.
    private func tabBar(selectedOverride: NotchTab? = nil,
                        measuring: Bool = false) -> some View {
        let tabs = measuring ? state.visibleTabs : displayTabs
        return HStack(spacing: chipGap) {
            ForEach(tabs, id: \.self) { tab in
                tabChip(tab, selectedOverride: selectedOverride, emitWidth: !measuring)
            }
        }
        // Prototype: the bead's morph container. Off on the measuring path — the
        // probe lays the row out once per tab, so its off-screen copies would all
        // claim the same glassEffectID and fight the live one for it.
        // The chip row's own coordinate space, so each glyph can report where it
        // sits and the bead layer below can be positioned in the same frame.
        .coordinateSpace(name: "chiprow")
        // The bead rides BEHIND the chips: `.background` here is inside the pill
        // (applied further out), so the stack is pill → bead → chips, and the glyph
        // stays crisp on top of the glass.
        .background(alignment: .leading) {
            if pageBead, !measuring, #available(macOS 26.0, *) {
                BeadLayer(selected: selectedOverride ?? state.currentTab,
                          centers: tabIconCenters)
            }
        }
        .padding(2)
        // LOCKED WIDTH — the fix for the bar reshuffling on every page switch.
        // Held to the widest pill the visible set can produce, leading-aligned,
        // so the chips pack from a fixed left edge and the pill's own edges never
        // move. Everything after the pill in the row (pin/gear/power) is packed
        // positionally behind it, so freezing the pill freezes the trio too — no
        // Spacer needed, and the trio's optical-centering tuning below survives
        // byte-for-byte.
        //
        // Placement is load-bearing, and this is the ONLY spot all three of these
        // hold at once:
        //  • BEFORE `.background(Capsule…)`, so the pill capsule sizes to the
        //    locked width instead of hugging the live chips (put it after and
        //    the pill still breathes while only the trio holds still).
        //  • BEFORE `.coordinateSpace(name: "tabbar")`, so that space's origin is
        //    the locked frame's leading edge — which the .leading alignment makes
        //    identical to the chip HStack's own. `slotCenterX` and `reorder` both
        //    seed at x = 2 (the .padding(2) above) and walk the chips in order,
        //    so drag-reorder keeps working untouched.
        //  • NOT on the measuring path, or the probe would measure a row already
        //    locked to `tabBarWidth` — a self-feeding fixed point that latches at
        //    0 and never discovers the true widest set.
        .frame(width: (measuring || tabBarWidth <= 0) ? nil : tabBarWidth,
               alignment: .leading)
        // Report the natural pill width from the probe's copies ONLY (same
        // reasoning as `emitWidth` above): max-reduced across one layout per
        // visible tab, that is the width the live pill locks to.
        .background(GeometryReader { g in
            Color.clear.preference(key: NavTabBarWidthKey.self,
                                   value: measuring ? g.size.width : 0)
        })
        // The pages section reads as its own longer pill, distinct from the
        // trailing pin/gear/power. The capsule is drawn WIDER than the chips via
        // negative padding — a purely visual extent that does NOT enlarge the
        // measured row, so it spends the slack already sitting inside the nav pill
        // instead of pushing the row back over the width ceiling (which is what
        // clipped the end controls before).
        .background(
            Capsule().fill(.white.opacity(0.06))
                .padding(.horizontal, -6)
        )
        .coordinateSpace(name: "tabbar")
        .onPreferenceChange(TabChipWidthKey.self) { if !measuring { chipWidths = $0 } }
        // CRITICALLY DAMPED (0.34/1.0), not the old 0.30/0.8. ONE curve drives
        // everything the switch touches — chip width, chip position, label color,
        // the selection capsule's fill, and (through the capsule's clip) the
        // title's reveal. At 0.8 a dozen chips overshot and swung back at once,
        // the single biggest contributor to the switch reading as unsettled; at
        // 1.0 the reflow arrives and stops.
        //
        // 0.34 rather than the original 0.30: with the bounce gone there is no
        // wobble to outrun, and the extra 40ms is what lets the capsule visibly
        // open BEFORE the label finishes condensing into it instead of the two
        // happening at once. Shortening it instead (0.24 was tried) snapped the
        // pill open faster than the label could resolve and made the pop worse.
        .animation(measuring ? nil : .spring(response: 0.34, dampingFraction: 1.0), value: state.currentTab)
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
                // Prototype: the glass bead rides the SELECTED page's glyph.
                // `emitWidth` is the live path (the probe passes it false), the
                // same signal the reorder plumbing keys off.
                // Report this glyph's centre in the chip row's own space, so the
                // travelling bead can land exactly on it. Live path only — the
                // probe's off-screen rows would report their own coordinates.
                .background(GeometryReader { g in
                    Color.clear.preference(
                        key: TabIconCenterKey.self,
                        value: emitWidth
                            ? [tab: g.frame(in: .named("chiprow")).midX] : [:])
                })
            if selected {
                Text(tab.title)
                    .font(.system(size: 11, weight: .semibold))
                    .fixedSize()
                    // Report the natural title width from the PROBE only (it lays
                    // the row out once per page, so max-reducing across its copies
                    // is the widest title) — then the live chip reserves that.
                    .background(GeometryReader { g in
                        Color.clear.preference(key: NavTitleWidthKey.self,
                                               value: emitWidth ? 0 : g.size.width)
                    })
                    // Centred, not leading: the slack is split around a short title
                    // so the chip stays optically balanced. Leading-aligned would
                    // just move the lopsided gap from the pill into the chip.
                    .frame(width: (emitWidth && titleSlot > 0) ? titleSlot : nil)
                    .transition(.modifier(active: TitleReveal(shown: false),
                                          identity: TitleReveal(shown: true)))
            }
        }
        // Prototype diagnostic: the bead is LIGHT glass, so a white glyph on it is
        // white-on-light and vanishes. If a dark glyph reads, the bead is correctly
        // behind the icon and this is purely a contrast problem; if it still
        // vanishes, the glass is compositing OVER the icon and the whole
        // bead-behind arrangement is unusable.
        .foregroundStyle(selected ? .white
                         : .white.opacity(targeted ? 0.9 : 0.45))
        // Adaptive horizontal padding (see `chipPadUnselected`): with a full tab set
        // (11 visible) an untrimmed control row once measured ~501pt against a 444pt
        // ceiling (= panel width 460 − 16), so the end controls (leading tab +
        // trailing power) were clipped. At 11 tabs we stay compact (pad 5, gap 2 →
        // ~431pt) — the tightest the full set can be without scaling the row (which
        // would desync the liquid melt-dot centers) or widening the pill past the
        // island. But the capsule is sized from the CURRENT visible set, so a
        // trimmed bar (≤10 tabs) has slack under 444: there we spread out to pad 6 /
        // gap 3 for visibly more breathing room. Selected chips keep their fixed 8
        // (the title already gives them width); only the icon-only unselected chips
        // step. Do NOT push the unselected pad past 6 while 11 tabs can still use it
        // — at 3/6 the full 11-set already overflows 444 (~461pt), hence the compact
        // fallback keyed on the count.
        .padding(.horizontal, selected ? 8 : chipPadUnselected)
        .frame(height: 24)
        .background(
            Capsule().fill(.white.opacity(
                isDragging ? 0.3 : (selected ? 0.16 : (targeted ? 0.09 : 0))))
        )
        // The capsule IS the title's reveal. The chip's width springs open, and
        // clipping the content to that animating capsule wipes the label into view
        // from behind its edge — which is why the label needs no sideways animation
        // of its own, and why it can no longer overhang.
        //
        // Filmed at 10× before this: the label was laid out at full size the moment
        // it was inserted and stayed razor-sharp OUTSIDE the capsule for the whole
        // spring, then dissolved at the very end. That mismatch — finished text
        // sitting past an edge that is still travelling — is what read as a fast
        // sideways pop. Clipping ties the two together for free, with no measured
        // title width and no second animation to keep in sync.
        .clipShape(Capsule())
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
    /// widths (2 pt leading pad from `.padding(2)` + the adaptive `chipGap` between
    /// chips) — stable during the reflow animation, unlike live frame reads. Reads
    /// the SAME `chipGap` the HStack lays out with, so drag targets stay exact under
    /// both the compact (11-tab) and spread (≤10-tab) spacing.
    private func slotCenterX(of tab: NotchTab, in order: [NotchTab]) -> CGFloat {
        var x: CGFloat = 2
        for t in order {
            let w = chipWidths[t] ?? 30
            if t == tab { return x + w / 2 }
            x += w + chipGap
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
            cx += w + chipGap
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

/// The album-artwork glow behind the panel, in its OWN view.
///
/// This used to live inline in `NotchView.contentIsland`, with its rotation
/// phase as `@State` on NotchView and its loudness read from the root's
/// `@EnvironmentObject var spectrum`. Both are 17 Hz signals — the audio tap
/// publishes every 0.06 s — so each sample invalidated the ENTIRE root body:
/// the island, all four Liquid morph relays, the ten-copy nav width probe, and
/// the current tab's whole view, which stays mounted while collapsed. That ran
/// continuously whenever music played with the media ear showing, which is the
/// app's normal idle state.
///
/// Observation in SwiftUI is per-OBJECT, not per-property, so throttling the
/// samples would not have helped while the root still observed the spectrum.
/// The phase and the observation both had to move down here, where invalidation
/// costs one blurred image pair instead of the whole tree.
private struct AmbientGlow: View {
    let art: NSImage
    let size: CGSize
    let intensity: Double

    @EnvironmentObject private var spectrum: AudioSpectrum
    @EnvironmentObject private var media: MediaWatcher
    @State private var colorPhase: Double = 0

    /// Music loudness (0…1), averaged over the newest few samples so the glow
    /// breathes rather than strobes. Zero while paused — the tap is off, so the
    /// background settles to its base.
    private var pulse: CGFloat {
        let recent = spectrum.levels.suffix(3)
        guard media.nowPlaying?.isPlaying == true, !recent.isEmpty else { return 0 }
        return CGFloat(recent.reduce(0, +)) / CGFloat(recent.count)
    }

    /// One oversized square copy of the artwork — square and larger than the
    /// panel's diagonal, so rotation never shows a corner.
    private func layer() -> some View {
        Image(nsImage: art)
            .resizable()
            .aspectRatio(contentMode: .fill)
            .frame(width: size.width, height: size.width)
    }

    var body: some View {
        let p = pulse
        ZStack {
            layer()
                .scaleEffect(1.6 + 0.25 * p)
                .rotationEffect(.degrees(colorPhase))
            layer()
                .scaleEffect(1.95 + 0.3 * p)
                .rotationEffect(.degrees(140 - colorPhase * 1.6))
                .offset(x: 30 * cos(colorPhase / 40),
                        y: 18 * sin(colorPhase / 47))
                .opacity(0.6)
        }
        .blur(radius: 46)
        .saturation(1.5 + 0.5 * p)
        .opacity((0.32 + 0.2 * p) * intensity)
        .frame(width: size.width, height: size.height)
        .allowsHitTesting(false)
        .animation(.linear(duration: 0.14), value: colorPhase)
        .animation(.easeOut(duration: 0.16), value: p)
        // Each fresh audio sample nudges the colors along; loudness sets the
        // pace, and no samples (paused) means no motion.
        .onChange(of: spectrum.levels) { levels in
            guard !levels.isEmpty else { return }
            colorPhase += 0.5 + 2.0 * Double(p)
        }
    }
}

/// `EqualizerBars` wired to the live audio tap, observing the spectrum ITSELF.
///
/// Call sites used to read `spectrum.levels` inline, which forced whatever view
/// contained them to observe the tap and re-render at 17 Hz. Pulling the
/// observation down to this leaf keeps the invalidation to four bars.
struct LiveEqualizer: View {
    var barCount: Int
    var maxHeight: CGFloat
    var color: Color

    @EnvironmentObject private var spectrum: AudioSpectrum

    var body: some View {
        // A dead tap must not animate: the synthetic sine is indistinguishable
        // from a live waveform, so a denied permission would look like it works.
        EqualizerBars(barCount: barCount, maxHeight: maxHeight, color: color,
                      animating: spectrum.failure == nil,
                      levels: spectrum.levels.isEmpty ? nil : spectrum.levels)
    }
}
