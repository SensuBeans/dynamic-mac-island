import AppKit
import Combine
import SwiftUI
import IOKit.ps
import SwiftTerm

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NotchPanel!
    private var host: PassThroughHostingView!
    private var metrics: NotchMetrics!

    private let state = NotchState()
    private let media = MediaWatcher()
    private let tray = FilesTray()
    private let spectrum = AudioSpectrum()
    private let lyrics = LyricsModel()
    private let calendarModel = CalendarModel()
    private let mirror = MirrorController()
    private let earReveal = EarRevealModel()
    private let toggles = TogglesModel()
    private let stats = StatsModel()
    private let pomodoro = PomodoroModel()
    private let audioOutput = AudioOutputModel()
    private let settings = SettingsStore()
    private let agentSessions = AgentSessionsModel()
    private let serversModel = ServersModel()
    private let notesSync = NotesSyncModel()

    private var keyMonitor: Any?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    /// Collapse hit-test rect, held at the recent MAX through a shrink's spring
    /// settle. islandRect() returns the ENDPOINT size at once, but the panel
    /// animates to it over ~0.3 s, so on a SHRINK (a row removed, a session ends,
    /// Mirror stops) the rect snaps small while the panel is still rendered large
    /// — a cursor resting in the still-visible lower band then falls outside and
    /// collapse() fires under it. Grows are adopted immediately (cursor already
    /// inside); shrinks hold the larger rect for islandShrinkSettle. See S4.
    private var heldCollapseRect: NSRect = .zero
    private var heldCollapseUntil: Date = .distantPast
    private let islandShrinkSettle: TimeInterval = 0.4
    private var expandWork: DispatchWorkItem?
    private var hoverPoll: Timer?
    private var spacePoll: Timer?
    private var batteryTimer: Timer?
    private var lastBattery: (charging: Bool, low: Bool)?
    private var spaceWork: DispatchWorkItem?
    private var lastWallpaper = ""

    private func currentWallpaperID() -> String {
        guard let info = CGWindowListCopyWindowInfo([.optionOnScreenOnly],
                                                    kCGNullWindowID) as? [[String: Any]]
        else { return "?" }
        for w in info where (w[kCGWindowOwnerName as String] as? String) == "Dock" {
            if let name = w[kCGWindowName as String] as? String, name.hasPrefix("Wallpaper") {
                return name
            }
        }
        return "?"
    }

    // MARK: Fullscreen detection (hide collapsed adornments over fullscreen)

    /// True while a fullscreen Space is frontmost on the notch panel's own screen.
    /// No permissions needed. See opus-fullscreen-hide.md ("Detector v2").
    ///
    /// Detector v1 (match a layer-0 window to the full screen frame) CANNOT WORK on
    /// a notched Mac: Chrome/YouTube fullscreen bounds are (0,33 W×visibleH) — the
    /// content stops BELOW the notch strip — which is byte-identical to a *maximized*
    /// (non-fullscreen) window over visibleFrame. Layer-0 geometry is fundamentally
    /// ambiguous, so tolerance tweaks are futile (ground-truthed on this machine).
    ///
    /// The reliable signal: while a fullscreen Space is frontmost, the Dock owns an
    /// on-screen "Fullscreen Backdrop" window (deep-negative layer) whose bounds equal
    /// the FULL screen frame. It's absent on the desktop. Backdrops from OTHER spaces
    /// appear mid-Space-slide at offset x — the bounds==THIS-screen's-frame gate drops
    /// those. The old layer-0 exact-full-frame match is kept as a cheap secondary OR
    /// for apps that truly cover the notch.
    ///
    /// v3 (name-free): `kCGWindowName` is NOT readable from this app process (no
    /// Screen-Recording permission), so the v2 `name == "Fullscreen Backdrop"` test
    /// never matched in-app. Layers ARE always readable. On the DESKTOP the Dock owns
    /// exactly ONE deep-negative-layer window covering the screen (the wallpaper,
    /// layer -2147483624); on a FULLSCREEN Space it owns TWO (wallpaper + the
    /// backdrop at -2147483622). So: count Dock windows covering this screen's full
    /// frame in the deep-negative band; ≥2 ⇒ fullscreen. The name test is kept only
    /// as a fast path for the day the app ever gains the permission.
    ///
    /// `(signal, deepCount)` — the signal (if any) says the notch screen is showing a
    /// fullscreen Space: `"backdrop"`, `"layer0"`, or nil. deepCount (Dock deep-layer
    /// is surfaced so fsLog can print it and make the next live test self-diagnosing.
    private func detect() -> (String?, Int) {
        guard let screen = panel?.screen ?? NSScreen.main else { return (nil, 0) }
        // CGWindow bounds are global TOP-LEFT origin; NSScreen.frame is global
        // BOTTOM-LEFT. Flip about the PRIMARY display's height (origin 0,0) — the
        // classic multi-display coordinate bug lives here.
        let primaryH = (NSScreen.screens.first { $0.frame.origin == .zero }
                        ?? NSScreen.screens.first)?.frame.height ?? screen.frame.height
        let f = screen.frame
        let want = CGRect(x: f.origin.x, y: primaryH - f.maxY,
                          width: f.width, height: f.height)
        let mine = ProcessInfo.processInfo.processIdentifier
        // The backdrop lives among desktop elements, so DON'T exclude them (v1's mask
        // filtered out the very signal we need).
        guard let info = CGWindowListCopyWindowInfo(
            [.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]]
        else { return (nil, 0) }
        let tol: CGFloat = 2
        func coversScreen(_ w: [String: Any]) -> Bool {
            guard let bDict = w[kCGWindowBounds as String] as? NSDictionary,
                  let b = CGRect(dictionaryRepresentation: bDict) else { return false }
            return abs(b.minX - want.minX) <= tol && abs(b.minY - want.minY) <= tol
                && abs(b.width - want.width) <= tol && abs(b.height - want.height) <= tol
        }
        // Primary: Dock-owned deep-negative-layer windows covering THIS screen's full
        // frame. The deep band (< -1,000,000) excludes normal Dock UI (layers 18/20/25
        // in the probe). Desktop = 1 (wallpaper); fullscreen = 2 (wallpaper + backdrop).
        var deep = 0
        var namedBackdrop = false
        for w in info where (w[kCGWindowOwnerName as String] as? String) == "Dock" {
            guard let layer = w[kCGWindowLayer as String] as? Int, layer < -1_000_000,
                  coversScreen(w) else { continue }
            deep += 1
            if (w[kCGWindowName as String] as? String) == "Fullscreen Backdrop" {
                namedBackdrop = true   // fast path if the app ever gains the permission
            }
        }
        if namedBackdrop || deep >= 2 { return ("backdrop", deep) }
        // Secondary: a foreign layer-0 window that truly covers the WHOLE frame
        // (notch strip included). Deliberately NOT a visibleFrame-shaped match —
        // that would false-positive on maximized windows (per the ground truth).
        for w in info {
            guard (w[kCGWindowLayer as String] as? Int) == 0 else { continue }
            if let pid = w[kCGWindowOwnerPID as String] as? pid_t, pid_t(mine) == pid { continue }
            if coversScreen(w) { return ("layer0", deep) }
        }
        return (nil, deep)
    }

    /// Re-run the detector and publish to `state.frontmostIsFullscreen` ONLY on an
    /// actual value change (no re-render churn every poll tick). `-FullscreenHideForce`
    /// pins it true so hiding can be eyeballed without entering fullscreen.
    private func refreshFullscreenState(_ reason: String) {
        let forced = UserDefaults.standard.bool(forKey: "FullscreenHideForce")
        // The window sweep runs every tick (it must — the signal changes with the
        // frontmost Space). Force short-circuits it; otherwise detect() decides.
        let (rawSignal, deep) = forced ? ("force", 0) : detect()
        let signal = forced ? "force" : rawSignal
        let detected = signal != nil
        fsLog("decide=\(detected) signal=\(signal ?? "none") deep=\(deep) forced=\(forced) reason=\(reason) published=\(state.frontmostIsFullscreen)")
        guard state.frontmostIsFullscreen != detected else { return }
        state.frontmostIsFullscreen = detected
        fsLog("PUBLISH frontmostIsFullscreen -> \(detected)")
    }

    /// `-FullscreenHideDebug`: append one line per detector decision to a readable
    /// file (macOS 26 redacts NSLog args in the unified log, so file logging only).
    private func fsLog(_ msg: String) {
        guard UserDefaults.standard.bool(forKey: "FullscreenHideDebug") else { return }
        let line = "\(Self.fsLogStamp.string(from: Date())) \(msg)\n"
        let url = URL(fileURLWithPath: "/tmp/notch-fullscreen.log")
        guard let data = line.data(using: .utf8) else { return }
        if let fh = try? FileHandle(forWritingTo: url) {
            defer { try? fh.close() }
            _ = try? fh.seekToEnd()
            try? fh.write(contentsOf: data)
        } else {
            try? data.write(to: url, options: .atomic)
        }
    }
    private static let fsLogStamp: DateFormatter = {
        let f = DateFormatter()
        f.dateFormat = "HH:mm:ss.SSS"
        return f
    }()
    /// Block-observer tokens auto-unregister on dealloc — must be retained.
    private var observerTokens: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()

    /// Thread-safe snapshot of the island's built-in Terminal-tab shells,
    /// `(sessionID, shellPid)`. `TerminalSessionsModel.sessions` is main-only, but
    /// `AgentSessionsModel` reads this on its own `ioQueue` to recognize a Claude
    /// session hosted inside the island — so the snapshot is updated on main and
    /// read under a lock.

    /// Thread-safe mirror of the auto-resume toggle — `AgentSessionsModel` reads
    /// it on `ioQueue`, the setting is written on main.
    private let autoResumeLock = NSLock()
    private var autoResumeSnapshot = true

    /// Drives the `-LiquidNavDebug` auto-loop (nav show→hide) for goo tuning.
    private var liquidNavDebugTimer: Timer?
    /// Drives the `-LiquidIslandDebug` auto-loop (ear show/hide + panel close/open,
    /// alternating) for tuning the two island morphs.
    private var liquidIslandDebugTimer: Timer?
    /// Drives the `-LiquidAgentDebug` auto-loop (agent pill show/hide) for tuning
    /// the LiquidAgent bud-and-pinch with a synthetic injected pill.
    private var liquidAgentDebugTimer: Timer?

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
        // `-ResumeReportProbe <path>` runs the verdict pipeline and quits. Ahead
        // of the notch-screen guard and of any window, so it works headless.
        if let i = CommandLine.arguments.firstIndex(of: "-ResumeReportProbe"),
           i + 1 < CommandLine.arguments.count {
            agentSessions.runReportProbe(writingTo: CommandLine.arguments[i + 1])
            DispatchQueue.main.asyncAfter(deadline: .now() + 20) { NSApp.terminate(nil) }
            return
        }
        // `-IdentityProbe <pid>[,<pid>…]` prints what each pid's terminal resolves
        // to and quits. Host resolution decides whether a row gets Approve, Open
        // and auto-resume at all, and it cannot be read off the screen — a row
        // looks identical for a correct `.other` and a wrong one.
        if let i = CommandLine.arguments.firstIndex(of: "-IdentityProbe"),
           i + 1 < CommandLine.arguments.count {
            for raw in CommandLine.arguments[i + 1].split(separator: ",") {
                guard let pid = Int32(raw) else { continue }
                let id = TerminalIdentity.resolve(pid: pid)
                print("pid=\(pid) tty=\(id.tty ?? "-") host=\(id.host) isDeck=\(id.host.isDeck)")
            }
            NSApp.terminate(nil)
            return
        }
        guard let screen = NotchMetrics.notchScreen() else { return }
        metrics = NotchMetrics(screen: screen)
        state.onQuit = { NSApp.terminate(nil) }
        // The ear's single-owner reducer watches the media pipeline from launch.
        earReveal.bind(to: media)
        state.onExpandRequest = { [weak self] in self?.expand() }
        state.onHoverChange = { [weak self] inside in self?.hoverIsland(inside) }
        // Songs/Albums jumps need Accessibility. Once the one-time system
        // prompt has fired, further clicks while untrusted show a toast and
        // open the Privacy pane instead of stacking dialogs.
        media.onNeedsAccessibility = { [weak self] in
            self?.state.showToast(NotchToast(icon: "hand.raised",
                                             title: "Accessibility needed",
                                             subtitle: "System Settings › Privacy"))
            if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
                NSWorkspace.shared.open(url)
            }
        }

        // One fixed window — the island animates inside it, so open/close and
        // the media ear can never cause a positional snap. Clicks in the
        // window's transparent areas fall through to whatever is beneath.
        panel = NotchPanel(contentRect: metrics.windowFrame)
        host = PassThroughHostingView(rootView: makeRoot())
        // The island rect in the host's own coordinate space. NSHostingView is
        // flipped (origin top-left), so the island — glued to the screen's top
        // edge — starts at y = 0; handle both orientations to be safe.
        host.islandRect = { [weak self] in
            guard let self else { return .zero }
            var s: CGSize
            let x: CGFloat
            if self.state.isExpanded {
                let onMirror = self.state.currentTab == .mirror
                // LOCKSTEP with NotchView.expandedSize — every branch below
                // must mirror it exactly (settings footprint, hug-sized tabs,
                // mirror's opt-in placeholder) or the hover rect drifts from
                // the rendered island and it collapses under the cursor.
                if self.state.showingSettings {
                    s = NotchMetrics.agentsIslandSize
                } else if self.state.currentTab == .tray {
                    s = self.metrics.trayExpandedSize(itemCount: self.tray.items.count,
                                                      cell: self.settings.trayTileSize)
                } else if self.state.currentTab == .agents {
                    s = NotchView.hugSize(cap: NotchMetrics.agentsIslandSize,
                                          natural: self.state.tabHugHeight)
                } else if self.state.currentTab == .servers {
                    s = NotchView.hugSize(cap: NotchMetrics.serversIslandSize,
                                          natural: self.state.tabHugHeight)
                } else if self.state.currentTab == .calendar {
                    s = self.metrics.calendarExpandedSize(monthMode: self.state.calendarMonthMode)
                } else {
                    let mirrorLive = onMirror && self.mirror.wantsRunning
                    s = self.metrics.expandedSize(zoomed: mirrorLive,
                                                  large: mirrorLive && self.state.mirrorBig)
                }
                // Center on the ACTUAL island width so hover hit-testing tracks
                // the rendered island (terminal is wider than the standard
                // panel) — must match the .padding(.leading) in NotchView.
                x = self.metrics.expandedLeadingPad(width: s.width)
                // The panel floats below the notch — the interactive rect
                // bridges notch, gap, and panel so crossing the gap doesn't
                // read as leaving the island. (notch→nav gap + nav bar +
                // nav→content gap.)
                s.height += self.metrics.notchHeight + NotchMetrics.islandGap
                    + NotchMetrics.navIslandHeight + NotchMetrics.navContentGap
            } else {
                // LOCKSTEP: the collapsed bar renders off the SETTLED reveal
                // signal (EarRevealModel), so the hover rect must too.
                s = self.metrics.collapsedSize(withMedia: self.earReveal.earVisible || (self.pomodoro.isRunning && self.settings.timerCountdownEar),
                                               toast: self.state.toast != nil,
                                               withAgent: self.agentSessions.hasActivePill)
                x = self.metrics.islandLeadingPad(expanded: false)
            }
            let y = self.host.isFlipped ? 0 : self.host.bounds.height - s.height
            return NSRect(x: x, y: y, width: s.width, height: s.height)
        }
        host.onMouseState = { [weak self] inside in self?.hoverIsland(inside) }
        // Pin = parkable island: the panel window becomes user-movable (the
        // WindowDragGesture in NotchView needs it) and stays wherever it is
        // dropped. Unpinning — including the collapse path, which always
        // unpins — snaps the window back to its exact notch-home frame, so
        // the one-fixed-window geometry holds whenever the island is docked.
        state.$pinned
            .removeDuplicates()
            .sink { [weak self] pinned in
                guard let self else { return }
                self.panel.isMovable = pinned
                if !pinned, let m = self.metrics {
                    self.panel.setFrame(m.windowFrame, display: true)
                    self.state.parked = false
                }
            }
            .store(in: &cancellables)
        // Parked = pinned + genuinely away from home. Window moves flip it;
        // the unpin snap-home above clears it. 2pt tolerance so AppKit frame
        // rounding can't strand a docked island in parked layout.
        observerTokens.append(NotificationCenter.default.addObserver(
            forName: NSWindow.didMoveNotification, object: panel, queue: .main
        ) { [weak self] _ in
            guard let self, let m = self.metrics else { return }
            let d = hypot(self.panel.frame.origin.x - m.windowFrame.origin.x,
                          self.panel.frame.origin.y - m.windowFrame.origin.y)
            let parked = self.state.pinned && d > 2
            if self.state.parked != parked { self.state.parked = parked }
        })
        host.onEarHover = { [weak self] over in self?.setEarHover(over) }
        // With hover-to-expand off, a click in the notch opens the panel.
        host.onZoneClick = { [weak self] in
            guard let self, !self.settings.hoverToExpand, !self.state.isExpanded else { return }
            self.expand()
        }
        panel.onScroll = { [weak self] event in self?.handleIslandSwipe(event) }
        // The expand trigger hugs the physical notch exactly; the ear and
        // wings never open the panel.
        host.hoverZoneRect = { [weak self] in
            guard let self else { return .zero }
            if self.state.isExpanded { return self.host.islandRect() }
            let b = self.host.bounds
            let s = self.metrics.hoverZoneSize
            let y = self.host.isFlipped ? 0 : b.height - s.height
            return NSRect(x: (b.width - s.width) / 2, y: y,
                          width: s.width, height: s.height)
        }
        host.earBoundaryX = { [weak self] in
            guard let self else { return .infinity }
            return self.host.islandRect().minX + self.metrics.notchWidth
        }
        host.frame = NSRect(origin: .zero, size: metrics.windowFrame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.orderFrontRegardless()

        // Liquid-nav tuning harness (`-LiquidNavDebug 1`): force the panel open
        // and auto-loop the nav show/hide so the goo morph (slowed 8× in
        // NotchView) can be screenshotted frame-by-frame. No-op otherwise.
        startLiquidNavDebugIfNeeded()

        // Liquid-island tuning harness (`-LiquidIslandDebug 1`): auto-loop the
        // ear reveal + panel close/open (slowed 6× in NotchView). No-op otherwise.
        startLiquidIslandDebugIfNeeded()

        // Liquid agent-pill tuning harness (`-LiquidAgentDebug 1`): auto-loop the
        // pill show/hide with a synthetic pill (slowed 6× in NotchView). No-op
        // otherwise; `-LiquidAgentFreeze <e>` holds it collapsed for stills.
        startLiquidAgentDebugIfNeeded()

        // Esc collapses while the panel has focus — except on the Terminal
        // tab, where Esc must reach the shell (vim/less would be unusable
        // otherwise). Collapse there still works via mouse-leave, pin, or
        // clicking away.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53, self.state.isExpanded {
                self.collapse()
                return nil
            }
            return event
        }

        // Nothing re-synced after a sleep. Tabs whose data is event-driven or
        // loaded on a visibility edge showed pre-sleep state after the lid
        // opened — a calendar list containing meetings that already ended, with
        // no timestamp or spinner to say it was old. Stats and Servers already
        // self-heal via setPolling's eager first tick, so they are left alone.
        observerTokens.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.calendarModel.refreshAuthorization()
            self.calendarModel.load()
            self.toggles.refreshAll()
            self.media.refresh()
        })

        observerTokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.rebuildMetrics() })

        // Apple Notes sync surfaces conflicts / permission issues as toasts.
        notesSync.onToast = { [weak self] title, subtitle in
            self?.state.showToast(NotchToast(icon: "note.text", title: title,
                                             subtitle: subtitle))
        }

        setupToasts()

        // Which terminal the Servers page starts servers in (Configurations).
        // Read through the store so flipping the setting takes effect on the very
        // next start, with no restart and no cached copy to go stale.
        serversModel.useDeck = { [weak self] in
            guard let self else { return false }
            return self.settings.terminalHost == "deck" && DeckBridge.isInstalled
        }

        // Auto-resume: settings gate (thread-safe snapshot), the notch-terminal
        // injection route, and the fire toasts — all wired before start() so the
        // initial scan already sees them.
        autoResumeSnapshot = settings.agentsAutoResume
        agentSessions.autoResumeEnabled = { [weak self] in
            guard let self else { return true }
            self.autoResumeLock.lock(); defer { self.autoResumeLock.unlock() }
            return self.autoResumeSnapshot
        }
        settings.$agentsAutoResume
            .sink { [weak self] on in
                guard let self else { return }
                self.autoResumeLock.lock(); self.autoResumeSnapshot = on; self.autoResumeLock.unlock()
            }
            .store(in: &cancellables)
        agentSessions.onResumeFired = { [weak self] project, name, notify in
            guard let self else { return }
            if notify {
                self.state.showToast(NotchToast(
                    icon: "bolt.slash",
                    title: "Limits reset — \(project)",
                    subtitle: name.map { "\($0) is waiting for you" } ?? "waiting for you",
                    color: .orange))
            } else {
                self.state.showToast(NotchToast(
                    icon: "bolt.fill",
                    title: "Resumed — \(project)",
                    subtitle: name,
                    color: .green))
            }
        }
        // Every OTHER auto-resume outcome — the ones that used to reach nothing
        // but a log file. `onResumeFired` above already toasts the two success
        // shapes, so this only toasts what it doesn't; both paths file the
        // verdict in Notification Center, where it waits however long it takes
        // the user to come back to the machine.
        agentSessions.onResumeReport = { [weak self] report in
            guard let self else { return }
            ResumeNotifier.post(report)
            switch report.outcome {
            case .resumed, .notified:
                break   // onResumeFired toasted this one already
            case .failed:
                self.state.showToast(NotchToast(
                    icon: report.glyph,
                    title: "Didn't resume — \(report.project)",
                    subtitle: report.detail,
                    color: .red))
            case .skipped:
                self.state.showToast(NotchToast(
                    icon: report.glyph,
                    title: "No resume needed — \(report.project)",
                    subtitle: report.detail,
                    color: .gray))
            case .armed:
                break   // never settled; the countdown chip is the surface
            }
        }
        ResumeNotifier.prepare()

        // Claude Code agent sessions: watch ~/.claude/projects, toast on
        // Done / Interrupted transitions (suppressed while already viewing
        // the Agents tab, mirroring the track-change toast guard).
        agentSessions.start()
        agentSessions.onTransition = { [weak self] session, _ in
            guard let self else { return }
            guard !(self.state.isExpanded && self.state.currentTab == .agents) else { return }
            // ONLY interrupt for the actionable case — a session waiting on you.
            // "Complete" fires on every finished turn (constant while you work)
            // and would keep replacing the media ear; the collapsed pill already
            // shows the ✓ count non-intrusively, so no toast for it.
            guard session.state == .waiting else { return }
            self.state.showToast(NotchToast(icon: "exclamationmark.triangle.fill",
                                            title: "Needs you — \(session.project)",
                                            subtitle: session.name,
                                            color: .orange))
        }

        pomodoro.onPhaseEnd = { [weak self] ended in
            guard let self else { return }
            if self.settings.timerEndSound != "none" {
                NSSound(named: self.settings.timerEndSound)?.play()
            }
            guard self.settings.timerEndToast else { return }
            self.state.showToast(NotchToast(
                icon: ended == .focus ? "cup.and.saucer.fill" : "brain.head.profile",
                title: ended == .focus ? "Focus done" : "Break over",
                subtitle: ended == .focus ? "Take a break" : "Back to work",
                color: ended == .focus ? .green : .orange), duration: 4)
        }
        // Seed the pomodoro from settings and keep it in sync.
        pomodoro.focusMinutes = settings.focusMinutes
        pomodoro.restMinutes = settings.breakMinutes
        pomodoro.autoStart = settings.timerAutoStart
        settings.$focusMinutes.dropFirst()
            .sink { [weak self] in self?.pomodoro.focusMinutes = $0 }.store(in: &cancellables)
        settings.$breakMinutes.dropFirst()
            .sink { [weak self] in self?.pomodoro.restMinutes = $0 }.store(in: &cancellables)
        settings.$timerAutoStart.dropFirst()
            .sink { [weak self] in self?.pomodoro.autoStart = $0 }.store(in: &cancellables)

        // Hide the island the moment a 4-finger gesture lands — catches
        // Space swipes at their START (wallpaper polling covers the tail).
        TouchSensor.start()
        TouchSensor.onFingerCount = { [weak self] fingers in
            guard let self, !self.state.isExpanded else { return }
            if fingers >= 4 {
                self.spaceWork?.cancel()
                self.state.spaceTransitioning = true
            } else if self.state.spaceTransitioning {
                self.spaceWork?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    self?.state.spaceTransitioning = false
                }
                self.spaceWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.5, execute: work)
            }
        }

        // Vanish during Space switches so swipes between desktops look clean.
        observerTokens.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.activeSpaceDidChangeNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            guard let self else { return }
            self.state.spaceTransitioning = true
            self.spaceWork?.cancel()
            let work = DispatchWorkItem { [weak self] in
                self?.state.spaceTransitioning = false
            }
            self.spaceWork = work
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.8, execute: work)
            // Entering/leaving fullscreen always switches Spaces — re-check now
            // and again after the new Space's windows have settled (the poll is
            // the ultimate safety net if both fire before the switch lands).
            self.refreshFullscreenState("space-change")
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.6) { [weak self] in
                self?.refreshFullscreenState("space-change+0.6")
            }
        })

        // A plain app activation (⌘-Tab into a fullscreen app, etc.) can flip the
        // fullscreen state without a Space change on some paths — re-check on it too.
        observerTokens.append(NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didActivateApplicationNotification,
            object: nil, queue: .main
        ) { [weak self] _ in
            self?.refreshFullscreenState("app-activate")
        })

        // Belt-and-suspenders hover: tracking areas can stop delivering in
        // long-lived accessory panels, so a cheap poll also opens the panel
        // whenever the cursor is on the island. This path cannot break.
        hoverPoll = Timer.scheduledTimer(withTimeInterval: 0.12, repeats: true) { [weak self] _ in
            guard let self, !self.state.isExpanded else { return }
            let zone = self.host.hoverZoneRect?() ?? self.host.islandRect()
            let zoneScreen = self.panel.convertToScreen(self.host.convert(zone, to: nil))
            let islandScreen = self.panel.convertToScreen(
                self.host.convert(self.host.islandRect(), to: nil))
            let mouse = NSEvent.mouseLocation
            if zoneScreen.contains(mouse) {
                // Route through the same dwell debounce as the tracking-area
                // path — a bare expand() here would defeat the phantom-open
                // protection, popping the panel when the cursor merely crosses
                // the fake notch zone on the menu bar (non-notch screens).
                self.hoverIsland(true)
            } else {
                let earX = islandScreen.minX + self.metrics.notchWidth
                self.setEarHover(mouse.x > earX && islandScreen.contains(mouse))
            }
        }
        hoverPoll?.tolerance = 0.02

        // Space-switch detection on a much slower cadence: CGWindowList IPC
        // serializes every on-screen window, so polling it 8×/sec (as the
        // hover poll used to) is a needless drain. Each Space has its own Dock
        // wallpaper window; a change in its ID means the user switched desktops.
        // The window name needs Screen Recording permission — without it the ID
        // reads "?", so skip those ticks entirely (and never seed "?" as the
        // baseline, which would fire one spurious blink when permission lands).
        spacePoll = Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self else { return }
            // Safety-net fullscreen re-check (publishes only on real change).
            self.refreshFullscreenState("poll")
            let wallpaper = self.currentWallpaperID()
            guard wallpaper != "?" else { return }
            if self.lastWallpaper.isEmpty {
                self.lastWallpaper = wallpaper
            } else if wallpaper != self.lastWallpaper {
                self.lastWallpaper = wallpaper
                self.state.spaceTransitioning = true
                self.spaceWork?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    self?.state.spaceTransitioning = false
                }
                self.spaceWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
            }
        }
        spacePoll?.tolerance = 0.1

        // Seed the fullscreen state at launch (honors -FullscreenHideForce for V2).
        refreshFullscreenState("startup")
    }

    private func setupToasts() {
        // Track changes → brief island toast with artwork.
        media.$nowPlaying
            .compactMap { $0 }
            .removeDuplicates { $0.title == $1.title }
            .dropFirst()
            .sink { [weak self] np in
                guard let self, !self.state.isExpanded, self.settings.trackChangeToast else { return }
                self.state.showToast(NotchToast(icon: "music.note", title: np.title,
                                                subtitle: np.artist, useArtwork: true))
            }
            .store(in: &cancellables)

        // Keep the default toast duration in sync with the setting.
        state.defaultToastDuration = settings.toastDuration
        settings.$toastDuration
            .sink { [weak self] in self?.state.defaultToastDuration = $0 }
            .store(in: &cancellables)

        // Media settings that live inside MediaWatcher.
        media.setYouTubeEnabled(settings.youtubeEnabled)
        settings.$youtubeEnabled
            .dropFirst()
            .sink { [weak self] on in self?.media.setYouTubeEnabled(on) }
            .store(in: &cancellables)
        media.pausedEarHideDelay = settings.pausedEarHide
        settings.$pausedEarHide
            .sink { [weak self] v in self?.media.pausedEarHideDelay = v }
            .store(in: &cancellables)

        // Notes loaded tolerantly may hold more pages than the saved count
        // (a non-empty page is never dropped) — reconcile the setting to match,
        // but only when it actually differs so a clean launch writes nothing.
        if settings.notesPageCount != state.pages.count {
            settings.notesPageCount = state.pages.count
        }

        // Calendar query settings.
        calendarModel.lookAheadDays = settings.calendarLookAhead
        calendarModel.includeAllDay = settings.calendarAllDay
        calendarModel.excludedCalendarIDs = Set(settings.calendarExcludedIDs)
        settings.$calendarLookAhead.dropFirst().sink { [weak self] v in
            self?.calendarModel.lookAheadDays = v; self?.calendarModel.load()
        }.store(in: &cancellables)
        settings.$calendarAllDay.dropFirst().sink { [weak self] v in
            self?.calendarModel.includeAllDay = v; self?.calendarModel.load()
        }.store(in: &cancellables)
        settings.$calendarExcludedIDs.dropFirst().sink { [weak self] v in
            self?.calendarModel.excludedCalendarIDs = Set(v); self?.calendarModel.load()
        }.store(in: &cancellables)

        // Mirror camera + flip.
        mirror.preferredCameraID = settings.mirrorCameraID
        mirror.mirrored = settings.mirrorFlip
        settings.$mirrorCameraID.dropFirst()
            .sink { [weak self] in self?.mirror.selectCamera($0) }.store(in: &cancellables)
        settings.$mirrorFlip.dropFirst()
            .sink { [weak self] in self?.mirror.setMirrored($0) }.store(in: &cancellables)

        // Stats refresh rate + hidden tiles.
        stats.refreshInterval = settings.statsRefreshRate
        stats.hiddenTiles = Set(settings.statsHiddenTiles)
        settings.$statsRefreshRate.dropFirst()
            .sink { [weak self] in self?.stats.refreshInterval = $0 }.store(in: &cancellables)
        settings.$statsHiddenTiles.dropFirst()
            .sink { [weak self] in self?.stats.hiddenTiles = Set($0) }.store(in: &cancellables)

        // Controls: screenshot mode.
        toggles.screenshotMode = settings.screenshotMode
        settings.$screenshotMode.dropFirst()
            .sink { [weak self] in self?.toggles.screenshotMode = $0 }.store(in: &cancellables)

        batteryTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.checkBattery()
        }
        batteryTimer?.tolerance = 2

        // Pinned island: switching away from the Mirror tab must stop the
        // camera. mirror.stop() otherwise only runs on collapse(), so a pinned
        // panel would keep the session (and the green recording dot) alive
        // invisibly. Also reset mirrorBig, as its doc comment promises.
        state.$currentTab
            .removeDuplicates()
            .sink { [weak self] tab in
                guard let self, tab != .mirror else { return }
                self.mirror.stop()
                if !self.settings.mirrorRememberBig { self.state.mirrorBig = false }
            }
            .store(in: &cancellables)
    }

    private func checkBattery() {
        guard settings.batteryAlerts else { return }
        guard let blob = IOPSCopyPowerSourcesInfo()?.takeRetainedValue(),
              let list = IOPSCopyPowerSourcesList(blob)?.takeRetainedValue() as? [CFTypeRef],
              let ps = list.first,
              let d = IOPSGetPowerSourceDescription(blob, ps)?.takeUnretainedValue() as? [String: Any],
              let cur = d[kIOPSCurrentCapacityKey] as? Int,
              let max = d[kIOPSMaxCapacityKey] as? Int, max > 0 else { return }
        let charging = (d[kIOPSIsChargingKey] as? Bool) ?? false
        let pct = Int(Double(cur) / Double(max) * 100)
        let low = pct <= 20
        defer { lastBattery = (charging, low) }
        guard let prev = lastBattery else { return }
        if charging != prev.charging {
            state.showToast(NotchToast(icon: charging ? "bolt.fill" : "battery.75",
                                       title: charging ? "Charging" : "On Battery",
                                       subtitle: "\(pct)%",
                                       color: charging ? .green : .white))
        } else if low && !prev.low && !charging {
            state.showToast(NotchToast(icon: "battery.25", title: "Low Battery",
                                       subtitle: "\(pct)%", color: .red))
        }
    }

    private var swipeX: CGFloat = 0
    private var swipeY: CGFloat = 0
    /// True while a swipe that BEGAN over an open settings page is in flight:
    /// the whole gesture then belongs to settings back-navigation (page → root
    /// → closed), never to the tab ratchet underneath the overlay.
    private var settingsSwipe = false
    /// Live volume swipe: the player volume captured (asynchronously) when
    /// the gesture began, offset by the fingers as they move.
    private var volumeBase: Double?
    /// Drops stale async volume reads once a newer gesture has begun.
    private var volumeReadToken = 0
    /// Set when the fingers lift before the base volume read landed — the
    /// completion applies the whole swipe as soon as it arrives.
    private var volumeSwipeEnded = false
    private var lastSentVolume: Int?
    private var lastVolumeSendTime: TimeInterval = 0

    /// Once a swipe over the expanded panel proves horizontal it stays a
    /// tab swipe for the rest of the gesture, so accumulated vertical noise
    /// can't kill the indicator mid-drag.
    private var tabSwipeActive = false
    /// Tab steps already committed live during the current gesture.
    private var tabSteps = 0

    /// Swipe travel (pt) per tab step. The ratchet advances a tab each time
    /// the fingers cover this much; lifting commits at half of it, where the
    /// tab bar previews the target.
    private static let tabSwipeSpan: CGFloat = 100

    private func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern = .alignment) {
        guard settings.haptics else { return }
        NSHapticFeedbackManager.defaultPerformer.perform(pattern, performanceTime: .now)
    }

    /// Two-finger swipes. Collapsed: left/right skips tracks, up/down drives
    /// the player volume live while the fingers move. Expanded: a horizontal
    /// swipe ratchets through the tabs continuously — one step per span of
    /// travel, wrapping at the ends — with the content nudging along.
    private func handleIslandSwipe(_ event: NSEvent) {
        switch event.phase {
        case .began:
            swipeX = 0
            swipeY = 0
            tabSwipeActive = false
            tabSteps = 0
            settingsSwipe = state.isExpanded
                && (state.showingSettings || state.notesBrowsing)
            volumeBase = nil
            volumeSwipeEnded = false
            lastSentVolume = nil
            volumeReadToken += 1
            // Kick off the base volume read now so it has usually landed by
            // the time the fingers actually move.
            if !state.isExpanded, media.nowPlaying != nil, settings.swipeVolume {
                let token = volumeReadToken
                media.readPlayerVolumeAsync { [weak self] v in
                    guard let self, token == self.volumeReadToken else { return }
                    self.volumeBase = v
                    self.updateLiveVolume(final: self.volumeSwipeEnded)
                }
            }
        case .changed:
            swipeX += event.scrollingDeltaX
            swipeY += event.scrollingDeltaY
            if state.isExpanded {
                // Settings owns the gesture: each span of horizontal travel
                // (either direction) steps back one level — sub-page → root →
                // closed — the swipe-out the user asked for.
                if settingsSwipe {
                    if !tabSwipeActive, abs(swipeX) > 8,
                       abs(swipeX) > abs(swipeY) * 1.5 {
                        tabSwipeActive = true
                    }
                    guard tabSwipeActive else { return }
                    let steps = Int((abs(swipeX) / Self.tabSwipeSpan).rounded(.towardZero))
                    if steps != tabSteps {
                        for _ in 0..<max(0, steps - tabSteps) { settingsBack() }
                        tabSteps = steps
                    }
                    return
                }
                if !tabSwipeActive, abs(swipeX) > 8,
                   abs(swipeX) > abs(swipeY) * 1.5 {
                    tabSwipeActive = true
                }
                guard tabSwipeActive else { return }
                // Ratchet: travel is measured in "steps toward the next tab"
                // (leftward swipe = positive); each whole span commits a step
                // live and the residual drives the nudge indicator.
                let travel = -swipeX / Self.tabSwipeSpan
                let steps = Int(travel.rounded(.towardZero))
                if steps != tabSteps {
                    stepTab(by: steps - tabSteps)
                    tabSteps = steps
                }
                state.tabSwipeProgress =
                    max(-1, min(1, CGFloat(tabSteps) - travel))
            } else {
                updateLiveVolume(final: false)
            }
        case .ended:
            if state.isExpanded {
                defer {
                    state.tabSwipeProgress = 0
                    tabSwipeActive = false
                    tabSteps = 0
                    settingsSwipe = false
                }
                if settingsSwipe {
                    // Lifting past half a span commits one more back-step.
                    guard tabSwipeActive else { return }
                    let residual = abs(swipeX) / Self.tabSwipeSpan - CGFloat(tabSteps)
                    if residual > 0.5 { settingsBack() }
                    return
                }
                guard tabSwipeActive else { return }
                // Lifting past half a span commits one more step.
                let residual = -swipeX / Self.tabSwipeSpan - CGFloat(tabSteps)
                if abs(residual) > 0.5 { stepTab(by: residual > 0 ? 1 : -1) }
                return
            }
            guard media.nowPlaying != nil else { return }
            if settings.swipeToSkip, abs(swipeX) > 40, abs(swipeX) > abs(swipeY) {
                let next = swipeX < 0
                next ? media.nextTrack() : media.previousTrack()
                haptic()
                state.showToast(NotchToast(icon: next ? "forward.fill" : "backward.fill",
                                           title: next ? "Next" : "Previous",
                                           color: media.accent), duration: 1.2)
            } else if volumeBase == nil {
                // Fingers lifted before the base read landed (a quick flick)
                // — the pending completion applies the swipe.
                volumeSwipeEnded = true
            } else {
                updateLiveVolume(final: true)
            }
        case .cancelled:
            state.tabSwipeProgress = 0
            tabSwipeActive = false
            tabSteps = 0
            settingsSwipe = false
            volumeReadToken += 1
        default:
            break
        }
    }

    /// An accessory app never gets an app-provided main menu, and AppKit routes
    /// ⌘C/⌘V/⌘X/⌘A/⌘Z through main-menu key equivalents — so with no menu, none
    /// of them reached the first responder and every text surface in the island
    /// (Notes editor, settings fields, the terminal) was un-pasteable.
    ///
    /// This menu is never DISPLAYED (`.accessory` draws no menu bar); it exists
    /// purely as the routing table. Auto-enabling means each item only fires
    /// when the current first responder actually implements its selector, which
    /// is exactly the behavior a key monitor could not reproduce. Deliberately
    /// no ⌘Q item: the island is always-on and quits from its power button.
    private func installMainMenu() {
        let main = NSMenu()
        // Slot 0 is the app menu by convention; left empty so nothing claims a
        // key equivalent there.
        let appItem = NSMenuItem()
        appItem.submenu = NSMenu()
        main.addItem(appItem)

        let edit = NSMenu(title: "Edit")
        edit.addItem(withTitle: "Undo", action: Selector(("undo:")), keyEquivalent: "z")
        let redo = edit.addItem(withTitle: "Redo", action: Selector(("redo:")),
                                keyEquivalent: "z")
        redo.keyEquivalentModifierMask = [.command, .shift]
        edit.addItem(.separator())
        edit.addItem(withTitle: "Cut", action: #selector(NSText.cut(_:)), keyEquivalent: "x")
        edit.addItem(withTitle: "Copy", action: #selector(NSText.copy(_:)), keyEquivalent: "c")
        edit.addItem(withTitle: "Paste", action: #selector(NSText.paste(_:)), keyEquivalent: "v")
        edit.addItem(withTitle: "Select All", action: #selector(NSText.selectAll(_:)),
                     keyEquivalent: "a")
        let editItem = NSMenuItem()
        editItem.submenu = edit
        main.addItem(editItem)

        NSApp.mainMenu = main
    }

    /// One back-step with a haptic tick for whichever overlay owns the gesture:
    /// settings (sub-page → root → closed) or the Notes browser (→ editor).
    /// No-ops once nothing is left to dismiss (a long swipe just exits).
    private func settingsBack() {
        if state.settingsRoute == nil, state.notesBrowsing {
            withAnimation(.easeOut(duration: 0.18)) { state.notesBrowsing = false }
            haptic()
            return
        }
        guard let route = state.settingsRoute else { return }
        state.settingsRoute = route == .root ? nil : .root
        haptic()
    }

    /// Moves the current tab by `delta`, wrapping at the ends, with a
    /// haptic tick per change.
    private func stepTab(by delta: Int) {
        let tabs = state.visibleTabs
        guard delta != 0, let i = tabs.firstIndex(of: state.currentTab) else { return }
        let n = tabs.count
        state.currentTab = tabs[((i + delta) % n + n) % n]
        haptic()
    }

    /// Maps the accumulated vertical swipe onto the player volume. Sends
    /// only whole-percent changes, rate-limited, so a fast swipe can't spawn
    /// an osascript pile-up; a haptic tick marks every 10% detent.
    private func updateLiveVolume(final: Bool) {
        guard settings.swipeVolume, media.nowPlaying != nil, let base = volumeBase,
              abs(swipeY) > 12, abs(swipeY) > abs(swipeX) else { return }
        let whole = Int(min(100, max(0, base - swipeY * settings.volumeSensitivity).rounded()))
        let now = ProcessInfo.processInfo.systemUptime
        if whole != lastSentVolume, final || now - lastVolumeSendTime > 0.05 {
            if let prev = lastSentVolume, prev / 10 != whole / 10 {
                haptic(.levelChange)
            }
            lastSentVolume = whole
            lastVolumeSendTime = now
            media.setPlayerVolume(Double(whole))
        }
        let icon = whole == 0 ? "speaker.slash.fill"
            : whole < 34 ? "speaker.wave.1.fill"
            : whole < 67 ? "speaker.wave.2.fill" : "speaker.wave.3.fill"
        state.showToast(NotchToast(icon: icon, title: "Volume \(whole)%",
                                   color: media.accent), duration: final ? 1 : 3)
    }

    private func setEarHover(_ over: Bool) {
        guard state.earHovered != over else { return }
        state.earHovered = over
    }

    func applicationWillTerminate(_ notification: Notification) {
        state.saveNow()
        // The LOCAL notes store is flushed by saveNow above; Apple Notes edits are
        // debounced 2 s and were not flushed by anything, so quitting inside that
        // window kept the text in the island's cache forever while Notes never
        // received it — a silent, permanent divergence with no indication.
        notesSync.flushPendingEdits()
        toggles.shutdown()
        agentSessions.shutdown()
        if settings.trayClearOnQuit { tray.clear() }
    }

    private func makeRoot() -> AnyView {
        AnyView(NotchView(metrics: metrics, spectrum: spectrum)
            .environmentObject(state)
            .environmentObject(media)
            .environmentObject(tray)
            .environmentObject(calendarModel)
            .environmentObject(mirror)
            .environmentObject(earReveal)
            .environmentObject(toggles)
            .environmentObject(stats)
            .environmentObject(pomodoro)
            .environmentObject(spectrum)
            .environmentObject(lyrics)
            .environmentObject(audioOutput)
            .environmentObject(agentSessions)
            .environmentObject(serversModel)
            .environmentObject(notesSync)
            .environmentObject(settings))
    }

    /// Expand on hover, effectively instantly. SwiftUI can drop hover-exit
    /// events on fast cursor moves, so after one beat we re-verify the cursor
    /// is STILL on the island before opening — instant response for a real
    /// hover, no phantom opens from a cursor that merely passed through.
    private func hoverIsland(_ inside: Bool) {
        expandWork?.cancel()
        // Hover-to-expand off: the panel only opens on a click in the notch
        // (see host.onZoneClick).
        guard settings.hoverToExpand else { return }
        guard inside, !state.isExpanded else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.state.isExpanded else { return }
            let inWindow = self.host.convert(self.host.islandRect(), to: nil)
            let screenRect = self.panel.convertToScreen(inWindow)
            if screenRect.contains(NSEvent.mouseLocation) { self.expand() }
        }
        expandWork = work
        // "Instant" keeps the original 0.05 s debounce (phantom-open guard);
        // longer delays come straight from the setting.
        let dwell = settings.expandDelay > 0 ? settings.expandDelay : 0.05
        DispatchQueue.main.asyncAfter(deadline: .now() + dwell, execute: work)
    }

    private func expand() {
        // Freeze harness for the ear pins the panel COLLAPSED so hover can't
        // open it out from under a deterministic capture.
        if UserDefaults.standard.object(forKey: "LiquidEarFreeze") != nil { return }
        guard !state.isExpanded else { return }
        state.isExpanded = true
        media.refresh()
        notesSync.refresh()  // pull Apple Notes if that mode is on (no-op otherwise)
        // orderFront, NOT makeKeyAndOrderFront: hover-expand must not steal key
        // status from the frontmost app mid-typing. The panel already has
        // `becomesKeyOnlyIfNeeded`, so it becomes key on its own the moment a
        // control that needs the keyboard (the notes editor) is clicked.
        panel.orderFront(nil)
        startMouseWatch()
    }

    private func collapse() {
        // Freeze harness for the close morph pins the panel EXPANDED.
        if UserDefaults.standard.object(forKey: "LiquidCloseFreeze") != nil { return }
        guard state.isExpanded else { return }
        stopMouseWatch()
        // Latch the on-screen panel size BEFORE the mirror reverts (S11): a
        // live/zoomed Mirror shrinks to standard the instant mirror.stop() flips
        // wantsRunning below, which would start the close morph's Surface Return
        // from the standard rect and snap. Only Mirror's size is volatile through
        // a close; every other tab stays put, so .zero (use the live size) there.
        if state.currentTab == .mirror, mirror.wantsRunning {
            state.closePanelSize = metrics.expandedSize(zoomed: true,
                                                        large: state.mirrorBig)
        } else {
            state.closePanelSize = .zero
        }
        state.isExpanded = false
        state.pinned = false
        state.navHovered = false
        if !settings.mirrorRememberBig { state.mirrorBig = false }
        state.settingsRoute = nil
        state.saveNow()
        mirror.stop()
        media.setProgressPolling(false)
    }

    /// `-LiquidNavDebug 1`: a self-driving harness for tuning the Goo Merge
    /// liquid nav. Forces the panel expanded and auto-loops the nav show→hide so
    /// the morph (slowed 8× in NotchView while this flag is on) can be captured
    /// frame-by-frame with `screencapture`. Off by default — never runs unless
    /// the launch arg / user default is set.
    private func startLiquidNavDebugIfNeeded() {
        let defaults = UserDefaults.standard
        // A long, unique ASCII marker so `strings` can PROVE this code shipped in
        // the running binary — the short "LiquidNavDebug" key is ≤15 bytes and
        // Swift inlines it as a small string, invisible to `strings`. Also prints
        // to Console at launch as a live "the new build is running" signal.
        NSLog("SurfaceBulgeLiquidNavHarness_v02_engaged")

        // `-LiquidNavFreeze <e>`: pin the morph at a STATIC reveal value with no
        // animation, so each beat-sheet frame is deterministic. NotchView reads
        // the same key for `renderNavT`; here we just hold the panel open.
        if defaults.object(forKey: "LiquidNavFreeze") != nil {
            state.isExpanded = true
            state.navHovered = true
            return
        }

        guard defaults.bool(forKey: "LiquidNavDebug") else { return }
        var shown = false
        let toggle: () -> Void = { [weak self] in
            guard let self else { return }
            self.state.isExpanded = true      // hold it open; nothing collapses us
            shown.toggle()
            self.state.navHovered = shown     // drives navShown → the navT morph
        }
        // First reveal is DELAYED past view mount: toggling navHovered before
        // NotchView's onChange observers exist is silently missed, and the loop
        // then looks dead for a full period (18 s) — the first cycle never ran.
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { toggle() }
        // Period exceeds the slowed morph (0.85·8 ≈ 6.8 s show / 0.70·8 ≈ 5.6 s
        // hide) plus a settle hold, so each direction finishes before reversing.
        liquidNavDebugTimer = Timer.scheduledTimer(withTimeInterval: 9.0,
                                                   repeats: true) { _ in toggle() }
    }

    /// `-LiquidIslandDebug 1`: a self-driving harness for the two island morphs.
    /// It cycles ear-show → ear-hide → panel-open → panel-close forever (each
    /// slowed 6× in NotchView), forcing the panel/ear state so mouse drift can't
    /// disturb it, so both morphs can be captured frame-by-frame. Off by default.
    private func startLiquidIslandDebugIfNeeded() {
        let defaults = UserDefaults.standard
        // Long ASCII marker so `strings` can PROVE this shipped in the running
        // binary (short keys inline invisibly) + a live Console launch signal.
        NSLog("SurfaceReturnLiquidIslandHarness_v01_engaged")

        // `-LiquidEarFreeze <e>`: hold the panel COLLAPSED so the frozen ear
        // (rendered by NotchView) can be captured deterministically.
        if defaults.object(forKey: "LiquidEarFreeze") != nil {
            state.isExpanded = false
            state.liquidEarDebugForced = true
            return
        }
        // `-LiquidCloseFreeze <e>`: hold the panel EXPANDED (NotchView renders the
        // frozen close value over it).
        if defaults.object(forKey: "LiquidCloseFreeze") != nil {
            state.isExpanded = true
            panel.orderFront(nil)
            return
        }

        guard defaults.bool(forKey: "LiquidIslandDebug") else { return }
        // Four beats, one per timer tick. Each forces exactly the state its morph
        // needs; the mouse-watch is suppressed while this timer lives.
        var beat = 0
        let step: () -> Void = { [weak self] in
            guard let self else { return }
            switch beat % 4 {
            case 0:                                   // ear reveals (collapsed)
                self.state.isExpanded = false
                self.state.liquidEarDebugForced = true
            case 1:                                   // ear hides
                self.state.liquidEarDebugForced = false
            case 2:                                   // panel opens
                self.state.liquidEarDebugForced = false
                self.state.isExpanded = true
                self.panel.orderFront(nil)
            default:                                  // panel closes
                self.state.isExpanded = false
            }
            beat += 1
        }
        // Delay the first beat past view mount (toggling @Published before
        // NotchView's onChange observers exist is silently missed — the nav
        // harness hit this exact bug).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { step() }
        // Period exceeds the slowest slowed morph (0.85·6 ≈ 5.1 s) plus a settle.
        liquidIslandDebugTimer = Timer.scheduledTimer(withTimeInterval: 6.5,
                                                      repeats: true) { _ in step() }
    }

    /// `-LiquidAgentDebug 1`: a self-driving harness for the agent-pill liquid.
    /// It injects a SYNTHETIC collapsed pill (never touching the real agent
    /// sessions) and loops show → hide forever while the island stays collapsed,
    /// so the LiquidAgent bud-and-pinch (slowed 6× in NotchView) can be captured
    /// frame-by-frame. `-LiquidAgentFreeze <e>` instead holds it shown so the
    /// frozen morph value renders deterministically. Off by default.
    private func startLiquidAgentDebugIfNeeded() {
        let defaults = UserDefaults.standard
        // Long ASCII marker so `strings` can PROVE this shipped in the running
        // binary (short keys inline invisibly).
        NSLog("LiquidAgentPillHarness_v01_engaged")

        // Freeze: hold the pill "present" and collapsed; NotchView renders the
        // frozen agentT over it. The synthetic pill must be set so the goo mounts.
        if defaults.object(forKey: "LiquidAgentFreeze") != nil {
            state.isExpanded = false
            state.liquidAgentDebugPill = .working(2)
            return
        }

        guard defaults.bool(forKey: "LiquidAgentDebug") else { return }
        // Two beats: inject the pill (reveal) → clear it (absorb). Cycle a couple
        // of states across reveals so the tinted glyph dot is exercised too.
        let pills: [AgentSessionsModel.CollapsedPill] = [.working(2), .waiting(1), .complete(3)]
        var beat = 0
        let step: () -> Void = { [weak self] in
            guard let self else { return }
            self.state.isExpanded = false
            if beat % 2 == 0 {
                self.state.liquidAgentDebugPill = pills[(beat / 2) % pills.count]
            } else {
                self.state.liquidAgentDebugPill = nil
            }
            beat += 1
        }
        // Delay past view mount (toggling @Published before NotchView's onChange
        // observers exist is silently missed — the nav harness hit this bug).
        DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { step() }
        // Period exceeds the slowed show (0.60·6 ≈ 3.6 s) plus a settle.
        liquidAgentDebugTimer = Timer.scheduledTimer(withTimeInterval: 4.5,
                                                     repeats: true) { _ in step() }
    }

    /// Collapse the moment the cursor leaves the visible island bounds.
    private func startMouseWatch() {
        let check: () -> Void = { [weak self] in
            guard let self, self.state.isExpanded else { return }
            // The debug harness owns nav state while looping — don't let a stray
            // cursor override navHovered or collapse the panel out from under it.
            // Freeze mode (`-LiquidNavFreeze`) likewise holds the panel open.
            if self.liquidNavDebugTimer != nil { return }
            if self.liquidIslandDebugTimer != nil { return }
            if self.liquidAgentDebugTimer != nil { return }
            if UserDefaults.standard.object(forKey: "LiquidNavFreeze") != nil { return }
            // Proper view→window→screen conversion handles the hosting
            // view's flipped coordinate system.
            let inWindow = self.host.convert(self.host.islandRect(), to: nil)
            let target = self.panel.convertToScreen(inWindow).insetBy(dx: -6, dy: -6)
            // Never let the collapse rect trail the rendered panel on a shrink.
            let visible = self.collapseRect(target: target)
            let mouse = NSEvent.mouseLocation
            // The nav dock rides the TOP of the island, but the bar itself is
            // rendered `notchHeight + gap` BELOW the rect's top edge (the rect
            // bridges the notch + gap). So the trigger band must span the notch,
            // the gap, the full nav bar, AND a buffer into the content — else
            // the cursor over the bar's lower half falls outside and it retracts
            // out from under the pointer. Screen coords are bottom-up, so the
            // band hangs off the maxY (top) edge.
            // Bottom-nav mode mirrors the trigger bands to the island's BOTTOM
            // edge (screen coords are bottom-up: bottom = minY).
            let navBottom = self.settings.navAtBottom
            let navZoneHeight = navBottom
                ? NotchMetrics.navContentGap + NotchMetrics.navIslandHeight + 28
                : self.metrics.notchHeight
                    + NotchMetrics.islandGap
                    + NotchMetrics.navIslandHeight + 28
            let stayZone = NSRect(x: visible.minX,
                                  y: navBottom ? visible.minY : visible.maxY - navZoneHeight,
                                  width: visible.width,
                                  height: navZoneHeight)
            // Hysteresis (user-tuned): REVEALING demands the cursor actually
            // reach the island's border strip (top strip normally, bottom strip
            // in bottom-nav mode) — the old single zone fired a good 60pt
            // early, while still over content. Once revealed, the generous zone
            // keeps it out so using the nav buttons never retracts the bar
            // mid-reach.
            let enterH = navBottom
                ? NotchMetrics.navContentGap + NotchMetrics.navIslandHeight + 10
                : self.metrics.notchHeight + NotchMetrics.islandGap + 10
            let enterZone = NSRect(x: visible.minX,
                                   y: navBottom ? visible.minY : visible.maxY - enterH,
                                   width: visible.width,
                                   height: enterH)
            let inNav = self.state.navHovered
                ? stayZone.contains(mouse)
                : enterZone.contains(mouse)
            if self.state.navHovered != inNav { self.state.navHovered = inNav }
            // While the user is actively typing in a terminal (the panel is
            // key and a terminal view holds focus), the cursor drifting off
            // the island must not collapse it out from under a command.
            // Clicking another app resigns key, so normal behavior resumes.
            let typingInTerminal = self.panel.isKeyWindow
                && self.panel.firstResponder is LocalProcessTerminalView
            if !visible.contains(mouse), !self.state.pinned,
               !self.state.menuHoldsOpen, !typingInTerminal {
                self.collapse()
            }
        }
        globalMouseMonitor = NSEvent.addGlobalMonitorForEvents(matching: .mouseMoved) { _ in check() }
        localMouseMonitor = NSEvent.addLocalMonitorForEvents(matching: .mouseMoved) { event in
            check()
            return event
        }
    }

    private func stopMouseWatch() {
        if let globalMouseMonitor { NSEvent.removeMonitor(globalMouseMonitor) }
        if let localMouseMonitor { NSEvent.removeMonitor(localMouseMonitor) }
        globalMouseMonitor = nil
        localMouseMonitor = nil
        // Reset the hold so the next expand starts clean.
        heldCollapseRect = .zero
        heldCollapseUntil = .distantPast
    }

    /// The rect the collapse test uses, smoothed so it never trails the rendered
    /// panel on a SHRINK. A grow (or the first sighting) is adopted immediately —
    /// the cursor is already inside the larger area. A shrink holds the previous,
    /// larger rect for islandShrinkSettle so the down-spring can't collapse the
    /// panel under a cursor resting in the still-visible band; once the hold
    /// elapses the render has caught up and the smaller target is adopted.
    private func collapseRect(target: NSRect) -> NSRect {
        let now = Date()
        if target.height >= heldCollapseRect.height {
            heldCollapseRect = target
            heldCollapseUntil = .distantPast
        } else if heldCollapseUntil == .distantPast {
            // First frame of a new shrink — start the hold, keep the larger rect.
            heldCollapseUntil = now.addingTimeInterval(islandShrinkSettle)
        } else if now >= heldCollapseUntil {
            // Hold elapsed — adopt the settled (smaller) target.
            heldCollapseRect = target
            heldCollapseUntil = .distantPast
        }
        // else: within an active hold — keep the larger heldCollapseRect.
        return heldCollapseRect
    }

    private func rebuildMetrics() {
        // During display reconfiguration NSScreen.screens can be momentarily
        // empty; keep the existing metrics until a screen reappears rather than
        // trapping or building a bogus geometry.
        guard let screen = NotchMetrics.notchScreen() else { return }
        let new = NotchMetrics(screen: screen)
        // Only rebuild when the geometry actually changed. Replacing
        // host.rootView discards all view-local @State (notes focus, sliders,
        // lyrics toggle), so doing it on every incidental screen-parameters
        // notification (e.g. display sleep/wake) caused a visible reset while
        // the panel was expanded.
        if let old = metrics,
           old.windowFrame == new.windowFrame,
           old.notchWidth == new.notchWidth,
           old.notchHeight == new.notchHeight {
            return
        }
        metrics = new
        panel.setFrame(metrics.windowFrame, display: true)
        host.rootView = makeRoot()
    }
}
