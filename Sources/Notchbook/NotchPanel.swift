import AppKit

/// Borderless, non-activating panel that floats over the menu bar / notch
/// on every space, including full-screen apps.
final class NotchPanel: NSPanel {
    init(contentRect: NSRect) {
        super.init(contentRect: contentRect,
                   styleMask: [.borderless, .nonactivatingPanel],
                   backing: .buffered,
                   defer: false)
        isFloatingPanel = true
        level = .statusBar
        collectionBehavior = [.canJoinAllSpaces, .stationary, .fullScreenAuxiliary]
        isOpaque = false
        backgroundColor = .clear
        hasShadow = false
        isMovable = false
        hidesOnDeactivate = false
        becomesKeyOnlyIfNeeded = true
        animationBehavior = .none
    }

    override var canBecomeKey: Bool { true }
    override var canBecomeMain: Bool { false }
}

import SwiftUI

/// Hosting view that only claims mouse events inside the island's bounds —
/// the rest of the fixed transparent window lets clicks fall through to
/// whatever windows are beneath it.
final class PassThroughHostingView: NSHostingView<AnyView> {
    var islandRect: () -> NSRect = { .zero }
    /// The sub-rect of the island whose hover should EXPAND the panel —
    /// excludes the sound-wave ear so it can be clicked without opening.
    var hoverZoneRect: (() -> NSRect)?
    /// Reports whether the cursor is over the hover zone. Driven by our own
    /// AppKit tracking area — SwiftUI's .onHover regions silently stop
    /// firing in this always-up accessory panel after a while.
    var onMouseState: ((Bool) -> Void)?
    /// Cursor is over the island but outside the hover zone (i.e., the ear).
    var onEarHover: ((Bool) -> Void)?

    private var hoverArea: NSTrackingArea?

    override func hitTest(_ point: NSPoint) -> NSView? {
        let local = convert(point, from: superview)
        guard islandRect().insetBy(dx: -4, dy: -4).contains(local) else { return nil }
        return super.hitTest(point)
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let hoverArea { removeTrackingArea(hoverArea) }
        let area = NSTrackingArea(
            rect: bounds,
            options: [.mouseEnteredAndExited, .mouseMoved, .activeAlways],
            owner: self)
        addTrackingArea(area)
        hoverArea = area
    }

    override func mouseEntered(with event: NSEvent) {
        super.mouseEntered(with: event)
        reportHover(event)
    }

    override func mouseMoved(with event: NSEvent) {
        super.mouseMoved(with: event)
        reportHover(event)
    }

    override func mouseExited(with event: NSEvent) {
        super.mouseExited(with: event)
        onMouseState?(false)
        onEarHover?(false)
    }

    private func reportHover(_ event: NSEvent) {
        let p = convert(event.locationInWindow, from: nil)
        let zone = hoverZoneRect?() ?? islandRect()
        let inZone = zone.insetBy(dx: -2, dy: -2).contains(p)
        onMouseState?(inZone)
        // The ear is strictly RIGHT of the notch — the left wing is neither
        // trigger nor ear.
        onEarHover?(!inZone && p.x > zone.maxX
                    && islandRect().insetBy(dx: -2, dy: -2).contains(p))
    }
}
