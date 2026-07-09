import AppKit

/// Geometry for the collapsed (notch-hugging) and expanded (notebook) states,
/// derived from the screen's real notch when present.
struct NotchMetrics {
    let screen: NSScreen
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    /// Extra width either side of the physical notch (visual only, when the
    /// island is showing content). The hover zone hugs the notch exactly.
    static let wing: CGFloat = 14
    /// The hover/expand trigger zone: the physical notch bounds, exactly.
    var hoverZoneSize: CGSize { CGSize(width: notchWidth, height: notchHeight) }
    static let topFlare: CGFloat = 6

    static let expandedContentSize = CGSize(width: 460, height: 240)
    /// Larger island used while the mirror is zoomed.
    static let zoomedContentSize = CGSize(width: 620, height: 470)
    /// Transparent margin around the expanded shape so its shadow isn't clipped.
    static let shadowPad: CGFloat = 40
    /// Extra ear width either side of the notch while media is active, so the
    /// island can show album art and a now-playing indicator like the iPhone's
    /// Dynamic Island.
    static let mediaEar: CGFloat = 12

    init(screen: NSScreen) {
        self.screen = screen
        if screen.safeAreaInsets.top > 0,
           let left = screen.auxiliaryTopLeftArea,
           let right = screen.auxiliaryTopRightArea {
            notchWidth = screen.frame.width - left.width - right.width
            notchHeight = screen.safeAreaInsets.top
        } else {
            // No physical notch (external display, older Mac): fake one.
            notchWidth = 190
            notchHeight = 32
        }
    }

    /// Width of the media ear on the RIGHT side only: album art + equalizer.
    /// The left side stays at notch width so the island never covers the
    /// frontmost app's menu items (they grow from the left).
    var mediaEarWidth: CGFloat {
        (notchHeight - 10) + 6 + 30 + 8
    }

    func collapsedSize(withMedia: Bool, toast: Bool = false) -> CGSize {
        let extra: CGFloat = toast ? 215 : (withMedia ? mediaEarWidth : 0)
        return CGSize(width: notchWidth + Self.wing * 2 + extra, height: notchHeight)
    }

    func expandedSize(zoomed: Bool = false) -> CGSize {
        let content = zoomed ? Self.zoomedContentSize : Self.expandedContentSize
        return CGSize(width: max(content.width, collapsedSize(withMedia: true).width),
                      height: notchHeight + content.height)
    }

    /// The tray hugs its content like a proper drop shelf: one row of files
    /// keeps the panel short; more rows grow it up to the standard height,
    /// after which the grid scrolls.
    func trayExpandedSize(itemCount: Int) -> CGSize {
        let columns = 6  // 62pt tiles + 8pt gaps in the 428pt content width
        let rows = max(1, (itemCount + columns - 1) / columns)
        // 74pt per tile row (tile + label), 8pt between rows; 28pt footer
        // block; 56pt tab bar + paddings.
        let grid = CGFloat(rows) * 74 + CGFloat(rows - 1) * 8
        let content = min(Self.expandedContentSize.height, 56 + grid + 28)
        var size = expandedSize()
        size.height = notchHeight + content
        return size
    }

    /// The ONE window frame: fixed and centered, sized for the expanded
    /// island plus shadow margins. The window never moves or resizes — the
    /// island animates inside it, so transitions can never visually snap.
    /// Clicks in the window's fully transparent areas pass through to the
    /// windows beneath (standard behavior for borderless clear windows).
    var windowFrame: NSRect {
        let biggest = expandedSize(zoomed: true)
        let size = CGSize(width: biggest.width + Self.shadowPad * 2,
                          height: biggest.height + Self.shadowPad)
        let f = screen.frame
        return NSRect(x: f.midX - size.width / 2,
                      y: f.maxY - size.height,
                      width: size.width, height: size.height)
    }

    /// Leading padding of the island inside the fixed window. Collapsed, the
    /// island's left edge sits flush beside the notch (media ear grows right
    /// only); expanded, the panel is centered.
    func islandLeadingPad(expanded: Bool, zoomed: Bool = false) -> CGFloat {
        expanded ? (windowFrame.width - expandedSize(zoomed: zoomed).width) / 2
                 : windowFrame.width / 2 - notchWidth / 2 - Self.wing
    }

    /// Prefer the screen that actually has a notch.
    static func notchScreen() -> NSScreen {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.main
            ?? NSScreen.screens[0]
    }
}
