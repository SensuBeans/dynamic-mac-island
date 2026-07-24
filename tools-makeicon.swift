import AppKit
import CoreGraphics
import Foundation

// Final "Dynamic Island" app icon — variant 1 (Graphite), camera dot removed.
// Re-rendered natively at every iconset size (not downsampled) so the small
// sizes stay crisp. Usage: swift makeicns.swift <outputIconsetDir>

let outDir = CommandLine.arguments.count > 1
    ? CommandLine.arguments[1]
    : FileManager.default.currentDirectoryPath

func ctx(_ s: Int) -> CGContext {
    CGContext(data: nil, width: s, height: s, bitsPerComponent: 8, bytesPerRow: 0,
              space: CGColorSpace(name: CGColorSpace.sRGB)!,
              bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
}
func rgb(_ r: Double, _ g: Double, _ b: Double, _ a: Double = 1) -> CGColor {
    CGColor(srgbRed: r/255, green: g/255, blue: b/255, alpha: a)
}
func squircle(_ rect: CGRect, _ radius: CGFloat) -> CGPath {
    CGPath(roundedRect: rect, cornerWidth: radius, cornerHeight: radius, transform: nil)
}
func linearGradient(_ c: CGContext, _ colors: [CGColor], _ locs: [CGFloat],
                    from: CGPoint, to: CGPoint) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                       colors: colors as CFArray, locations: locs)!
    c.drawLinearGradient(g, start: from, end: to,
                         options: [.drawsBeforeStartLocation, .drawsAfterEndLocation])
}
func radialGlow(_ c: CGContext, center: CGPoint, radius: CGFloat, color: CGColor) {
    let g = CGGradient(colorsSpace: CGColorSpace(name: CGColorSpace.sRGB)!,
                       colors: [color, color.copy(alpha: 0)!] as CFArray, locations: [0, 1])!
    c.drawRadialGradient(g, startCenter: center, startRadius: 0,
                         endCenter: center, endRadius: radius, options: [])
}

func drawIcon(size s: Int) -> CGImage {
    let c = ctx(s)
    let S = CGFloat(s)
    let body = CGRect(x: 0, y: 0, width: S, height: S).insetBy(dx: S*0.055, dy: S*0.055)
    let radius = body.width * 0.2237

    c.saveGState()
    c.addPath(squircle(body, radius))
    c.clip()

    // Graphite gradient + cool blue bloom behind the island (the liquid glow).
    linearGradient(c, [rgb(58, 60, 68), rgb(20, 21, 26), rgb(10, 10, 13)], [0, 0.55, 1],
                   from: CGPoint(x: 0, y: S), to: CGPoint(x: 0, y: 0))
    radialGlow(c, center: CGPoint(x: S/2, y: S*0.46), radius: S*0.42,
               color: rgb(90, 160, 255, 0.38))

    // Glassy top sheen.
    linearGradient(c, [rgb(255, 255, 255, 0.16), rgb(255, 255, 255, 0.0)], [0, 1],
                   from: CGPoint(x: 0, y: S), to: CGPoint(x: 0, y: S*0.62))

    // The island: a clean black pill (no camera dot).
    let w = S * 0.52, h = S * 0.175
    let pill = CGRect(x: (S - w)/2, y: S*0.50 - h/2, width: w, height: h)
    let pillR = pill.height/2
    c.setShadow(offset: CGSize(width: 0, height: -S*0.008), blur: S*0.05,
                color: rgb(0, 0, 0, 0.55))
    c.addPath(squircle(pill, pillR))
    c.setFillColor(rgb(6, 6, 8))
    c.fillPath()
    c.setShadow(offset: .zero, blur: 0, color: nil)
    // Faint rim so it reads as glass, not a punched hole. Skipped at tiny sizes
    // where a hairline just muddies the silhouette.
    if s >= 64 {
        c.addPath(squircle(pill.insetBy(dx: S*0.0035, dy: S*0.0035), pillR))
        c.setStrokeColor(rgb(255, 255, 255, 0.16))
        c.setLineWidth(max(1, S*0.004))
        c.strokePath()
    }

    c.restoreGState()
    return c.makeImage()!
}

func writePNG(_ img: CGImage, _ path: String) {
    let rep = NSBitmapImageRep(cgImage: img)
    try! rep.representation(using: .png, properties: [:])!.write(to: URL(fileURLWithPath: path))
}

// Standard macOS iconset matrix.
let sizes: [(name: String, px: Int)] = [
    ("icon_16x16",      16), ("icon_16x16@2x",    32),
    ("icon_32x32",      32), ("icon_32x32@2x",    64),
    ("icon_128x128",   128), ("icon_128x128@2x", 256),
    ("icon_256x256",   256), ("icon_256x256@2x", 512),
    ("icon_512x512",   512), ("icon_512x512@2x", 1024),
]
try? FileManager.default.createDirectory(atPath: outDir, withIntermediateDirectories: true)
for (name, px) in sizes {
    writePNG(drawIcon(size: px), "\(outDir)/\(name).png")
}
print("wrote \(sizes.count) sizes to \(outDir)")
