import AppKit

/// Geometry for the collapsed (notch-hugging) and expanded (notebook) states,
/// derived from the screen's real notch when present.
struct NotchMetrics {
    let screen: NSScreen
    let notchWidth: CGFloat
    let notchHeight: CGFloat

    /// Visual wings either side of the notch — now ZERO: the collapsed island is
    /// exactly the physical notch footprint, extras grow rightward only. Kept as
    /// a named constant (not deleted) so existing call sites stay valid.
    static let wing: CGFloat = 0
    /// The hover/expand trigger zone: the physical notch bounds, exactly.
    var hoverZoneSize: CGSize { CGSize(width: notchWidth, height: notchHeight) }
    static let topFlare: CGFloat = 6
    /// Gap between the physical notch and the floating expanded island.
    static let islandGap: CGFloat = 6
    /// Height of the floating nav-bar island.
    static let navIslandHeight: CGFloat = 34
    /// Resting gap between the nav bar and the content panel. Wider than
    /// `islandGap` on purpose: the goo neck must fully pinch off here so the nav
    /// reads as a separated capsule when shown, only fusing mid-transition.
    static let navContentGap: CGFloat = 14

    static let expandedContentSize = CGSize(width: 460, height: 158)
    /// Larger island used while the mirror is zoomed.
    static let zoomedContentSize = CGSize(width: 620, height: 470)
    /// The terminal tab needs real estate — roughly 90×20 cells at 11pt mono.
    /// This is the final island size (chips + terminal), not a "content" size,
    /// so it is used verbatim rather than run through `expandedSize`.
    static let terminalIslandSize = CGSize(width: 620, height: 320)
    /// The Agents tab is a session dashboard — tall enough for ~5 rows before
    /// the list scrolls. Final island size, used verbatim like the terminal's.
    static let agentsIslandSize = CGSize(width: 470, height: 300)
    /// The Servers tab (Local Starter list) — same footprint as the Agents tab.
    static let serversIslandSize = CGSize(width: 470, height: 300)
    /// Transparent margin around the expanded shape so its shadow isn't clipped.
    static let shadowPad: CGFloat = 40
    /// Extra ear width either side of the notch while media is active, so the
    /// island can show album art and a now-playing indicator like the iPhone's
    /// Dynamic Island.
    static let mediaEar: CGFloat = 12
    /// Extra ear width on the RIGHT for the collapsed agent-status pill
    /// (state glyph + count capsule). Like the media ear, it grows the island
    /// rightward only; the left side stays at notch width. Sits OUTBOARD of the
    /// media ear when both are present.
    static let agentEar: CGFloat = 56
    /// Slot reserved on the RIGHT for the floating toast capsule (icon + one line
    /// of text). Its own little island beside the notch — the black bar does NOT
    /// widen for it.
    static let toastEar: CGFloat = 202

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

    func collapsedSize(withMedia: Bool, toast: Bool = false,
                       withAgent: Bool = false) -> CGSize {
        // Toast and the agent pill are mutually exclusive (the pill is hidden
        // while a toast is up); both float outboard of the media ear.
        let outboard: CGFloat = toast ? Self.toastEar : (withAgent ? Self.agentEar : 0)
        let extra: CGFloat = (withMedia ? mediaEarWidth : 0) + outboard
        // EXACTLY the physical notch width, plus right-side content only — no
        // wings. The bar's left edge sits flush at the notch's left edge; all
        // extras (ear, toast, pill slot) grow rightward from the notch.
        return CGSize(width: notchWidth + extra, height: notchHeight)
    }

    /// "Twice as big" mirror: double the zoomed width, clamped so the island
    /// (with notch and shadow margins) always fits on the screen.
    var mirrorLargeContentSize: CGSize {
        let f = screen.frame
        return CGSize(width: min(Self.zoomedContentSize.width * 2,
                                 f.width - Self.shadowPad * 2 - 40),
                      height: min(Self.zoomedContentSize.height * 2,
                                  f.height - notchHeight - Self.shadowPad - 80))
    }

    func expandedSize(zoomed: Bool = false, large: Bool = false) -> CGSize {
        let content = large ? mirrorLargeContentSize
                    : zoomed ? Self.zoomedContentSize
                    : Self.expandedContentSize
        // The panel floats BELOW the notch as its own island, so its height
        // is just the content plus a small top pad (no notch strip).
        // The nav bar lives in its own island above, so the content panel
        // sheds the old in-panel tab bar (24pt) + spacing (10pt).
        return CGSize(width: max(content.width, collapsedSize(withMedia: true).width),
                      height: content.height - 30)
    }

    /// The tray hugs its content like a proper drop shelf: one row of files
    /// keeps the panel short; more rows grow it up to the standard height,
    /// after which the grid scrolls.
    /// `cell` is the grid tile edge (the tray tile-size setting: 62 normal,
    /// 54 compact). Columns and row height derive from it so the island height
    /// never drifts from the actual grid. At 62 this reproduces the original
    /// 6-column / 74pt-row layout exactly.
    func trayExpandedSize(itemCount: Int, cell: CGFloat = 62) -> CGSize {
        let gap: CGFloat = 8
        let contentWidth: CGFloat = 428  // usable grid width
        let columns = max(1, Int((contentWidth + gap) / (cell + gap)))
        let rows = max(1, (itemCount + columns - 1) / columns)
        let rowHeight = cell + 12  // tile + label
        let grid = CGFloat(rows) * rowHeight + CGFloat(rows - 1) * gap
        let content = min(Self.expandedContentSize.height, 56 + grid + 28)
        var size = expandedSize()
        size.height = content - 30
        return size
    }

    /// The calendar tab grows taller in month mode to fit a comfortable month
    /// grid beside the selected day's events; list mode uses the standard size.
    func calendarExpandedSize(monthMode: Bool) -> CGSize {
        guard monthMode else { return expandedSize() }
        var size = expandedSize()
        size.height = 210
        return size
    }

    /// The ONE window frame: fixed and centered, sized for the expanded
    /// island plus shadow margins. The window never moves or resizes — the
    /// island animates inside it, so transitions can never visually snap.
    /// Clicks in the window's fully transparent areas pass through to the
    /// windows beneath (standard behavior for borderless clear windows).
    var windowFrame: NSRect {
        let biggest = expandedSize(zoomed: true, large: true)
        let size = CGSize(width: biggest.width + Self.shadowPad * 2,
                          height: biggest.height + Self.shadowPad + 90)
        let f = screen.frame
        return NSRect(x: f.midX - size.width / 2,
                      y: f.maxY - size.height,
                      width: size.width, height: size.height)
    }

    /// Leading padding of the island inside the fixed window. Collapsed, the
    /// island's left edge sits flush beside the notch (media ear grows right
    /// only); expanded, the panel is centered.
    func islandLeadingPad(expanded: Bool, zoomed: Bool = false,
                          large: Bool = false) -> CGFloat {
        expanded ? (windowFrame.width - expandedSize(zoomed: zoomed, large: large).width) / 2
                 : windowFrame.width / 2 - notchWidth / 2
    }

    /// Leading pad that centers an expanded island of an explicit width — used
    /// by tabs whose island isn't sized by `expandedSize` (tray, terminal,
    /// calendar month mode). Keeps hover hit-testing aligned with the rendered
    /// island whatever its width.
    func expandedLeadingPad(width: CGFloat) -> CGFloat {
        (windowFrame.width - width) / 2
    }

    /// Prefer the screen that actually has a notch. Returns nil when no screen
    /// is available — `NSScreen.screens` is momentarily empty during display
    /// reconfiguration, and indexing `[0]` there would trap.
    static func notchScreen() -> NSScreen? {
        NSScreen.screens.first { $0.safeAreaInsets.top > 0 }
            ?? NSScreen.main
            ?? NSScreen.screens.first
    }
}
