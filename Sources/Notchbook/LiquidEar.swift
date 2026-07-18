import SwiftUI

/// "Side Bulge" liquid for the collapsed media ear (motion study E1). When music
/// starts, the notch's right flank swells sideways under surface tension — a low
/// horizontal bulge, born ~9pt tall and vertically centered — that rounds into
/// the full ear pill, staying ONE continuous black body with the notch the whole
/// way. On hide it runs in exact reverse.
///
/// Technique is the shipped nav metaball (see LiquidNav): the notch silhouette
/// and the growing ear blob are drawn into one blurred+thresholded layer so their
/// alphas fuse into a single liquid outline (the overlap at the seam becomes the
/// neck). The body is filled PURE BLACK so mid-flight it is indistinguishable
/// from the real notch; at rest the goo is gone and NotchView's real backing +
/// crisp ear content have cross-faded in (crisp-at-rest rule).
///
/// A second, gentler metaball pass carries the content dot-melt: two light dots
/// (album thumb + equalizer cluster) bud at the notch seam and slide to their
/// measured content positions, then dissolve as the real views sharpen in.
///
/// `t` is eased reveal progress (`earT`): 0 = bare notch, 1 = ear resting.
struct LiquidEar: View, Animatable {
    var t: Double

    /// Relay `t` through the animation transaction so the Canvas re-renders every
    /// intermediate value. Without this, `withAnimation` hands the Canvas only the
    /// END value and the morph never draws one live frame (see LiquidNav).
    var animatableData: Double {
        get { t }
        set { t = newValue }
    }

    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var earWidth: CGFloat          // resting ear extension (mediaEarWidth)
    /// `-LiquidEarPink 1`: flood the raw fused silhouette flat hot pink so the
    /// geometry can be judged frame-by-frame. Off in normal use.
    var debugPink: Bool = false

    // Layout padding baked into the hosting frame (NotchView must match).
    static let vPadTop: CGFloat = 6
    static let vPadBottom: CGFloat = 10
    static let rightPad: CGFloat = 20   // ≈ 2·bodyBlur + headroom for the ear cap

    // --- Tuning knobs (mirror LiquidNav's 8/19 metaball family) ---
    static let bodyBlur: CGFloat = 5
    static let bodyThreshold: Double = 0.42

    var body: some View {
        Canvas { ctx, size in
            let e = t
            let leftInset: CGFloat = 0
            let notchFrame = CGRect(x: leftInset, y: Self.vPadTop,
                                    width: notchWidth, height: notchHeight)
            let notchRight = leftInset + notchWidth
            let cy = Self.vPadTop + notchHeight / 2

            // --- E1 ear blob geometry (mock: earStudies[E1].render) ---
            // rise rounds the swell up over the first ~75% of travel; the blob is
            // born 9pt tall and grows to the full notch height; its width tracks
            // the ear extension. The rect starts 6pt INTO the notch so the two
            // bodies overlap and the blur+threshold necks them into one silhouette.
            let rise = smooth(0, 0.75, e)
            let w = earWidth * rise
            let h = lerp(9, notchHeight, smooth(0.1, 0.8, e))
            let earRect = CGRect(x: notchRight - 6, y: cy - h / 2,
                                 width: w + 6, height: h)

            let bodyShapes: (inout GraphicsContext) -> Void = { layer in
                // The notch itself: the REAL NotchShape so the visible bottom edge
                // + corners match the shipped backing exactly (the top sits over
                // the hardware cutout, so only the lower silhouette reads).
                layer.fill(NotchShape(topRadius: NotchMetrics.topFlare, bottomRadius: 10)
                            .path(in: notchFrame), with: .color(.white))
                if earRect.width > 0.5 {
                    layer.fill(Path(roundedRect: earRect,
                                    cornerRadius: min(h / 2, earRect.width / 2)),
                               with: .color(.white))
                }
            }

            // Fuse into one liquid silhouette. Filters compose content-first, so
            // blur (added last) runs before the threshold (added first): the alphas
            // bleed together, then snap to a hard edge — the classic metaball.
            var bodyCtx = ctx
            let bodyColor = debugPink ? Color(red: 1.0, green: 0.08, blue: 0.58) : Color.black
            bodyCtx.addFilter(.alphaThreshold(min: Self.bodyThreshold, color: bodyColor))
            bodyCtx.addFilter(.blur(radius: Self.bodyBlur))
            bodyCtx.drawLayer(content: bodyShapes)
            // No content dot-melt in the ear (per review): the black body swells
            // into the ear pill and the real album/EQ views simply cross-fade in
            // at rest (NotchView's ear-content `iconIn` window).
        }
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    /// Smoothstep e0→e1, clamped, as CGFloat (matches the mock's `smooth`).
    private func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> CGFloat {
        let d = e1 - e0
        guard d != 0 else { return x < e0 ? 0 : 1 }
        let tt = min(1, max(0, (x - e0) / d))
        return CGFloat(tt * tt * (3 - 2 * tt))
    }
}
