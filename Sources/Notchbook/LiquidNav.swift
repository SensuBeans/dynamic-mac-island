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
            // The panel's top edge tracks 43·e and COVERS everything at/below it,
            // so only liquid rising ABOVE this line is ever seen.
            let panelTop = navSlot * CGFloat(e)
            // Shape rounds up over the first ~72% of travel (flat swell → droplet).
            let rise = smooth(0, 0.72, e)
            // The body DETACHES from the surface over the middle-to-late travel:
            // 0 = tucked into the panel (a merged swell), 1 = lifted clear at the
            // capsule slot. This is what makes a neck appear and then pinch.
            let detach = smooth(0.35, 0.92, e)

            // --- Droplet geometry ---
            // Born 28% WIDER than the capsule and flat; narrows as it rounds up.
            let bulgeW = navWidth * (1.28 - 0.28 * rise)
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

            // In flight the liquid catches light — dark glass on a dark desktop
            // reads as nothing, so the droplet + neck are lifted toward a lit
            // mercury tone that peaks mid-morph and fades out before the crisp
            // glass capsule cross-fades in (so there's no brightness pop at rest).
            let glow = (4 * e * (1 - e)) * (1 - Double(smooth(0.8, 1, e)))
            let g = CGFloat(glow)
            let flightFill = debugPink
                ? Color(red: 1.0, green: 0.08, blue: 0.58)   // Phase-1 harness
                : Color(red: 0.12 + 0.16 * g,
                        green: 0.13 + 0.16 * g,
                        blue: 0.155 + 0.17 * g)

            // --- Body metaball: droplet + neck + panel edge, one fused blob ---
            var bodyCtx = ctx
            bodyCtx.addFilter(.alphaThreshold(min: Self.bodyThreshold, color: flightFill))
            bodyCtx.addFilter(.blur(radius: Self.bodyBlur))
            bodyCtx.drawLayer { layer in
                layer.fill(Path(roundedRect: panelRect, cornerRadius: panelTopRadius),
                           with: .color(.white))
                if neckW > 0.5 && neckRect.height > 0 {
                    layer.fill(Path(roundedRect: neckRect, cornerRadius: neckW / 2),
                               with: .color(.white))
                }
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
