import SwiftUI

/// Liquid reveal for the collapsed agent-status pill — the same surface-tension
/// morph as the media ear (E1), but ending in a DETACHED capsule the way the nav
/// bud does (LiquidNav's pinch). Mass swells out of the nearest island body — the
/// media ear's right cap when music is playing, otherwise the notch's right flank
/// — extends rightward on a liquid neck, bulges into the capsule at the pill's
/// exact rest rect, and the neck pinches off so the capsule floats free.
///
/// Technique is the shipped metaball (see LiquidNav/LiquidEar): the donor
/// silhouette, the traveling capsule, and the connecting neck are drawn into one
/// blurred + alpha-thresholded layer so their alphas fuse into a single liquid
/// outline (the overlap is the neck; when the neck thins past the blur's reach it
/// pinches). The donor half is painted black (indistinguishable from the real
/// notch/ear it overlays); the capsule half is the pill's dark-glass tone and
/// cross-fades into the real `AgentPillLabel` over the last stretch (crisp-at-rest
/// rule). The glyph + count are carried by two melt dots (tinted glyph, light
/// count) that bud at the seam and sharpen into the real label at the end.
///
/// `t` is eased reveal progress (`agentT`): 0 = absorbed into the island body,
/// 1 = the detached pill resting. It runs in exact reverse on hide.
struct LiquidAgent: View, Animatable {
    var t: Double
    var animatableData: Double {
        get { t }
        set { t = newValue }
    }

    var notchWidth: CGFloat
    var notchHeight: CGFloat
    /// Media-ear extension when the ear is the donor; 0 → donor is the notch flank.
    var earWidth: CGFloat
    var hasEar: Bool
    /// The pill's resting capsule rect, MEASURED from the real `AgentPillLabel` in
    /// this Canvas's coordinate space (island top-left, before the `-vPadTop`
    /// offset is applied — this view re-adds it). The morph targets this exactly,
    /// so at e=1 the goo silhouette is pixel-congruent with the real capsule.
    var pillRect: CGRect
    /// Measured glyph-center and count-center x within the pill (island space).
    /// `nil` → symmetric fallback inside `pillRect`.
    var glyphCenterX: CGFloat?
    var countCenterX: CGFloat?
    /// The pill's state tint (orange waiting / blue working / green complete) —
    /// the glyph melt-dot is born already colored.
    var tint: Color
    /// `-LiquidAgentPink 1`: flood the fused silhouette flat pink for geometry
    /// tuning; no tone, no dots, no cross-fade.
    var debugPink: Bool = false

    // Hosting-frame padding (NotchView must match): headroom so the capsule's
    // rounded top/bottom + the ear cap never clip against the canvas edge.
    static let vPadTop: CGFloat = 6
    static let vPadBottom: CGFloat = 10
    static let rightPad: CGFloat = 20

    // Metaball family (mirrors LiquidEar's 5/0.42 body + 3/0.42 dots).
    static let bodyBlur: CGFloat = 5
    static let bodyThreshold: Double = 0.42
    static let dotBlur: CGFloat = 3
    static let dotThreshold: Double = 0.42
    /// Dark-glass capsule tone — matches the pill's VisualEffectBlur + black 0.4.
    static let glassTone = Color(red: 0.12, green: 0.13, blue: 0.155)

    var body: some View {
        Canvas { ctx, size in
            let e = t
            let vTop = Self.vPadTop

            // --- Donor geometry (island space y shifted into canvas by +vTop) ---
            let notchFrame = CGRect(x: 0, y: vTop, width: notchWidth, height: notchHeight)
            let cy = pillRect.midY + vTop          // capsule rides the pill's center line
            let donorRightX = notchWidth + (hasEar ? earWidth : 0)
            // Full ear cap (matches the resting media-ear silhouette) so the neck
            // buds off the real body edge, not a bare notch corner.
            let earRect = CGRect(x: notchWidth - 6, y: vTop,
                                 width: earWidth + 6, height: notchHeight)

            // --- Traveling capsule: seed at the seam → the pill's rest rect ---
            let targetW = pillRect.width
            let targetH = pillRect.height
            let targetCX = pillRect.midX
            let grow = smooth(0.08, 0.82, e)
            let slide = smooth(0.12, 0.90, e)
            let dropW = lerp(10, targetW, grow)
            let dropH = lerp(9, targetH, smooth(0.08, 0.75, e))
            let dropCX = lerp(donorRightX + 6, targetCX, slide)
            let dropRect = CGRect(x: dropCX - dropW / 2, y: cy - dropH / 2,
                                  width: dropW, height: dropH)
            let dropCorner = dropH / 2

            // --- Neck: a horizontal liquid column tying the capsule to the donor,
            // thinning to nothing at pinch (the detachment). ---
            let neckIn = smooth(0.20, 0.52, e)
            let pinch = smooth(0.70, 0.96, e)
            let neckThick = min(dropH, targetH) * 0.55 * neckIn * (1 - pinch)
            let neckLeft = donorRightX - 4
            let neckRight = dropRect.minX + 4
            let neckRect = CGRect(x: neckLeft, y: cy - neckThick / 2,
                                  width: max(0, neckRight - neckLeft), height: neckThick)

            let bodyShapes: (inout GraphicsContext) -> Void = { layer in
                // Donor mass (hidden-congruent with the real notch/ear it overlays).
                layer.fill(NotchShape(topRadius: NotchMetrics.topFlare, bottomRadius: 10)
                            .path(in: notchFrame), with: .color(.white))
                if hasEar {
                    layer.fill(Path(roundedRect: earRect,
                                    cornerRadius: min(notchHeight / 2, earRect.width / 2)),
                               with: .color(.white))
                }
                if neckThick > 0.5 && neckRect.width > 0 {
                    layer.fill(Path(roundedRect: neckRect, cornerRadius: neckThick / 2),
                               with: .color(.white))
                }
                if dropW > 0.5 {
                    layer.fill(Path(roundedRect: dropRect, cornerRadius: dropCorner),
                               with: .color(.white))
                }
            }

            if debugPink {
                var b = ctx
                b.addFilter(.alphaThreshold(min: Self.bodyThreshold,
                                            color: Color(red: 1.0, green: 0.08, blue: 0.58)))
                b.addFilter(.blur(radius: Self.bodyBlur))
                b.drawLayer(content: bodyShapes)
                return
            }

            // Fuse into one silhouette, then paint it: black at the donor (left),
            // dark-glass at the capsule (right). Where there's a real black
            // backing (notch/ear) the black half is invisibly coincident; the
            // glass half floats over the desktop as the detached pill.
            var bodyCtx = ctx
            bodyCtx.clipToLayer { mask in
                var m = mask
                m.addFilter(.alphaThreshold(min: Self.bodyThreshold, color: .white))
                m.addFilter(.blur(radius: Self.bodyBlur))
                m.drawLayer(content: bodyShapes)
            }
            let tone = Gradient(stops: [
                .init(color: .black, location: 0.0),
                .init(color: Self.glassTone, location: 1.0),
            ])
            bodyCtx.fill(Path(CGRect(origin: .zero, size: size)),
                         with: .linearGradient(tone,
                             startPoint: CGPoint(x: donorRightX, y: cy),
                             endPoint: CGPoint(x: pillRect.minX, y: cy)))
            // A faint capsule top-rim so the glass reads as lit, fading with flight.
            let flight = 4 * e * (1 - e)
            if dropRect.width > 6 {
                var rim = ctx
                rim.blendMode = .plusLighter
                let rs = 0.16 + 0.18 * flight
                rim.stroke(Path(roundedRect: dropRect, cornerRadius: dropCorner),
                           with: .color(.white.opacity(rs)), lineWidth: 0.75)
            }

            // --- Glyph + count melt dots: bud at the capsule as it forms, spread
            // to the label positions, dissolve as the real label sharpens in. ---
            let appear = smooth(0.48, 0.68, e)
            let iconIn = smooth(0.84, 1, e)
            let dotsOpacity = Double(appear) * (1 - Double(iconIn))
            if dotsOpacity > 0.001 {
                let spread = smooth(0.58, 0.9, e)
                let gTarget = (glyphCenterX ?? (targetCX - 7))
                let cTarget = (countCenterX ?? (targetCX + 7))
                let gx = lerp(dropCX, gTarget, spread)
                let cx = lerp(dropCX, cTarget, spread)
                let gr = (3.2 - 0.3 * spread) * grow
                let cr = (2.7 - 0.3 * spread) * grow
                // Glyph dot — tinted; born already the pill's state color.
                drawDot(ctx, x: gx, y: cy, r: gr, color: tint, opacity: dotsOpacity)
                // Count dot — light; becomes the white numerals.
                drawDot(ctx, x: cx, y: cy, r: cr, color: Color(white: 0.92), opacity: dotsOpacity)
            }
        }
    }

    private func drawDot(_ ctx: GraphicsContext, x: CGFloat, y: CGFloat, r: CGFloat,
                         color: Color, opacity: Double) {
        guard r > 0.2 else { return }
        var c = ctx
        c.opacity = opacity
        c.addFilter(.alphaThreshold(min: Self.dotThreshold, color: color))
        c.addFilter(.blur(radius: Self.dotBlur))
        c.drawLayer { layer in
            layer.fill(Path(ellipseIn: CGRect(x: x - r, y: y - r, width: r * 2, height: r * 2)),
                       with: .color(.white))
        }
    }

    private func lerp(_ a: CGFloat, _ b: CGFloat, _ t: CGFloat) -> CGFloat { a + (b - a) * t }

    private func smooth(_ e0: Double, _ e1: Double, _ x: Double) -> CGFloat {
        let d = e1 - e0
        guard d != 0 else { return x < e0 ? 0 : 1 }
        let tt = min(1, max(0, (x - e0) / d))
        return CGFloat(tt * tt * (3 - 2 * tt))
    }
}

/// Measured pill geometry (capsule rest frame + glyph/count center-x) in the
/// collapsed island's coordinate space — the agent pill's analogue of
/// `NavIconCentersKey` / `EarContentCentersKey`.
struct AgentPillFrameKey: PreferenceKey {
    static var defaultValue: CGRect = .zero
    static func reduce(value: inout CGRect, nextValue: () -> CGRect) {
        let n = nextValue()
        if n != .zero { value = n }
    }
}
