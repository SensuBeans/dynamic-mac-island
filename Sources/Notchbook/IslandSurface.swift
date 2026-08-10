import AppKit
import SwiftUI

/// How every floating island is painted — the nav capsule, the content panel,
/// the track toast and the collapsed agent pill. All four already shared one
/// recipe (a `.hudWindow` blur, a black scrim, a hairline white rim); this makes
/// that recipe a single modifier and adds macOS 26's Liquid Glass as one branch
/// of it.
///
/// Ported from Terminal Deck's `DeckSurface`, whose measurements carry over:
/// `liquidGlass` is `.glassEffect` sitting ON TOP of the frosted substrate rather
/// than instead of it, because bare glass over a transparent window keeps ~65% of
/// the wallpaper's chroma — the island would turn whatever colour the desktop is.
/// Over the substrate that drops to ~18%. It also means the two styles differ by
/// exactly one modifier over a shared ground, so the setting reads as one design
/// with and without edge refraction instead of two unrelated looks.
enum IslandSurfaceStyle: String, CaseIterable, Hashable {
    case liquidGlass, frosted, solid

    var title: String {
        switch self {
        case .liquidGlass: return "Liquid Glass"
        case .frosted:     return "Frosted"
        case .solid:       return "Solid"
        }
    }

    /// True where `.glassEffect` genuinely exists. The settings picker uses this
    /// to decide whether to OFFER the segment at all.
    static var liquidGlassAvailable: Bool {
        if #available(macOS 26.0, *) { return true }
        return false
    }

    /// What a stored preference string actually resolves to. Unknown or empty
    /// (nobody has chosen yet) means frosted — today's look — and a Liquid Glass
    /// choice carried onto an older machine downgrades rather than failing.
    static func resolve(_ stored: String) -> IslandSurfaceStyle {
        let want = IslandSurfaceStyle(rawValue: stored) ?? .frosted
        if want == .liquidGlass, !liquidGlassAvailable { return .frosted }
        return want
    }
}

/// The frosted substrate — `.hudWindow`, which is what every island has always
/// used, so the Frosted style is pixel-identical to the pre-Liquid-Glass app.
///
/// `.behindWindow`, not `.withinWindow`: it samples the desktop, exactly as the
/// window's own backdrop does. Two `.behindWindow` views stacked are two
/// independent desktop blurs composited, NOT a blur of a blur — there is no
/// glass-on-glass mud here.
///
/// `.state = .active` matters: the default `.followsWindowActiveState` dims the
/// island every time the window loses key, and the island is never key.
struct VisualEffectBlur: NSViewRepresentable {
    var material: NSVisualEffectView.Material = .hudWindow

    func makeNSView(context: Context) -> NSVisualEffectView {
        let view = NSVisualEffectView()
        apply(to: view)
        return view
    }

    func updateNSView(_ view: NSVisualEffectView, context: Context) { apply(to: view) }

    private func apply(to view: NSVisualEffectView) {
        view.material = material
        view.blendingMode = .behindWindow
        view.state = .active
    }
}

/// One island's material treatment.
///
/// Shadows are NOT handled here. Every island's shadow is tuned to its own
/// geometry, and the nav capsule's has to stay in lockstep with the matching one
/// on LiquidNav's canvas or it pops at the goo→glass cross-fade — so shadows stay
/// at the call sites where that pairing is visible.
struct IslandSurface<S: InsettableShape>: ViewModifier {
    var shape: S
    /// The black scrim over the substrate. The islands were tuned at two levels:
    /// 0.32 for the big surfaces (nav capsule, content panel) and 0.4 for the
    /// small floating capsules (toast, agent pill). Liquid Glass supplies its own
    /// depth and takes no scrim.
    var dim: Double = 0.32
    var rim: Bool = true
    /// Liquid Glass's hover/press response. Only for controls.
    var interactive: Bool = false

    let style: IslandSurfaceStyle
    @Environment(\.accessibilityReduceTransparency) private var reduceTransparency

    /// What actually gets drawn, after the accessibility setting has had its say.
    /// `.glassEffect` is not documented to honour Reduce Transparency, so it is
    /// gated by hand. (`style` has already been through
    /// `IslandSurfaceStyle.resolve`, so the OS downgrade is done.)
    private var effective: IslandSurfaceStyle {
        reduceTransparency ? .solid : style
    }

    /// `content` appears EXACTLY ONCE here, in no conditional, and that is the
    /// whole design of this method.
    ///
    /// SwiftUI gives the same view in two branches of a conditional two different
    /// structural identities, so putting `content` inside the style switch would
    /// tear down and rebuild everything the modifier wraps every time the setting
    /// changed — and here that wraps the entire content panel, including whatever
    /// page is open and any half-finished edit in it. Deck lost an in-flight
    /// rename and a half-typed URL to exactly this before moving the branching
    /// into the BACKGROUND, which may rebuild as often as it likes because nothing
    /// living is in it.
    func body(content: Content) -> some View {
        content
            .background { surfaceLayer }
            .clipShape(shape)
            .overlay { if rim { rimStroke } }
    }

    /// The ground under the content. Glass goes here rather than on `content`
    /// itself: `.glassEffect` renders the material for `shape`, and it does that
    /// just as well behind the content as around it.
    @ViewBuilder
    private var surfaceLayer: some View {
        switch effective {
        case .liquidGlass:
            if #available(macOS 26.0, *) {
                Color.clear
                    .glassEffect(glass, in: shape)
                    .background { VisualEffectBlur().clipShape(shape) }
            } else {
                // Not reachable — `resolve` already downgrades below 26 — but it
                // renders the frosted ground rather than nothing, so that if
                // anyone ever collapses that downgrade the worst case is a
                // plainer island instead of an invisible one.
                frostedLayer
            }
        case .frosted:
            frostedLayer
        case .solid:
            shape.fill(Color(nsColor: .windowBackgroundColor))
        }
    }

    private var frostedLayer: some View {
        ZStack {
            VisualEffectBlur()
            Color.black.opacity(dim)
        }
        .clipShape(shape)
    }

    /// The islands' long-standing hairline: a flat white 0.14 at 0.5pt. Kept flat
    /// rather than Deck's top-bright gradient because these are small, and at a
    /// 34pt capsule a vertical gradient rim reads as a lighting error rather than
    /// a specular edge.
    private var rimStroke: some View {
        shape.strokeBorder(.white.opacity(0.14), lineWidth: 0.5)
    }

    /// A gated COMPUTED property. `Glass` can never be a STORED property —
    /// `@available(macOS 26.0, *) var g: Glass` is a hard compiler error
    /// ("stored properties cannot be marked potentially unavailable").
    @available(macOS 26.0, *)
    private var glass: Glass {
        var g: Glass = .regular
        if interactive { g = g.interactive() }
        return g
    }
}

extension View {
    /// Paint this view as a floating island. `style` comes from
    /// `IslandSurfaceStyle.resolve(settings.surfaceStyle)` at the call site, so
    /// each island reads the setting once rather than every sub-view reaching for
    /// the store.
    ///
    /// Do NOT nest one of these inside another. Glass inside glass refracts an
    /// already-refracted surface and renders as a muddy blob — which is why the
    /// tab chips and the pages pill stay flat `.white.opacity(…)` fills inside the
    /// nav capsule.
    func islandSurface<S: InsettableShape>(_ shape: S,
                                           style: IslandSurfaceStyle,
                                           dim: Double = 0.32,
                                           rim: Bool = true,
                                           interactive: Bool = false) -> some View {
        modifier(IslandSurface(shape: shape, dim: dim, rim: rim,
                               interactive: interactive, style: style))
    }
}
