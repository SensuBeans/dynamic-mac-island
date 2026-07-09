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
    private let calendarModel = CalendarModel()
    private let mirror = MirrorController()
    private let toggles = TogglesModel()
    private let stats = StatsModel()

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
            let s: CGSize
            let x: CGFloat
            if self.state.isExpanded {
                s = self.metrics.expandedSize(zoomed: self.state.mirrorZoomed)
                x = self.metrics.islandLeadingPad(expanded: true,
                                                  zoomed: self.state.mirrorZoomed)
            } else {
                s = self.metrics.collapsedSize(withMedia: self.media.nowPlaying != nil && !self.media.earHidden,
                                               toast: self.state.toast != nil)
                x = self.metrics.islandLeadingPad(expanded: false)
            }
            let y = self.host.isFlipped ? 0 : self.host.bounds.height - s.height
            return NSRect(x: x, y: y, width: s.width, height: s.height)
        }
        host.onMouseState = { [weak self] inside in self?.hoverIsland(inside) }
        host.onEarHover = { [weak self] over in self?.setEarHover(over) }
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
            .environmentObject(stats))
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
        state.mirrorZoomed = false
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
            if !visible.contains(NSEvent.mouseLocation) { self.collapse() }
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
