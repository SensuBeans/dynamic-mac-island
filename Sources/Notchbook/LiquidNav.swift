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
struct LiquidNav: View {
    var t: Double
    var panelWidth: CGFloat
    var navWidth: CGFloat         // target capsule width (hugs the controls)
    var navHeight: CGFloat        // 34
    var navSlot: CGFloat          // navIslandHeight + gap (43): panel-top travel
    var panelTopRadius: CGFloat
    var iconCount: Int = 5
    var iconSpacing: CGFloat = 40 // dot spread between adjacent icons at full spread

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
            let rise = smooth(0, 0.85, e)     // surface swells & rounds up
            let lift = smooth(0.55, 1, e)     // body migrates off the surface
            let panelTop = navSlot * CGFloat(e)   // real panel-top tracks 43·e

            // --- Droplet geometry ---
            // Born 25% WIDER than the capsule and flat; narrows as it rounds up.
            let bulgeW = navWidth * (1.25 - 0.25 * rise)
            // 10pt swell → full capsule height.
            let bulgeH = 10 + (navHeight - 10) * rise
            // The droplet's TOP. On the surface it protrudes above the panel edge
            // by bulgeH·rise (rise 0 = flush/flat, rise 1 = fully out); then it
            // migrates up to the capsule slot (top = 0) over lift.
            let surfaceTop = panelTop - bulgeH * rise
            let bulgeTop = surfaceTop * (1 - lift)   // slotTop = 0
            let centerY = bulgeTop + bulgeH / 2
            let radius = bulgeH / 2                    // droplet is a pill/circle

            let dropRect = CGRect(x: cx - bulgeW / 2, y: bulgeTop,
                                  width: bulgeW, height: bulgeH)
            // The parent drop's top edge. Lives behind the real panel; only its
            // neck rising toward the droplet ever shows. Tall enough to read as a
            // solid mass at every frame.
            let panelRect = CGRect(x: cx - panelWidth / 2, y: panelTop,
                                   width: panelWidth, height: 60)

            // In flight the liquid catches light — dark glass on a dark desktop
            // reads as nothing, so the droplet + neck are lifted toward a lit
            // mercury tone that peaks mid-morph and fades out before the crisp
            // glass capsule cross-fades in (so there's no brightness pop at rest).
            let glow = (4 * e * (1 - e)) * (1 - Double(smooth(0.8, 1, e)))
            let g = CGFloat(glow)
            let flightFill = Color(red: 0.12 + 0.16 * g,
                                   green: 0.13 + 0.16 * g,
                                   blue: 0.155 + 0.17 * g)

            // --- Body metaball: droplet + neck + panel edge, one fused blob ---
            var bodyCtx = ctx
            bodyCtx.addFilter(.alphaThreshold(min: Self.bodyThreshold, color: flightFill))
            bodyCtx.addFilter(.blur(radius: Self.bodyBlur))
            bodyCtx.drawLayer { layer in
                layer.fill(Path(roundedRect: panelRect, cornerRadius: panelTopRadius),
                           with: .color(.white))
                layer.fill(Path(roundedRect: dropRect, cornerRadius: radius),
                           with: .color(.white))
            }

            // --- Icon melt: one light blob → five spreading dots → SF Symbols ---
            // The dots ride the droplet's center. They only exist once the body
            // has formed (appear) and dissolve as the real icons cross-fade in
            // (iconIn); the real icons themselves are drawn by NotchView.
            let appear = smooth(0.5, 0.68, e)
            let iconIn = smooth(0.88, 1, e)
            let dotsOpacity = appear * (1 - iconIn)
            if dotsOpacity > 0.001 {
                let spread = smooth(0.62, 0.9, e)  // clustered → spread apart
                let dotR = 7 - 2 * spread          // 7pt merged → 5pt distinct
                var dotCtx = ctx
                dotCtx.opacity = Double(dotsOpacity)
                dotCtx.addFilter(.alphaThreshold(min: Self.dotThreshold, color: Self.dotFill))
                dotCtx.addFilter(.blur(radius: Self.dotBlur))
                dotCtx.drawLayer { layer in
                    let mid = iconCount / 2
                    for i in 0..<iconCount {
                        let off = CGFloat(i - mid) * iconSpacing * spread
                        let d = CGRect(x: cx + off - dotR, y: centerY - dotR,
                                       width: dotR * 2, height: dotR * 2)
                        layer.fill(Path(ellipseIn: d), with: .color(.white))
                    }
                }
            }
        }
        .opacity(0.95)
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
