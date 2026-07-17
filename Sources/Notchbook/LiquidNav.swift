import SwiftUI

/// "Goo Merge" liquid for the nav bar: the nav capsule buds up out of the
/// content panel's top edge, joined by a metaball neck that stretches and
/// pinches off as it separates (and re-fuses when it retracts). The chosen
/// motion study from the liquid-nav gallery.
///
/// Technique: the classic metaball — draw two rounded-rect blobs into a Canvas
/// layer, `.blur` them so their alpha bleeds together, then `.alphaThreshold`
/// to snap the fused alpha back to a hard silhouette (the overlap becomes a
/// liquid neck). We use that silhouette as a MASK over the island's real glass
/// material, so the nav + neck are the same translucent glass as everything
/// else — not a flat fill.
///
/// `t` is reveal progress: 0 = nav fully absorbed into the panel's top edge,
/// 1 = nav is a separate capsule floating in the gap. The panel-top blob sits
/// BEHIND the real content panel, so only the neck rising off it ever shows.
struct LiquidNav: View {
    var t: Double
    var panelWidth: CGFloat
    var navWidth: CGFloat
    var navHeight: CGFloat
    var navSlot: CGFloat          // navIslandHeight + gap: how far the panel top
                                  // sits below this view's top when fully shown
    var panelTopRadius: CGFloat

    // --- Tuning knobs (eyeball against the real notch) ---
    /// Blur before thresholding. Bigger = fatter, lazier neck that bridges a
    /// wider gap and pinches later; smaller = thin neck that snaps sooner.
    static let blur: CGFloat = 6
    /// Alpha cutoff. Higher = tighter silhouette + cleaner pinch (less bridging
    /// across the resting gap); lower = gooier, stays connected longer. The
    /// mockup's feColorMatrix implies ~0.42 (8/19), but at our real 9pt resting
    /// gap that leaves a broad web that never fully pinches; 0.52 lands a clean
    /// separated capsule at rest while still necking through the transition.
    static let threshold: Double = 0.52
    /// The island's material tone — a dark glass, near-opaque so a hint of the
    /// desktop still reads through. (Drawn directly, not masked over an
    /// NSVisualEffectView, which ignores masks and left the goo invisible.)
    static let fill = Color(red: 0.12, green: 0.13, blue: 0.155)

    var body: some View {
        Canvas { ctx, size in
            let e = t
            let cx = size.width / 2
            let panelTop = navSlot * CGFloat(e)

            // Nav blob — the budding droplet. Starts as a thin sliver merged with
            // the panel edge and grows to the full capsule; narrows a touch while
            // budding so it reads as a droplet forming, not a bar sliding.
            let navH = 8 + (navHeight - 8) * smoothstep(0.05, 1, e)
            let navW = navWidth * (0.74 + 0.26 * CGFloat(min(1, e)))
            let navCY = navHeight / 2
            let navRect = CGRect(x: cx - navW / 2, y: navCY - navH / 2,
                                 width: navW, height: navH)

            // Panel-top blob — the parent drop's top edge. Lives behind the real
            // panel; its only visible contribution is the neck rising toward the
            // nav blob. Its top tracks the panel as it shifts down.
            let panelRect = CGRect(x: cx - panelWidth / 2, y: panelTop,
                                   width: panelWidth, height: 46)

            // Metaball: blur both blobs so their alpha bleeds together, then
            // alphaThreshold to snap the fused alpha into a hard liquid
            // silhouette filled with the island tone (the overlap = the neck).
            ctx.addFilter(.alphaThreshold(min: Self.threshold, color: Self.fill))
            ctx.addFilter(.blur(radius: Self.blur))
            ctx.drawLayer { layer in
                layer.fill(Path(roundedRect: panelRect, cornerRadius: panelTopRadius),
                           with: .color(.white))
                layer.fill(Path(roundedRect: navRect, cornerRadius: min(navH / 2, 16)),
                           with: .color(.white))
            }
        }
        .opacity(0.95)
    }

    private func smoothstep(_ e0: Double, _ e1: Double, _ x: Double) -> CGFloat {
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

