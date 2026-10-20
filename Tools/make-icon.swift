// Renders the Ring app icon into an .iconset folder. Usage: swift make-icon.swift <out.iconset> [preview.png]
// Look: six frosted-glass fan pieces of a ring and a glass dot over a graphite tile lit by a warm
// glow from behind — Liquid Glass style, no blue.
import AppKit

let out = URL(fileURLWithPath: CommandLine.arguments[1])
try? FileManager.default.createDirectory(at: out, withIntermediateDirectories: true)

func color(_ r: CGFloat, _ g: CGFloat, _ b: CGFloat, _ a: CGFloat = 1) -> CGColor {
    CGColor(srgbRed: r, green: g, blue: b, alpha: a)
}

func render(_ px: Int) -> Data {
    let cs = CGColorSpace(name: CGColorSpace.sRGB)!
    let ctx = CGContext(data: nil, width: px, height: px, bitsPerComponent: 8, bytesPerRow: 0, space: cs,
                        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    let s = CGFloat(px) / 1024
    ctx.scaleBy(x: s, y: s) // draw in a 1024 space, y up

    // Tile: macOS icon grid, 824 square with a continuous-looking corner.
    let tile = CGRect(x: 100, y: 100, width: 824, height: 824)
    let tilePath = CGPath(roundedRect: tile, cornerWidth: 185, cornerHeight: 185, transform: nil)

    // Drop shadow under the tile.
    ctx.saveGState()
    ctx.setShadow(offset: CGSize(width: 0, height: -14), blur: 34, color: color(0, 0, 0, 0.35))
    ctx.addPath(tilePath); ctx.setFillColor(color(0.1, 0.1, 0.11)); ctx.fillPath()
    ctx.restoreGState()

    ctx.saveGState()
    ctx.addPath(tilePath); ctx.clip()
    // Graphite base.
    let base = CGGradient(colorsSpace: cs, colors: [color(0.24, 0.24, 0.27), color(0.08, 0.08, 0.09)] as CFArray, locations: [0, 1])!
    ctx.drawLinearGradient(base, start: CGPoint(x: 200, y: 924), end: CGPoint(x: 820, y: 100), options: [])
    // Warm glow behind the ring (bottom right) and a cool, soft light top left.
    let warm = CGGradient(colorsSpace: cs, colors: [color(1.0, 0.56, 0.32, 0.85), color(0.95, 0.32, 0.45, 0.35), color(0.9, 0.3, 0.4, 0)] as CFArray, locations: [0, 0.45, 1])!
    ctx.drawRadialGradient(warm, startCenter: CGPoint(x: 640, y: 380), startRadius: 0, endCenter: CGPoint(x: 640, y: 380), endRadius: 430, options: [])
    let cool = CGGradient(colorsSpace: cs, colors: [color(0.85, 0.9, 0.95, 0.28), color(0.85, 0.9, 0.95, 0)] as CFArray, locations: [0, 1])!
    ctx.drawRadialGradient(cool, startCenter: CGPoint(x: 330, y: 760), startRadius: 0, endCenter: CGPoint(x: 330, y: 760), endRadius: 380, options: [])
    // Thin inner rim on the tile.
    ctx.addPath(CGPath(roundedRect: tile.insetBy(dx: 2, dy: 2), cornerWidth: 183, cornerHeight: 183, transform: nil))
    ctx.setStrokeColor(color(1, 1, 1, 0.14)); ctx.setLineWidth(3); ctx.strokePath()
    ctx.restoreGState()

    let c = CGPoint(x: 512, y: 512)

    func glass(_ shape: CGPath, lightFromTop: Bool = true) {
        let box = shape.boundingBox
        // Shadow cast onto the tile.
        ctx.saveGState()
        ctx.setShadow(offset: CGSize(width: 0, height: -18), blur: 30, color: color(0, 0, 0, 0.45))
        ctx.addPath(shape); ctx.setFillColor(color(1, 1, 1, 0.08)); ctx.fillPath()
        ctx.restoreGState()

        ctx.saveGState()
        ctx.addPath(shape); ctx.clip()
        // Body: frosted white, brighter at the top, letting the glow through at the bottom.
        let body = CGGradient(colorsSpace: cs, colors: [color(1, 1, 1, 0.40), color(1, 1, 1, 0.07), color(1, 0.88, 0.82, 0.16)] as CFArray, locations: [0, 0.55, 1])!
        ctx.drawLinearGradient(body, start: CGPoint(x: box.midX, y: box.maxY), end: CGPoint(x: box.midX, y: box.minY), options: [])
        // Refraction hint: the warm glow bent through the glass, offset from the real glow.
        let bent = CGGradient(colorsSpace: cs, colors: [color(1, 0.66, 0.42, 0.75), color(1, 0.45, 0.5, 0.25), color(1, 0.6, 0.4, 0)] as CFArray, locations: [0, 0.5, 1])!
        ctx.drawRadialGradient(bent, startCenter: CGPoint(x: 585, y: 345), startRadius: 0, endCenter: CGPoint(x: 585, y: 345), endRadius: 360, options: [])
        // The cool top-left light, bent too.
        let bentCool = CGGradient(colorsSpace: cs, colors: [color(0.95, 0.97, 1, 0.35), color(0.95, 0.97, 1, 0)] as CFArray, locations: [0, 1])!
        ctx.drawRadialGradient(bentCool, startCenter: CGPoint(x: 360, y: 720), startRadius: 0, endCenter: CGPoint(x: 360, y: 720), endRadius: 260, options: [])
        // Inner shadow along the bottom edge for thickness.
        ctx.addPath(shape)
        ctx.setShadow(offset: CGSize(width: 0, height: 10), blur: 16, color: color(0, 0, 0, 0.25))
        ctx.setStrokeColor(color(0, 0, 0, 0.25)); ctx.setLineWidth(6); ctx.strokePath()
        ctx.restoreGState()

        // Specular rim: bright on the upper edge, fading downward.
        ctx.saveGState()
        ctx.addPath(shape)
        ctx.setLineWidth(5)
        ctx.replacePathWithStrokedPath()
        ctx.clip()
        let rim = CGGradient(colorsSpace: cs, colors: [color(1, 1, 1, 1.0), color(1, 1, 1, 0.2), color(1, 1, 1, 0.6)] as CFArray, locations: [0, 0.6, 1])!
        ctx.drawLinearGradient(rim, start: CGPoint(x: box.minX, y: box.maxY), end: CGPoint(x: box.maxX, y: box.minY), options: [])
        ctx.restoreGState()
    }

    // Rounded annular sector (a fan piece) with a constant-width gap to its neighbours,
    // the same construction as the app's ring wedges.
    func sector(start: CGFloat, end: CGFloat, inner r: CGFloat, outer R: CGFloat, gap: CGFloat, corner: CGFloat) -> CGPath {
        let half = gap / 2
        let a0o = start + half / R, a1o = end - half / R
        let a0i = start + half / r, a1i = end - half / r
        func pt(_ radius: CGFloat, _ a: CGFloat) -> CGPoint { CGPoint(x: c.x + radius * cos(a), y: c.y + radius * sin(a)) }
        let co = corner, ci = corner * 0.75
        let oS = pt(R, a0o), oE = pt(R, a1o), iE = pt(r, a1i), iS = pt(r, a0i)
        let p = CGMutablePath()
        let ex = oS.x - iS.x, ey = oS.y - iS.y, len = hypot(ex, ey)
        p.move(to: CGPoint(x: oS.x - ex / len * co, y: oS.y - ey / len * co))
        p.addArc(tangent1End: oS, tangent2End: pt(R, a0o + co / R), radius: co)
        p.addArc(center: c, radius: R, startAngle: a0o + co / R, endAngle: a1o - co / R, clockwise: false)
        p.addArc(tangent1End: oE, tangent2End: iE, radius: co)
        p.addArc(tangent1End: iE, tangent2End: pt(r, a1i - ci / r), radius: ci)
        p.addArc(center: c, radius: r, startAngle: a1i - ci / r, endAngle: a0i + ci / r, clockwise: true)
        p.addArc(tangent1End: iS, tangent2End: oS, radius: ci)
        p.closeSubpath()
        return p
    }

    // Six fan pieces, one centred at the top like the ring's first slot.
    let inner: CGFloat = 132, outer: CGFloat = 318
    for k in 0..<6 {
        let mid = .pi / 2 - CGFloat(k) * .pi / 3
        let start = mid - .pi / 6, end = mid + .pi / 6
        let outline = sector(start: start, end: end, inner: inner, outer: outer, gap: 30, corner: 34)
        glass(outline)
        // Specular streak just inside the outer edge, brightest where it faces up.
        ctx.saveGState()
        ctx.addPath(outline); ctx.clip()
        let streak = CGMutablePath()
        streak.addArc(center: c, radius: outer - 22, startAngle: start + 0.16, endAngle: end - 0.16, clockwise: false)
        ctx.addPath(streak.copy(strokingWithWidth: 12, lineCap: .round, lineJoin: .round, miterLimit: 1))
        ctx.clip()
        let sheen = CGGradient(colorsSpace: cs, colors: [color(1, 1, 1, 0.85), color(1, 1, 1, 0.05)] as CFArray, locations: [0, 1])!
        ctx.drawLinearGradient(sheen, start: CGPoint(x: 512, y: 800), end: CGPoint(x: 512, y: 300), options: [])
        ctx.restoreGState()
    }
    glass(CGPath(ellipseIn: CGRect(x: c.x - 80, y: c.y - 80, width: 160, height: 160), transform: nil))

    let image = ctx.makeImage()!
    return NSBitmapImageRep(cgImage: image).representation(using: .png, properties: [:])!
}

for base in [16, 32, 128, 256, 512] {
    try render(base).write(to: out.appendingPathComponent("icon_\(base)x\(base).png"))
    try render(base * 2).write(to: out.appendingPathComponent("icon_\(base)x\(base)@2x.png"))
}
if CommandLine.arguments.count > 2 {
    try render(1024).write(to: URL(fileURLWithPath: CommandLine.arguments[2]))
}
