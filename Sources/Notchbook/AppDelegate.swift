import AppKit
import Combine
import SwiftUI
import IOKit.ps

final class AppDelegate: NSObject, NSApplicationDelegate {
    private var panel: NotchPanel!
    private var host: PassThroughHostingView!
    private var metrics: NotchMetrics!

    private let state = NotchState()
    private let media = MediaWatcher()
    private let tray = FilesTray()
    private let spectrum = AudioSpectrum()
    private let calendarModel = CalendarModel()
    private let mirror = MirrorController()
    private let toggles = TogglesModel()
    private let stats = StatsModel()
    private let pomodoro = PomodoroModel()

    private var keyMonitor: Any?
    private var globalMouseMonitor: Any?
    private var localMouseMonitor: Any?
    private var expandWork: DispatchWorkItem?
    private var hoverPoll: Timer?
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

    func applicationDidFinishLaunching(_ notification: Notification) {
        metrics = NotchMetrics(screen: NotchMetrics.notchScreen())
        state.onQuit = { NSApp.terminate(nil) }
        state.onExpandRequest = { [weak self] in self?.expand() }
        state.onHoverChange = { [weak self] inside in self?.hoverIsland(inside) }

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
                s = self.state.currentTab == .tray
                    ? self.metrics.trayExpandedSize(itemCount: self.tray.items.count)
                    : self.metrics.expandedSize(zoomed: onMirror,
                                                large: onMirror && self.state.mirrorBig)
                // The panel floats below the notch — the interactive rect
                // bridges notch, gap, and panel so crossing the gap doesn't
                // read as leaving the island.
                s.height += self.metrics.notchHeight + NotchMetrics.islandGap * 2
                    + NotchMetrics.navIslandHeight
                x = self.metrics.islandLeadingPad(expanded: true,
                                                  zoomed: onMirror,
                                                  large: onMirror && self.state.mirrorBig)
            } else {
                s = self.metrics.collapsedSize(withMedia: (self.media.nowPlaying != nil && !self.media.earHidden) || self.pomodoro.isRunning,
                                               toast: self.state.toast != nil)
                x = self.metrics.islandLeadingPad(expanded: false)
            }
            let y = self.host.isFlipped ? 0 : self.host.bounds.height - s.height
            return NSRect(x: x, y: y, width: s.width, height: s.height)
        }
        host.onMouseState = { [weak self] inside in self?.hoverIsland(inside) }
        host.onEarHover = { [weak self] over in self?.setEarHover(over) }
        host.onScroll = { [weak self] event in self?.handleIslandSwipe(event) }
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
            return self.host.islandRect().minX + NotchMetrics.wing + self.metrics.notchWidth
        }
        host.frame = NSRect(origin: .zero, size: metrics.windowFrame.size)
        host.autoresizingMask = [.width, .height]
        panel.contentView = host
        panel.orderFrontRegardless()

        // Esc collapses while the panel has focus.
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            if event.keyCode == 53, self?.state.isExpanded == true {
                self?.collapse()
                return nil
            }
            return event
        }

        observerTokens.append(NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.rebuildMetrics() })

        setupToasts()

        pomodoro.onPhaseEnd = { [weak self] ended in
            NSSound(named: "Glass")?.play()
            self?.state.showToast(NotchToast(
                icon: ended == .focus ? "cup.and.saucer.fill" : "brain.head.profile",
                title: ended == .focus ? "Focus done" : "Break over",
                subtitle: ended == .focus ? "Take a break" : "Back to work",
                color: ended == .focus ? .green : .orange), duration: 4)
        }

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
            guard let self else { return }
            // Space-switch detection: activeSpaceDidChange never fires on this
            // macOS, but each Space has its own Dock wallpaper window — a
            // change in its ID means the user is switching desktops.
            let wallpaper = self.currentWallpaperID()
            if self.lastWallpaper.isEmpty {
                self.lastWallpaper = wallpaper
            } else if wallpaper != self.lastWallpaper, wallpaper != "?" {
                self.lastWallpaper = wallpaper
                self.state.spaceTransitioning = true
                self.spaceWork?.cancel()
                let work = DispatchWorkItem { [weak self] in
                    self?.state.spaceTransitioning = false
                }
                self.spaceWork = work
                DispatchQueue.main.asyncAfter(deadline: .now() + 0.7, execute: work)
            }
            guard !self.state.isExpanded else { return }
            let zone = self.host.hoverZoneRect?() ?? self.host.islandRect()
            let zoneScreen = self.panel.convertToScreen(self.host.convert(zone, to: nil))
            let islandScreen = self.panel.convertToScreen(
                self.host.convert(self.host.islandRect(), to: nil))
            let mouse = NSEvent.mouseLocation
            if zoneScreen.contains(mouse) {
                self.expand()
            } else {
                let earX = islandScreen.minX + NotchMetrics.wing + self.metrics.notchWidth
                self.setEarHover(mouse.x > earX && islandScreen.contains(mouse))
            }
        }
    }

    private func setupToasts() {
        // Track changes → brief island toast with artwork.
        media.$nowPlaying
            .compactMap { $0 }
            .removeDuplicates { $0.title == $1.title }
            .dropFirst()
            .sink { [weak self] np in
                guard let self, !self.state.isExpanded else { return }
                self.state.showToast(NotchToast(icon: "music.note", title: np.title,
                                                subtitle: np.artist, useArtwork: true))
            }
            .store(in: &cancellables)

        batteryTimer = Timer.scheduledTimer(withTimeInterval: 15, repeats: true) { [weak self] _ in
            self?.checkBattery()
        }
    }

    private func checkBattery() {
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
    /// Volume percent gained per point of vertical travel.
    private static let volumePerPoint: Double = 0.4

    private func haptic(_ pattern: NSHapticFeedbackManager.FeedbackPattern = .alignment) {
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
            if !state.isExpanded, media.nowPlaying != nil {
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
            if abs(swipeX) > 40, abs(swipeX) > abs(swipeY) {
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
        let tabs = NotchTab.allCases
        guard delta != 0, let i = tabs.firstIndex(of: state.currentTab) else { return }
        let n = tabs.count
        state.currentTab = tabs[((i + delta) % n + n) % n]
        haptic()
    }

    /// Maps the accumulated vertical swipe onto the player volume. Sends
    /// only whole-percent changes, rate-limited, so a fast swipe can't spawn
    /// an osascript pile-up; a haptic tick marks every 10% detent.
    private func updateLiveVolume(final: Bool) {
        guard media.nowPlaying != nil, let base = volumeBase,
              abs(swipeY) > 12, abs(swipeY) > abs(swipeX) else { return }
        let whole = Int(min(100, max(0, base - swipeY * Self.volumePerPoint)).rounded())
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
            .environmentObject(spectrum))
    }

    /// Expand on hover, effectively instantly. SwiftUI can drop hover-exit
    /// events on fast cursor moves, so after one beat we re-verify the cursor
    /// is STILL on the island before opening — instant response for a real
    /// hover, no phantom opens from a cursor that merely passed through.
    private func hoverIsland(_ inside: Bool) {
        expandWork?.cancel()
        guard inside, !state.isExpanded else { return }
        let work = DispatchWorkItem { [weak self] in
            guard let self, !self.state.isExpanded else { return }
            let inWindow = self.host.convert(self.host.islandRect(), to: nil)
            let screenRect = self.panel.convertToScreen(inWindow)
            let onIsland = screenRect.contains(NSEvent.mouseLocation)
            NSLog("notchbook dwell-check onIsland=%d rect=%@ mouse=%@",
                  onIsland ? 1 : 0,
                  NSStringFromRect(screenRect),
                  NSStringFromPoint(NSEvent.mouseLocation))
            if onIsland { self.expand() }
        }
        expandWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.05, execute: work)
    }

    private func expand() {
        guard !state.isExpanded else { return }
        state.isExpanded = true
        media.refresh()
        panel.makeKeyAndOrderFront(nil)
        startMouseWatch()
    }

    private func collapse() {
        guard state.isExpanded else { return }
        stopMouseWatch()
        state.isExpanded = false
        state.pinned = false
        state.navHovered = false
        state.mirrorBig = false
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
            if !visible.contains(mouse), !self.state.pinned {
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
        metrics = NotchMetrics(screen: NotchMetrics.notchScreen())
        panel.setFrame(metrics.windowFrame, display: true)
        host.rootView = makeRoot()
    }
}
