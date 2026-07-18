import SwiftUI

/// "Surface Bulge" liquid for the nav bar (motion study 02). Nothing arrives
/// from outside: the content panel's own top surface swells upward, the swell
/// rounds into a droplet, and the droplet IS the capsule. On hide it runs in
/// exact reverse — the droplet sinks back and the surface closes flat.
///
/// Technique: the classic metaball. Draw the descending panel-top blob and the
/// rising droplet blob into a Canvas layer, `.blur` them so their alphas bleed
/// together, then `.alphaThreshold` to snap the fused alpha into a hard liquid
/// silhouette (the overlap becomes the neck). Because the droplet is BORN from
/// the panel edge (blobs start fully merged, not approaching from afar), there
/// is no far-gap to bridge — the surface just distends and pinches.
///
/// A second, gentler metaball pass carries the "icon melt": a single light blob
/// at the droplet's center splits into five dots that spread to the tab-icon
/// positions, then cross-fade into the real SF Symbols at the very end.
///
/// `t` is eased reveal progress (`navT`): 0 = flat panel surface (nav absorbed),
/// 1 = a separate capsule. The panel-top blob sits BEHIND the real content
/// panel, so only the neck rising off it ever shows.
struct LiquidNav: View, Animatable {
    var t: Double

    /// Interpolate `t` through animation transactions. Without this, SwiftUI
    /// hands the Canvas only the END value of a withAnimation change — the
    /// morph never draws a single mid-flight frame live (freeze-flag renders
    /// looked perfect while the real animation showed nothing).
    var animatableData: Double {
        get { t }
        set { t = newValue }
    }

    var panelWidth: CGFloat
    var navWidth: CGFloat         // target capsule width (hugs the controls)
    var navHeight: CGFloat        // 34
    var navSlot: CGFloat          // navIslandHeight + gap (43): panel-top travel
    var panelTopRadius: CGFloat
    var iconCount: Int = 5
    var iconSpacing: CGFloat = 40 // dot spread between adjacent icons at full spread
    /// Measured per-icon center offsets from the capsule's center. When set,
    /// dots spread from the cluster to EXACTLY these positions so every real
    /// icon sharpens out of its own dot; overrides iconCount/iconSpacing.
    var iconOffsets: [CGFloat] = []
    /// `-LiquidNavPink 1`: fill the metaball body fully-opaque hot pink (no glow
    /// tint, no fade) so the raw silhouette can be judged frame-by-frame. Phase-1
    /// geometry harness only; off in normal use.
    var debugPink: Bool = false

    // --- Tuning knobs (eyeball against the real notch) ---
    /// Body blur before thresholding. Bigger = fatter, lazier neck that bridges
    /// a wider gap and pinches later; smaller = thin neck that snaps sooner.
    static let bodyBlur: CGFloat = 6
    /// Body alpha cutoff. The mockup's feColorMatrix implies ~0.42 (8/19). The
    /// droplet is born merged with the panel, so there's no resting gap to
    /// bridge — 0.42 necks through the transition and the crisp cross-fade
    /// (e ∈ [0.9,1]) hides whatever web remains at the very end.
    static let bodyThreshold: Double = 0.42
    /// The icon dots are tiny; full-strength blur would dissolve them, so the
    /// dot pass runs a gentler blur with the same 8/19 cutoff. Small radii merge
    /// into one blob when clustered and separate cleanly as they spread.
    static let dotBlur: CGFloat = 3.5
    static let dotThreshold: Double = 0.42
    /// The island's material tone — a dark glass, near-opaque so a hint of the
    /// desktop still reads through. (Drawn directly, not masked over an
    /// NSVisualEffectView, which ignores masks and left the goo invisible.)
    static let fill = Color(red: 0.12, green: 0.13, blue: 0.155)
    /// The icon dots read as light (they become the white SF Symbols).
    static let dotFill = Color(white: 0.86)

    var body: some View {
        Canvas { ctx, size in
            let e = t
            let cx = size.width / 2

            // --- Choreography timings (all in eased e) ---
            // Headroom so the droplet can ride ABOVE its rest slot mid-flight
            // without the canvas top edge guillotining it flat (bulgeTop goes a
            // few pt negative around e≈0.5–0.85 — the reported top "cut off").
            // The hosting frame is taller + offset up by the same amount.
            let topPad: CGFloat = 18
            // The panel's top edge tracks 43·e and COVERS everything at/below it,
            // so only liquid rising ABOVE this line is ever seen.
            let panelTop = topPad + navSlot * CGFloat(e)
            // Shape rounds up over the first ~72% of travel (flat swell → droplet).
            let rise = smooth(0, 0.72, e)
            // The body DETACHES from the surface over the middle-to-late travel:
            // 0 = tucked into the panel (a merged swell), 1 = lifted clear at the
            // capsule slot. This is what makes a neck appear and then pinch.
            let detach = smooth(0.35, 0.92, e)

            // --- Droplet geometry ---
            // Born wider than the capsule and flat; narrows as it rounds up.
            // CLAMPED inside the canvas with blur headroom: an overwide pill is
            // guillotined by the canvas edge into flat vertical cuts with square
            // top corners (the reported "cut off") — the blur+threshold can only
            // round corners that actually fit in the layer.
            let bulgeW = min(navWidth * (1.28 - 0.28 * rise),
                             size.width - 2 * Self.bodyBlur - 16)
            // A 9pt swell grows to the full capsule height.
            let bulgeH = 9 + (navHeight - 9) * rise
            let radius = bulgeH / 2                    // droplet is a pill/circle
            // Droplet BOTTOM relative to the panel edge: tucked 12pt INTO the
            // surface while merged (only a low cap shows), lifting to 9pt CLEAR of
            // it (= navContentGap) once separated. The goo bridges the small
            // in-between gap into a neck; beyond the blur's reach it pinches off.
            let bottomRel = 12 - 21 * detach
            let bulgeBottom = panelTop + bottomRel
            let bulgeTop = bulgeBottom - bulgeH
            let centerY = bulgeBottom - bulgeH / 2

            let dropRect = CGRect(x: cx - bulgeW / 2, y: bulgeTop,
                                  width: bulgeW, height: bulgeH)
            // The panel's top mass. Lives behind the real panel; gives the swell
            // something to be part of at rest and the neck something to merge into.
            let panelRect = CGRect(x: cx - panelWidth / 2, y: panelTop,
                                   width: panelWidth, height: 60)

            // Neck: a narrow liquid column tying the lifting droplet back into the
            // surface. Grows in as the body clears the edge, thins to nothing at
            // pinch — a LOCALIZED neck instead of a full-width web.
            let neckIn = smooth(0.42, 0.7, e)
            let pinch = smooth(0.72, 0.95, e)
            let neckW = bulgeW * 0.5 * neckIn * (1 - pinch)
            let neckRect = CGRect(x: cx - neckW / 2, y: centerY,
                                  width: neckW, height: max(0, panelTop + 10 - centerY))

            // The fused metaball silhouette — droplet + neck + panel edge — drawn
            // white for both the debug flood and (as a clip mask) the glass. The
            // blur+threshold is what necks the overlap and rounds every corner.
            let bodyShapes: (inout GraphicsContext) -> Void = { layer in
                layer.fill(Path(roundedRect: panelRect, cornerRadius: panelTopRadius),
                           with: .color(.white))
                if neckW > 0.5 && neckRect.height > 0 {
                    layer.fill(Path(roundedRect: neckRect, cornerRadius: neckW / 2),
                               with: .color(.white))
                }
                layer.fill(Path(roundedRect: dropRect, cornerRadius: radius),
                           with: .color(.white))
            }

            if debugPink {
                // Phase-1 geometry harness: flood the raw silhouette flat hot pink.
                var bodyCtx = ctx
                bodyCtx.addFilter(.alphaThreshold(min: Self.bodyThreshold,
                                                  color: Color(red: 1.0, green: 0.08, blue: 0.58)))
                bodyCtx.addFilter(.blur(radius: Self.bodyBlur))
                bodyCtx.drawLayer(content: bodyShapes)
            } else {
                // --- Refractive Liquid Glass -------------------------------------
                // Styling lives STRICTLY mid-flight: `flight` is 0 at both ends and
                // peaks at e=0.5, so near rest the glass fades to nothing and the
                // crisp capsule cross-fade (NotchView, e∈[0.9,1]) takes over with no
                // brightness pop. Everything below is clipped to the metaball
                // silhouette, then lit like clear glass: a translucent body, an
                // inner luminance gradient (light bends through — brightest at the
                // droplet crown, darkening into the thick neck), a specular top rim,
                // and thin glints down the neck edges.
                let flight = 4 * e * (1 - e)
                let full = Path(CGRect(origin: .zero, size: size))

                // Clip all glass painting to the fused silhouette's alpha.
                var glass = ctx
                glass.clipToLayer { mask in
                    var m = mask
                    m.addFilter(.alphaThreshold(min: Self.bodyThreshold, color: .white))
                    m.addFilter(.blur(radius: Self.bodyBlur))
                    m.drawLayer(content: bodyShapes)
                }

                // 1. Base translucent glass — dark, lets a hint of desktop through.
                glass.fill(full, with: .color(Color(red: 0.10, green: 0.11, blue: 0.14)
                                                    .opacity(0.60)))
                // 2. Inner luminance gradient: cool light pooling at the crown,
                //    thinning through the middle, deepening (thickest liquid) at the
                //    base and neck.
                let crownLift = 0.34 + 0.34 * flight
                let lume = Gradient(stops: [
                    .init(color: Color(red: 0.66, green: 0.74, blue: 0.86).opacity(crownLift), location: 0.00),
                    .init(color: Color(red: 0.30, green: 0.35, blue: 0.44).opacity(0.24), location: 0.40),
                    .init(color: Color(red: 0.02, green: 0.03, blue: 0.05).opacity(0.40), location: 1.00),
                ])
                glass.fill(full, with: .linearGradient(lume,
                        startPoint: CGPoint(x: cx, y: bulgeTop),
                        endPoint: CGPoint(x: cx, y: bulgeBottom + 4)))
                // 3. Crown glow: a soft additive bloom just under the top surface,
                //    the refraction highlight where light gathers.
                var crown = glass
                crown.blendMode = .plusLighter
                crown.fill(full, with: .radialGradient(
                        Gradient(colors: [Color.white.opacity(0.22 + 0.20 * flight), .clear]),
                        center: CGPoint(x: cx, y: bulgeTop + radius * 0.55),
                        startRadius: 0, endRadius: max(6, bulgeW * 0.55)))

                // 4. Specular top rim — a crisp ~1.3pt highlight along the crown,
                //    fading down the shoulders. Drawn on the droplet's true top arc;
                //    the tucked lower ring hides behind the content panel.
                var rimCtx = ctx
                rimCtx.blendMode = .plusLighter
                let rimS = 0.55 + 0.35 * flight
                let rimGrad = Gradient(stops: [
                    .init(color: .white.opacity(rimS), location: 0.00),
                    .init(color: .white.opacity(rimS * 0.30), location: 0.26),
                    .init(color: .white.opacity(0.0), location: 0.60),
                ])
                rimCtx.stroke(Path(roundedRect: dropRect, cornerRadius: radius),
                        with: .linearGradient(rimGrad,
                                startPoint: CGPoint(x: cx, y: bulgeTop),
                                endPoint: CGPoint(x: cx, y: bulgeBottom)),
                        lineWidth: 1.3)

                // 5. Secondary glints: thin bright edges down the neck, where the
                //    curved column catches light.
                if neckW > 0.5 && neckRect.height > 0 {
                    var glint = ctx
                    glint.blendMode = .plusLighter
                    let gs = 0.30 * flight
                    let glintGrad = Gradient(stops: [
                        .init(color: .white.opacity(gs), location: 0.0),
                        .init(color: .white.opacity(0.0), location: 0.85),
                    ])
                    glint.stroke(Path(roundedRect: neckRect, cornerRadius: neckW / 2),
                            with: .linearGradient(glintGrad,
                                    startPoint: CGPoint(x: cx, y: centerY),
                                    endPoint: CGPoint(x: cx, y: neckRect.maxY)),
                            lineWidth: 0.9)
                }
            }

            // --- Icon melt: one light blob → five spreading dots → SF Symbols ---
            // The dots ride the droplet's center. They only exist once the body
            // has formed (appear) and dissolve as the real icons cross-fade in
            // (iconIn); the real icons themselves are drawn by NotchView.
            let appear = smooth(0.5, 0.68, e)
            let iconIn = smooth(0.84, 1, e)   // matches NotchView's icon fade-in window
            let dotsOpacity = appear * (1 - iconIn)
            if dotsOpacity > 0.001 {
                let spread = smooth(0.62, 0.9, e)  // clustered → spread apart
                let dotR = 5 - 1.5 * spread        // 5pt merged → 3.5pt distinct (user: smaller)
                var dotCtx = ctx
                dotCtx.opacity = Double(dotsOpacity)
                dotCtx.addFilter(.alphaThreshold(min: Self.dotThreshold, color: Self.dotFill))
                dotCtx.addFilter(.blur(radius: Self.dotBlur))
                dotCtx.drawLayer { layer in
                    // Cluster → each icon's REAL measured position (fallback:
                    // symmetric uniform spread until the first layout lands).
                    let mid = CGFloat(iconCount - 1) / 2
                    let offsets = !iconOffsets.isEmpty
                        ? iconOffsets
                        : (0..<iconCount).map { (CGFloat($0) - mid) * iconSpacing }
                    for off0 in offsets {
                        let off = off0 * spread
                        let d = CGRect(x: cx + off - dotR, y: centerY - dotR,
                                       width: dotR * 2, height: dotR * 2)
                        layer.fill(Path(ellipseIn: d), with: .color(.white))
                    }
                }
            }
        }
        .opacity(debugPink ? 1 : 0.95)
    }

    /// Smoothstep from e0→e1, clamped, returned as CGFloat.
    private func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> CGFloat {
        let d = e1 - e0
        guard d != 0 else { return x < e0 ? 0 : 1 }
        let tt = min(1, max(0, (x - e0) / d))
        return CGFloat(tt * tt * (3 - 2 * tt))
    }
}

/// Measures the nav controls' intrinsic width so the liquid capsule is sized to
/// hug them (the metaball needs a concrete blob width).
struct NavWidthKey: PreferenceKey {
    static var defaultValue: CGFloat = 220
    static func reduce(value: inout CGFloat, nextValue: () -> CGFloat) {
        value = max(value, nextValue())
    }
}
