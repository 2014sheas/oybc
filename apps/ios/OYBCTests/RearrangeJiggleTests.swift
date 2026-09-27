import XCTest
@testable import OYBC

/// Pins the Rearrange jiggle's shared values (web `ArrangeGrid.module.css`
/// `.jiggle`: ±0.4°, 0.28 s per half-cycle) and that it rests at exactly 0°
/// when inactive — the bug was a shake that outlived Rearrange mode.
final class RearrangeJiggleTests: XCTestCase {
    func testSharedValuesMatchWeb() {
        XCTAssertEqual(RearrangeJiggle.amplitudeDegrees, 0.4)
        XCTAssertEqual(RearrangeJiggle.halfCycleSeconds, 0.28)
    }

    func testInactiveIsExactlyZeroAtAnyTime() {
        for t in stride(from: 0.0, through: 5.0, by: 0.037) {
            XCTAssertEqual(RearrangeJiggle.angle(active: false, time: t), 0)
        }
    }

    func testActiveSwingsBetweenBothExtremesAndStaysInBounds() {
        let quarter = RearrangeJiggle.halfCycleSeconds / 2
        XCTAssertEqual(RearrangeJiggle.angle(active: true, time: quarter), 0.4, accuracy: 1e-9)
        XCTAssertEqual(RearrangeJiggle.angle(active: true, time: 3 * quarter), -0.4, accuracy: 1e-9)
        for t in stride(from: 0.0, through: 5.0, by: 0.013) {
            XCTAssertLessThanOrEqual(abs(RearrangeJiggle.angle(active: true, time: t)), 0.4 + 1e-12)
        }
    }
}
