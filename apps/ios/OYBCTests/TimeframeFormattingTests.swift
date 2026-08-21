import XCTest
@testable import OYBC

/// Unit tests for `formatCadenceAdverb` (Task Pools + Recurring Boards
/// Rework, P6) — the "Repeats <adverb>" copy used by the Board-screen
/// manage row and the Boards-tab card's cadence subtitle.
final class TimeframeFormattingTests: XCTestCase {

    func testFormatCadenceAdverb_Daily() {
        XCTAssertEqual(formatCadenceAdverb(.daily), "daily")
    }

    func testFormatCadenceAdverb_Weekly() {
        XCTAssertEqual(formatCadenceAdverb(.weekly), "weekly")
    }

    func testFormatCadenceAdverb_Monthly() {
        XCTAssertEqual(formatCadenceAdverb(.monthly), "monthly")
    }

    func testFormatCadenceAdverb_Yearly() {
        XCTAssertEqual(formatCadenceAdverb(.yearly), "yearly")
    }

    /// Defensive-only branch — the repeat-cadence picker never offers
    /// `.custom`/`.indefinite`, but the function must not crash if it ever
    /// receives one.
    func testFormatCadenceAdverb_Custom_FallsBackToRegularly() {
        XCTAssertEqual(formatCadenceAdverb(.custom), "regularly")
    }

    func testFormatCadenceAdverb_Indefinite_FallsBackToRegularly() {
        XCTAssertEqual(formatCadenceAdverb(.indefinite), "regularly")
    }
}
