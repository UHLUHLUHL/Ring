import SwiftUI

/// Ring dimensions. Values are first guesses carried over from the Figma draft; re-measure on device.
enum RingMetrics {
    /// Overall size relative to the first build (user asked for ~75%).
    static let scale: CGFloat = 0.75
    static let outer: CGFloat = 196 * scale
    static let inner: CGFloat = 100 * scale
    static let gap: CGFloat = 8
    static let outerCorner: CGFloat = 18 * scale
    static let innerCorner: CGFloat = 13 * scale
    static let hubDiameter: CGFloat = 176 * scale
    static let hoverLift: CGFloat = 7 * scale
    /// Side of the square the ring is drawn in (leaves room for the hover lift).
    static let canvas: CGFloat = (outer + 22) * 2
    /// Glass variant for the ring. `.clear` lets the lensing show; `ring://…&glass=regular` overrides.
    static var glass: Glass = .clear
    /// Ring size when closed: it opens from here and closes back to it (guess, tuned by eye).
    static let closedGrow: CGFloat = 0.3
}

/// Angles in degrees, 0 = 12 o'clock, increasing clockwise on screen.
struct RingSlot {
    let index: Int
    let count: Int

    var mid: Double { Double(index) * 360 / Double(count) }
    var start: Double { mid - 180 / Double(count) }
    var end: Double { mid + 180 / Double(count) }

    /// Outward offset applied while a wedge centred at `mid` degrees is hovered.
    static func lift(mid: Double, amount: CGFloat) -> CGSize {
        let a = (mid - 90) * .pi / 180
        return CGSize(width: amount * CGFloat(Foundation.cos(a)), height: amount * CGFloat(Foundation.sin(a)))
    }

    func labelPoint(center: CGPoint) -> CGPoint {
        let a = (mid - 90) * .pi / 180
        let r = (RingMetrics.outer + RingMetrics.inner) / 2
        return CGPoint(x: center.x + r * CGFloat(Foundation.cos(a)), y: center.y + r * CGFloat(Foundation.sin(a)))
    }

    /// Which slot a point falls in, or nil when it is on the hub or outside the ring.
    static func hit(_ p: CGPoint, center: CGPoint, count: Int) -> Int? {
        guard count > 0 else { return nil }
        let dx = p.x - center.x, dy = p.y - center.y
        let dist = hypot(dx, dy)
        guard dist >= RingMetrics.inner - 4, dist <= RingMetrics.outer + 12 else { return nil }
        var deg = atan2(dy, dx) * 180 / .pi + 90
        if deg < 0 { deg += 360 }
        let step = 360 / Double(count)
        return Int(((deg + step / 2).truncatingRemainder(dividingBy: 360)) / step) % count
    }
}

/// Annular sector with rounded corners and a constant-width gap to its neighbours.
/// Angles in degrees (0 = 12 o'clock, clockwise). `outer` can shrink during the tab morph.
struct SectorShape: Shape {
    let start: Double
    let end: Double
    var outer: CGFloat = RingMetrics.outer
    /// Size relative to the full ring, about the ring centre (the open/close animation).
    var grow: CGFloat = 1
    /// Offset of a lifted (selected) wedge, applied after `grow`.
    var shift: CGSize = .zero
    /// The receiving glass surface. A sector is consumed at this radius instead
    /// of continuing to shrink behind the hub as a second lens.
    var hubRadius: CGFloat = 0

    init(slot: RingSlot) { start = slot.start; end = slot.end }
    init(start: Double, end: Double, outer: CGFloat, grow: CGFloat = 1, shift: CGSize = .zero, hubRadius: CGFloat = 0) {
        self.start = start; self.end = end; self.outer = outer; self.grow = grow; self.shift = shift; self.hubRadius = hubRadius
    }

    func path(in rect: CGRect) -> Path {
        guard grow > 0.01, outer * grow + hypot(shift.width, shift.height) > hubRadius + 0.1 else { return Path() }
        let full = fullPath(in: rect)
        let moved = CGAffineTransform(translationX: shift.width, y: shift.height)
        return shift == .zero ? full : full.applying(moved)
    }

    private func fullPath(in rect: CGRect) -> Path {
        let c = CGPoint(x: rect.midX, y: rect.midY)
        let R = outer * grow
        var r = RingMetrics.inner * grow
        if hubRadius > 0 {
            // A short meniscus reaches toward the hub only within six points of
            // contact. After contact its inner edge stays at the surface while
            // the outer edge drains into it; no ring travels underneath.
            let gap = max(0, r - hubRadius)
            let t = min(1, max(0, 1 - gap / 6))
            let contact = t * t * (3 - 2 * t)
            r = max(hubRadius - 3, r - (gap + 3) * contact)
        }
        let half = RingMetrics.gap / 2 * grow
        let span = (end - start) * .pi / 180
        // A wedge folding away (span → 0) simply disappears once it is thinner than the gap.
        guard R - r > 0.1, r > 0.1, span * Double(r) > Double(half * 2) + 3 * Double(grow) else { return Path() }
        func rad(_ deg: Double) -> Double { (deg - 90) * .pi / 180 }
        let a0o = rad(start) + Double(half / R), a1o = rad(end) - Double(half / R)
        let a0i = rad(start) + Double(half / r), a1i = rad(end) - Double(half / r)
        func pt(_ radius: CGFloat, _ a: Double) -> CGPoint {
            CGPoint(x: c.x + radius * CGFloat(Foundation.cos(a)), y: c.y + radius * CGFloat(Foundation.sin(a)))
        }
        // Corners shrink with the wedge so thin or short wedges keep a valid outline.
        let co = min(RingMetrics.outerCorner * grow, CGFloat(a1o - a0o) * R * 0.3, (R - r) * 0.42)
        let ci = min(RingMetrics.innerCorner * grow, CGFloat(a1i - a0i) * r * 0.3, (R - r) * 0.42)
        let oS = pt(R, a0o), oE = pt(R, a1o), iE = pt(r, a1i), iS = pt(r, a0i)
        let dO = Double(co / R), dI = Double(ci / r)

        var p = Path()
        let edge = CGPoint(x: oS.x - iS.x, y: oS.y - iS.y)
        let len = hypot(edge.x, edge.y)
        p.move(to: CGPoint(x: oS.x - edge.x / len * co, y: oS.y - edge.y / len * co))
        p.addArc(tangent1End: oS, tangent2End: pt(R, a0o + dO), radius: co)
        p.addArc(center: c, radius: R, startAngle: .radians(a0o + dO), endAngle: .radians(a1o - dO), clockwise: false)
        p.addArc(tangent1End: oE, tangent2End: iE, radius: co)
        p.addArc(tangent1End: iE, tangent2End: pt(r, a1i - dI), radius: ci)
        p.addArc(center: c, radius: r, startAngle: .radians(a1i - dI), endAngle: .radians(a0i + dI), clockwise: true)
        p.addArc(tangent1End: iS, tangent2End: oS, radius: ci)
        p.closeSubpath()
        return p
    }
}
