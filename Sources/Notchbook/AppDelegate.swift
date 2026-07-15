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
    private let toggles = TogglesModel()
    private let stats = StatsModel()
    private let pomodoro = PomodoroModel()
    private let audioOutput = AudioOutputModel()
    private let settings = SettingsStore()
    private let terminalSessions = TerminalSessionsModel()
    private let agentSessions = AgentSessionsModel()
    private let notesSync = NotesSyncModel()

    private var keyMonitor: Any?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
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
    /// Block-observer tokens auto-unregister on dealloc — must be retained.
    private var observerTokens: [NSObjectProtocol] = []
    private var cancellables = Set<AnyCancellable>()

    /// Thread-safe snapshot of the island's built-in Terminal-tab shells,
    /// `(sessionID, shellPid)`. `TerminalSessionsModel.sessions` is main-only, but
    /// `AgentSessionsModel` reads this on its own `ioQueue` to recognize a Claude
    /// session hosted inside the island — so the snapshot is updated on main and
    /// read under a lock.
    private let builtinShellLock = NSLock()
    private var builtinShellSnapshot: [(UUID, Int32)] = []

    func applicationDidFinishLaunching(_ notification: Notification) {
        guard let screen = NotchMetrics.notchScreen() else { return }
        metrics = NotchMetrics(screen: screen)
        state.onQuit = { NSApp.terminate(nil) }
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
                if self.state.currentTab == .tray {
                    s = self.metrics.trayExpandedSize(itemCount: self.tray.items.count,
                                                      cell: self.settings.trayTileSize)
                } else if self.state.currentTab == .terminal {
                    s = NotchMetrics.terminalIslandSize
                } else if self.state.currentTab == .agents {
                    s = NotchMetrics.agentsIslandSize
                } else if self.state.currentTab == .calendar {
                    s = self.metrics.calendarExpandedSize(monthMode: self.state.calendarMonthMode)
                } else {
                    s = self.metrics.expandedSize(zoomed: onMirror,
                                                  large: onMirror && self.state.mirrorBig)
                }
                // Center on the ACTUAL island width so hover hit-testing tracks
                // the rendered island (terminal is wider than the standard
                // panel) — must match the .padding(.leading) in NotchView.
                x = self.metrics.expandedLeadingPad(width: s.width)
                // The panel floats below the notch — the interactive rect
                // bridges notch, gap, and panel so crossing the gap doesn't
                // read as leaving the island.
                s.height += self.metrics.notchHeight + NotchMetrics.islandGap * 2
                    + NotchMetrics.navIslandHeight
            } else {
                s = self.metrics.collapsedSize(withMedia: (self.media.nowPlaying != nil && !self.media.earHidden) || (self.pomodoro.isRunning && self.settings.timerCountdownEar),
                                               toast: self.state.toast != nil,
                                               withAgent: self.agentSessions.hasActivePill)
                x = self.metrics.islandLeadingPad(expanded: false)
            }
            let y = self.host.isFlipped ? 0 : self.host.bounds.height - s.height
            return NSRect(x: x, y: y, width: s.width, height: s.height)
        }
        host.onMouseState = { [weak self] inside in self?.hoverIsland(inside) }
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

        // Esc collapses while the panel has focus — except on the Terminal
        // tab, where Esc must reach the shell (vim/less would be unusable
        // otherwise). Collapse there still works via mouse-leave, pin, or
        // clicking away.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            guard let self else { return event }
            if event.keyCode == 53, self.state.isExpanded,
               self.state.currentTab != .terminal {
                self.collapse()
                return nil
            }
            // A finished terminal session has no PTY to receive input; Return
            // (or Enter) dismisses it, per the exit hint.
            if self.state.isExpanded, self.state.currentTab == .terminal,
               event.keyCode == 36 || event.keyCode == 76,
               let sel = self.terminalSessions.selected, !sel.isAlive {
                self.terminalSessions.closeSession(id: sel.id)
                return nil
            }
            return event
        }

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

        // Feed the agent model the island's built-in shells (main-mutated,
        // ioQueue-read) so a Claude session running inside the notch's own
        // Terminal tab resolves to `.notch` and matches its exact session. Wire
        // the snapshot BEFORE start() so the initial scan can already see it.
        agentSessions.builtinShellPids = { [weak self] in
            guard let self else { return [] }
            self.builtinShellLock.lock(); defer { self.builtinShellLock.unlock() }
            return self.builtinShellSnapshot
        }
        terminalSessions.$sessions
            .sink { [weak self] sessions in
                guard let self else { return }
                let pids = sessions.compactMap { s -> (UUID, Int32)? in
                    let pid = s.view.process.shellPid
                    return pid > 0 ? (s.id, pid) : nil
                }
                self.builtinShellLock.lock()
                self.builtinShellSnapshot = pids
                self.builtinShellLock.unlock()
            }
            .store(in: &cancellables)

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
            NSSound(named: "Glass")?.play()
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
            volumeReadToken += 1
        default:
            break
        }
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
        toggles.shutdown()
        terminalSessions.shutdown()
        agentSessions.shutdown()
        if settings.trayClearOnQuit { tray.clear() }
    }

    private func makeRoot() -> AnyView {
        AnyView(NotchView(metrics: metrics)
            .environmentObject(state)
            .environmentObject(media)
            .environmentObject(tray)
            .environmentObject(calendarModel)
            .environmentObject(mirror)
            .environmentObject(toggles)
            .environmentObject(stats)
            .environmentObject(pomodoro)
            .environmentObject(spectrum)
            .environmentObject(lyrics)
            .environmentObject(audioOutput)
            .environmentObject(terminalSessions)
            .environmentObject(agentSessions)
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
        guard state.isExpanded else { return }
        stopMouseWatch()
        state.isExpanded = false
        state.pinned = false
        state.navHovered = false
        if !settings.mirrorRememberBig { state.mirrorBig = false }
        state.settingsRoute = nil
        state.saveNow()
        mirror.stop()
        media.setProgressPolling(false)
    }

    /// Collapse the moment the cursor leaves the visible island bounds.
    private func startMouseWatch() {
        let check: () -> Void = { [weak self] in
            guard let self, self.state.isExpanded else { return }
            // Proper view→window→screen conversion handles the hosting
            // view's flipped coordinate system.
            let inWindow = self.host.convert(self.host.islandRect(), to: nil)
            let visible = self.panel.convertToScreen(inWindow).insetBy(dx: -6, dy: -6)
            let mouse = NSEvent.mouseLocation
            // The nav dock lives in the bottom strip of the island stack
            // (screen coords are bottom-up); it shows only while the cursor
            // is down there or a swipe is in flight.
            let navZone = NSRect(x: visible.minX, y: visible.minY,
                                 width: visible.width,
                                 height: NotchMetrics.navIslandHeight
                                     + NotchMetrics.islandGap + 16)
            let inNav = navZone.contains(mouse)
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
