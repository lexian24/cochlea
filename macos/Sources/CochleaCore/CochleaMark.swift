import CoreGraphics
import Foundation

/// The cochlea mark, as geometry.
///
/// A logarithmic spiral, because that is literally what a cochlea is — the
/// spiral cavity of the inner ear — and because it also reads as a decaying
/// waveform, which is the other half of what this app does.
///
/// Computed rather than shipped as an image, and the numbers are the ones in
/// `Tools/make_logo.py` so the two cannot drift. A menu bar icon has to be a
/// *template* image to tint correctly against a light bar, a dark bar and a
/// highlighted menu, and it has to stay crisp at 16pt on a non-Retina display
/// and 32px on a Retina one. A path satisfies all of that at any size; a PNG
/// satisfies none of it without an asset catalogue this dependency-free
/// package deliberately does not have.
public enum CochleaMark {

    /// Enough coils to read as a cochlea, few enough to stay open at 16pt.
    public static let turns = 2.05
    /// How tightly it winds inward.
    public static let decay = 1.62
    /// Ribbon width as a fraction of the local radius.
    public static let thickness = 0.38

    /// Gap between adjacent coils, as a fraction of local radius.
    ///
    /// The pitch of a logarithmic spiral is itself proportional to radius, so
    /// a ribbon whose width is a fixed fraction of radius keeps a constant
    /// visual gap. If this goes negative the coils merge into a blob — which
    /// at menu bar size is the difference between a mark and a smudge.
    public static var coilGap: Double {
        let pitch = 1.0 - exp(-decay * 2 * .pi / (turns * 2 * .pi))
        return pitch - thickness
    }

    /// The outline of the tapered ribbon, in order, ready to be filled.
    ///
    /// Returns one closed loop: out along the spiral's outer edge, around the
    /// apex, and back along the inner edge. `extent` is the width the mark
    /// should occupy, and the result is optically centred on `center` — a
    /// spiral's mass sits off its geometric centre, so centring the bounding
    /// box instead leaves it visibly high and left.
    public static func outline(center: CGPoint, extent: CGFloat,
                               steps: Int = 240) -> [CGPoint] {
        let thetaMax = turns * 2 * .pi
        let startAngle = -Double.pi / 2
        var outer: [CGPoint] = []
        var inner: [CGPoint] = []
        for index in 0...steps {
            let s = Double(index) / Double(steps)
            let r = exp(-decay * s)
            // Taper only near the apex, so the ribbon keeps its weight through
            // the outer coils where a menu bar icon is actually legible.
            let w = thickness * r * pow(1.0 - s, 0.35)
            let a = startAngle + thetaMax * s
            let nx = cos(a), ny = sin(a)
            outer.append(CGPoint(x: nx * (r + w / 2), y: ny * (r + w / 2)))
            inner.append(CGPoint(x: nx * (r - w / 2), y: ny * (r - w / 2)))
        }

        let all = outer + inner
        let minX = all.map(\.x).min() ?? 0, maxX = all.map(\.x).max() ?? 0
        let minY = all.map(\.y).min() ?? 0, maxY = all.map(\.y).max() ?? 0
        let span = max(maxX - minX, maxY - minY)
        guard span > 0 else { return [] }
        let scale = Double(extent) / span
        let midX = (minX + maxX) / 2, midY = (minY + maxY) / 2

        func place(_ p: CGPoint) -> CGPoint {
            CGPoint(x: center.x + CGFloat((p.x - midX) * scale),
                    y: center.y + CGFloat((p.y - midY) * scale))
        }
        return outer.map(place) + inner.reversed().map(place)
    }
}
