import XCTest
@testable import OYBC

/// Pins the cell text scale: base sizes at a 5×5 edge, caps at a 3×3 edge,
/// linear between, clamped outside.
final class CellTextMetricsTests: XCTestCase {

    func testBaseSizesAtAndBelowFiveByFiveEdge() {
        for edge: CGFloat in [40, 64] {
            let m = CellTextMetrics(cellSize: edge)
            XCTAssertEqual(m.title, 9)
            XCTAssertEqual(m.bar, 9)
            XCTAssertEqual(m.tag, 7)
            XCTAssertEqual(m.barHeight, 13)
            XCTAssertEqual(m.titleTopInset, 20)
            XCTAssertEqual(m.titleBottomInset, 18)
        }
    }

    func testCapsAtAndAboveThreeByThreeEdge() {
        for edge: CGFloat in [112, 200] {
            let m = CellTextMetrics(cellSize: edge)
            XCTAssertEqual(m.title, 14)
            XCTAssertEqual(m.bar, 11)
            XCTAssertEqual(m.tag, 9)
            XCTAssertEqual(m.barHeight, 16)
            XCTAssertEqual(m.titleTopInset, 24)
            XCTAssertEqual(m.titleBottomInset, 21)
        }
    }

    func testLinearBetween() {
        let m = CellTextMetrics(cellSize: 88)
        XCTAssertEqual(m.title, 11.5, accuracy: 0.001)
        XCTAssertEqual(m.bar, 10, accuracy: 0.001)
        XCTAssertEqual(m.tag, 8, accuracy: 0.001)
    }
}
