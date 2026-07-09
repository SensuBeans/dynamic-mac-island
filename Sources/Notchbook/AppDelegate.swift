import AppKit
import Combine
import SwiftUI

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
                s = self.metrics.collapsedSize(withMedia: self.media.nowPlaying != nil)
                x = self.metrics.islandLeadingPad(expanded: false)
            }
            let y = self.host.isFlipped ? 0 : self.host.bounds.height - s.height
            return NSRect(x: x, y: y, width: s.width, height: s.height)
        }
        host.onMouseState = { [weak self] inside in self?.hoverIsland(inside) }
        host.onEarHover = { [weak self] over in self?.setEarHover(over) }
        // Hovering the sound-wave ear must NOT open the panel — it's a
        // click target for play/pause.
        host.hoverZoneRect = { [weak self] in
            guard let self else { return .zero }
            var r = self.host.islandRect()
            if !self.state.isExpanded, self.media.nowPlaying != nil {
                r.size.width = max(0, r.width - self.metrics.mediaEarWidth)
            }
            return r
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

        NotificationCenter.default.addObserver(
            forName: NSApplication.didChangeScreenParametersNotification,
            object: nil, queue: .main
        ) { [weak self] _ in self?.rebuildMetrics() }

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
                self.expand()
            } else {
                self.setEarHover(islandScreen.contains(mouse))
            }
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
