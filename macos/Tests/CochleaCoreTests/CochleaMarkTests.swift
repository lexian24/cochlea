import XCTest
@testable import CochleaCore

/// The mark is generated, not shipped, so its geometry is testable — and the
/// one property that actually matters at 18pt is that the coils stay apart.
final class CochleaMarkTests: XCTestCase {

    func testTheCoilsDoNotMerge() {
        // A logarithmic spiral's pitch is proportional to radius, so a ribbon
        // of fixed relative width keeps a constant visual gap. If this ever
        // goes negative the coils touch and the mark becomes a blob — which at
        // menu bar size is the difference between an icon and a smudge.
        XCTAssertGreaterThan(CochleaMark.coilGap, 0.1,
                             "coils this close will not survive 18pt")
    }

    func testTheOutlineIsAClosedRibbon() {
        // Out along the outer edge and back along the inner one, so filling it
        // gives a ribbon rather than a filled spiral disc.
        let points = CochleaMark.outline(center: .zero, extent: 18, steps: 40)
        XCTAssertEqual(points.count, 82)     // (steps + 1) x 2
    }

    func testItFitsTheExtentItIsGiven() {
        // A menu bar glyph lives in an 18pt box. Overflowing it clips;
        // undershooting leaves the icon looking small next to its neighbours.
        let extent: CGFloat = 18
        let points = CochleaMark.outline(center: CGPoint(x: 9, y: 9), extent: extent)
        let xs = points.map(\.x), ys = points.map(\.y)
        let width = xs.max()! - xs.min()!
        let height = ys.max()! - ys.min()!
        XCTAssertEqual(max(width, height), extent, accuracy: 0.01)
        XCTAssertLessThanOrEqual(min(width, height), extent + 0.01)
    }

    func testItIsCentredOnThePointItIsGiven() {
        // Optically, not by bounding box: a spiral's mass sits off its
        // geometric centre, so this centres the drawn extent and the drawing
        // code can trust the point it passes in.
        let center = CGPoint(x: 40, y: 25)
        let points = CochleaMark.outline(center: center, extent: 30)
        let xs = points.map(\.x), ys = points.map(\.y)
        XCTAssertEqual((xs.min()! + xs.max()!) / 2, center.x, accuracy: 0.01)
        XCTAssertEqual((ys.min()! + ys.max()!) / 2, center.y, accuracy: 0.01)
    }

    func testItScalesLinearly() {
        // The same path at every size is what makes shipping no bitmap
        // possible; a mark that drifts with scale would need one per size.
        let small = CochleaMark.outline(center: .zero, extent: 10, steps: 40)
        let large = CochleaMark.outline(center: .zero, extent: 100, steps: 40)
        for (a, b) in zip(small, large) {
            XCTAssertEqual(a.x * 10, b.x, accuracy: 0.001)
            XCTAssertEqual(a.y * 10, b.y, accuracy: 0.001)
        }
    }

    func testAZeroExtentDoesNotProduceGarbage() {
        // Defensive: a view laid out at zero size asks for this, and returning
        // NaN points would take the whole draw call down.
        let points = CochleaMark.outline(center: .zero, extent: 0, steps: 40)
        XCTAssertTrue(points.allSatisfy { $0.x.isFinite && $0.y.isFinite })
    }
}
