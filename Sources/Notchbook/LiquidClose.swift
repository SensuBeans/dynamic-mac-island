import SwiftUI

/// "Surface Return" liquid for collapsing the expanded panel back into the notch
/// (motion study C4). The faithful reverse of the shipped nav bud: the panel's
/// TOP edge climbs toward the notch while the body narrows behind it — mass
/// arriving before the bottom lets go — and the goo necks it into the notch's
/// underside. One body, surface tension leading, nothing thrown.
///
/// This is the liquid STAND-IN: the real glass panel (VisualEffectBlur, which
/// can't be masked into a metaball) cross-fades out early in flight while this
/// panel-toned body carries the travel, converging to black as it nears the
/// notch. On open it runs in reverse and the crisp panel cross-fades back in over
/// the last stretch. The nav capsule's melt is the shipped LiquidNav (navT→0),
/// chained as the opening beat — this view never draws it.
///
/// Content rows liquefy into staggered dots that accelerate up into the arriving
/// mass (the panel's analogue of the icon-melt).
///
/// `t` is eased close progress (`closeT`): 0 = fully expanded, 1 = collapsed.
struct LiquidClose: View, Animatable {
    var t: Double
    var animatableData: Double {
        get { t }
        set { t = newValue }
    }

    var notchWidth: CGFloat
    var notchHeight: CGFloat
    var gap: CGFloat               // islandGap (notch → nav)
    var navHeight: CGFloat
    var navContentGap: CGFloat
    var panelWidth: CGFloat
    var panelHeight: CGFloat
    var debugPink: Bool = false

    // Hosting-frame padding (NotchView must match): the canvas spans the notch
    // down to the panel bottom, with blur headroom on the sides + bottom.
    static let hPad: CGFloat = 26        // ≈ 2·bodyBlur + headroom for the wide panel
    static let botPad: CGFloat = 24
    static let bodyBlur: CGFloat = 7
    static let bodyThreshold: Double = 0.42
    static let dotBlur: CGFloat = 3.5
    static let dotThreshold: Double = 0.42
    static let dotFill = Color(white: 0.83)
    /// The panel material's solid stand-in tone (matches the glass at the handoff).
    static let panelTone = Color(red: 0.11, green: 0.12, blue: 0.15)

    var body: some View {
        Canvas { ctx, size in
            let e = t
            let cx = size.width / 2

            // Rest layout (canvas space, y=0 at the notch's top edge).
            let panelTopRest = notchHeight + gap + navHeight + navContentGap
            let panelBotRest = panelTopRest + panelHeight

            // --- C4 body geometry (mock: closeStudies[C4].render) ---
            let topY = lerp(panelTopRest, notchHeight - 5, smooth(0.24, 0.72, e))
            // The bottom edge ends fully INSIDE the notch (−2, not +9): the mass
            // must geometrically disappear into the silhouette by e≈0.96 so the
            // final opacity swap has nothing visible left to fade — a bottom that
            // floors below the notch leaves a black lip that can only ghost out
            // (the user-flagged ".95 frame").
            let botY = lerp(panelBotRest, notchHeight - 2, smooth(0.4, 0.96, e))
            // Width likewise tucks INSIDE the notch by the end — wider-than-notch
            // leaves nubs sticking out under its corners after absorption.
            let w = lerp(panelWidth, notchWidth - 6, smooth(0.42, 0.96, e))
            let h = max(5, botY - topY)
            let panelRect = CGRect(x: cx - w / 2, y: topY, width: w, height: h)
            let panelCorner = min(22, h / 2)
            let notchFrame = CGRect(x: cx - notchWidth / 2, y: 0,
                                    width: notchWidth, height: notchHeight)

            let bodyShapes: (inout GraphicsContext) -> Void = { layer in
                // The notch (real silhouette) so the panel necks into the true
                // underside; it never deforms — the liquid meets it.
                layer.fill(NotchShape(topRadius: NotchMetrics.topFlare, bottomRadius: 10)
                            .path(in: notchFrame), with: .color(.white))
                // Once the mass is fully absorbed (a sliver hidden inside the
                // notch), its blur still bleeds around the notch and DILATES the
                // fused silhouette — a fat halo-notch that can only fade out
                // (the "slowly fading instead of morphing" ending). Drop the blob
                // from the body at that point: the silhouette becomes the notch
                // alone, pixel-matching the real one, so the final swap is
                // invisible and the ending reads as pure absorption.
                if h > 6 || w > notchWidth {
                    layer.fill(Path(roundedRect: panelRect, cornerRadius: panelCorner),
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

            // Fuse notch + panel into one liquid silhouette, then paint it with a
            // vertical tone: black at the notch (top), panel-tone at the resting
            // panel bottom. As the body climbs, only its darkening upper reach
            // shows — it reads as sinking into the black notch.
            var body = ctx
            body.clipToLayer { mask in
                var m = mask
                m.addFilter(.alphaThreshold(min: Self.bodyThreshold, color: .white))
                m.addFilter(.blur(radius: Self.bodyBlur))
                m.drawLayer(content: bodyShapes)
            }
            // Fill: black at the notch (top), panel-tone at the resting bottom —
            // AND the whole body converges to pure black as it approaches the
            // notch (mock's panel-tone → black), so by contact the liquid and the
            // notch are one material and the merge reads as a single body, never a
            // separately-tinted slab fading in.
            let darken = Double(smooth(0.5, 0.9, e))    // panel-tone → black, done BEFORE the tuck
            let k = 1 - darken
            let bottomTone = Color(red: 0.11 * k, green: 0.12 * k, blue: 0.15 * k)
            let tone = Gradient(stops: [
                .init(color: .black, location: 0.0),
                .init(color: bottomTone, location: 1.0),
            ])
            body.fill(Path(CGRect(origin: .zero, size: size)),
                      with: .linearGradient(tone,
                          startPoint: CGPoint(x: cx, y: notchHeight),
                          endPoint: CGPoint(x: cx, y: panelBotRest)))

            // No content-row dot-melt on the expanded island (per review): the
            // panel content cross-fades out and the liquid body carries the whole
            // collapse into the notch — no dots ride up.
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
