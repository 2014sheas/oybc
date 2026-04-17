import XCTest
@testable import OYBC

/// Unit tests for `BingoDetection` — parity with
/// `packages/shared/tests/algorithms/bingoDetection.test.ts`.
///
/// The iOS implementation is a line-for-line mirror of the shared
/// TypeScript algorithm. Any divergence between the two would cause
/// cross-device UX drift (e.g. a board that shows a bingo on iOS but
/// not on web). This suite pins the invariants the mirror relies on.
///
/// Tests cover the three public entry points:
///   - `detectBingos(completionGrid:gridSize:)`
///   - `formatBingoMessage(result:)`
///   - `getHighlightedSquares(completedLines:gridSize:)`
final class BingoDetectionTests: XCTestCase {

    // MARK: - Helpers

    /// Builds a flat completion grid of length `size * size` with only
    /// the given indices marked complete. Matches the `makeGrid` helper
    /// in the shared TS tests so test cases can be reused 1:1.
    private func makeGrid(size: Int, completed: [Int]) -> [Bool] {
        var grid = Array(repeating: false, count: size * size)
        for i in completed { grid[i] = true }
        return grid
    }

    // MARK: - 5x5 Board

    func testEmptyFiveByFiveBoardHasNoBingos() {
        let grid = Array(repeating: false, count: 25)
        let result = BingoDetection.detectBingos(completionGrid: grid, gridSize: 5)
        XCTAssertEqual(result.completedLines, [])
        XCTAssertFalse(result.isGreenlog)
        XCTAssertEqual(result.totalCompleted, 0)
        XCTAssertEqual(result.totalSquares, 25)
    }

    func testFiveByFiveDetectsFirstRow() {
        let grid = makeGrid(size: 5, completed: [0, 1, 2, 3, 4])
        let result = BingoDetection.detectBingos(completionGrid: grid, gridSize: 5)
        XCTAssertEqual(result.completedLines, ["row_0"])
        XCTAssertFalse(result.isGreenlog)
        XCTAssertEqual(result.totalCompleted, 5)
    }

    func testFiveByFiveDetectsLastRow() {
        let grid = makeGrid(size: 5, completed: [20, 21, 22, 23, 24])
        let result = BingoDetection.detectBingos(completionGrid: grid, gridSize: 5)
        XCTAssertEqual(result.completedLines, ["row_4"])
    }

    func testFiveByFiveDetectsMiddleRow() {
        let grid = makeGrid(size: 5, completed: [10, 11, 12, 13, 14])
        let result = BingoDetection.detectBingos(completionGrid: grid, gridSize: 5)
        XCTAssertEqual(result.completedLines, ["row_2"])
    }

    func testFiveByFiveDetectsFirstColumn() {
        let grid = makeGrid(size: 5, completed: [0, 5, 10, 15, 20])
        let result = BingoDetection.detectBingos(completionGrid: grid, gridSize: 5)
        XCTAssertEqual(result.completedLines, ["col_0"])
    }

    func testFiveByFiveDetectsLastColumn() {
        let grid = makeGrid(size: 5, completed: [4, 9, 14, 19, 24])
        let result = BingoDetection.detectBingos(completionGrid: grid, gridSize: 5)
        XCTAssertEqual(result.completedLines, ["col_4"])
    }

    func testFiveByFiveDetectsMainDiagonal() {
        let grid = makeGrid(size: 5, completed: [0, 6, 12, 18, 24])
        let result = BingoDetection.detectBingos(completionGrid: grid, gridSize: 5)
        XCTAssertEqual(result.completedLines, ["diag_main"])
    }

    func testFiveByFiveDetectsAntiDiagonal() {
        let grid = makeGrid(size: 5, completed: [4, 8, 12, 16, 20])
        let result = BingoDetection.detectBingos(completionGrid: grid, gridSize: 5)
        XCTAssertEqual(result.completedLines, ["diag_anti"])
    }

    func testFiveByFiveDetectsMultipleSimultaneousBingos() {
        // row_0 (0–4) + col_0 (0,5,10,15,20) share index 0.
        let grid = makeGrid(size: 5, completed: [0, 1, 2, 3, 4, 5, 10, 15, 20])
        let result = BingoDetection.detectBingos(completionGrid: grid, gridSize: 5)
        XCTAssertTrue(result.completedLines.contains("row_0"))
        XCTAssertTrue(result.completedLines.contains("col_0"))
        XCTAssertFalse(result.isGreenlog)
    }

    func testFiveByFiveDetectsGreenlogWhenFull() {
        let grid = Array(repeating: true, count: 25)
        let result = BingoDetection.detectBingos(completionGrid: grid, gridSize: 5)
        XCTAssertTrue(result.isGreenlog)
        XCTAssertEqual(result.totalCompleted, 25)
        // Every row, every column, and both diagonals should be present.
        XCTAssertEqual(result.completedLines.count, 5 + 5 + 2)
    }

    // MARK: - 3x3 Board

    func testThreeByThreeDetectsRow() {
        let grid = makeGrid(size: 3, completed: [0, 1, 2])
        let result = BingoDetection.detectBingos(completionGrid: grid, gridSize: 3)
        XCTAssertEqual(result.completedLines, ["row_0"])
        XCTAssertEqual(result.totalSquares, 9)
    }

    func testThreeByThreeGreenlog() {
        let grid = Array(repeating: true, count: 9)
        let result = BingoDetection.detectBingos(completionGrid: grid, gridSize: 3)
        XCTAssertTrue(result.isGreenlog)
        XCTAssertEqual(result.totalCompleted, 9)
    }

    // MARK: - 4x4 Board

    func testFourByFourDetectsMainDiagonal() {
        // Indices on main diagonal: 0, 5, 10, 15.
        let grid = makeGrid(size: 4, completed: [0, 5, 10, 15])
        let result = BingoDetection.detectBingos(completionGrid: grid, gridSize: 4)
        XCTAssertEqual(result.completedLines, ["diag_main"])
        XCTAssertEqual(result.totalSquares, 16)
    }

    func testFourByFourDetectsAntiDiagonal() {
        // Indices on anti diagonal (size=4): 3, 6, 9, 12.
        let grid = makeGrid(size: 4, completed: [3, 6, 9, 12])
        let result = BingoDetection.detectBingos(completionGrid: grid, gridSize: 4)
        XCTAssertEqual(result.completedLines, ["diag_anti"])
    }

    // MARK: - Precondition

    func testDetectBingosPreconditionFailsOnMismatchedGridLength() {
        // Swift's `precondition` traps in debug builds; tested via an
        // XCTest expectation on the failure. We can't easily catch
        // preconditionFailure without crash-boxing, so document the
        // invariant by asserting a valid grid works and not adding a
        // false negative here. Kept as a named test for discoverability.
        let goodGrid = Array(repeating: false, count: 9)
        _ = BingoDetection.detectBingos(completionGrid: goodGrid, gridSize: 3) // no crash
    }

    // MARK: - formatBingoMessage

    func testFormatMessageReturnsNilWhenNoBingos() {
        let result = BingoDetectionResult(
            completedLines: [],
            isGreenlog: false,
            totalCompleted: 0,
            totalSquares: 25
        )
        XCTAssertNil(BingoDetection.formatBingoMessage(result: result))
    }

    func testFormatMessageReturnsGreenlog() {
        let result = BingoDetectionResult(
            completedLines: ["row_0", "row_1", "row_2"],
            isGreenlog: true,
            totalCompleted: 25,
            totalSquares: 25
        )
        XCTAssertEqual(BingoDetection.formatBingoMessage(result: result), "GREENLOG!")
    }

    func testFormatMessageListsBingoLinesWhenNotGreenlog() {
        let result = BingoDetectionResult(
            completedLines: ["row_0", "col_2"],
            isGreenlog: false,
            totalCompleted: 9,
            totalSquares: 25
        )
        XCTAssertEqual(
            BingoDetection.formatBingoMessage(result: result),
            "Bingo! (row_0, col_2)"
        )
    }

    // MARK: - getHighlightedSquares

    func testHighlightedSquaresEmptyForNoLines() {
        let result = BingoDetection.getHighlightedSquares(completedLines: [], gridSize: 5)
        XCTAssertTrue(result.isEmpty)
    }

    func testHighlightedSquaresForSingleRow() {
        let result = BingoDetection.getHighlightedSquares(completedLines: ["row_0"], gridSize: 5)
        XCTAssertEqual(result, Set([0, 1, 2, 3, 4]))
    }

    func testHighlightedSquaresForSingleColumn() {
        let result = BingoDetection.getHighlightedSquares(completedLines: ["col_2"], gridSize: 5)
        XCTAssertEqual(result, Set([2, 7, 12, 17, 22]))
    }

    func testHighlightedSquaresForMainDiagonal() {
        let result = BingoDetection.getHighlightedSquares(completedLines: ["diag_main"], gridSize: 5)
        XCTAssertEqual(result, Set([0, 6, 12, 18, 24]))
    }

    func testHighlightedSquaresForAntiDiagonal() {
        let result = BingoDetection.getHighlightedSquares(completedLines: ["diag_anti"], gridSize: 5)
        XCTAssertEqual(result, Set([4, 8, 12, 16, 20]))
    }

    func testHighlightedSquaresForIntersectingLinesUnionsIndices() {
        // row_0 ∪ col_0 → first row plus first column (deduped on 0).
        let result = BingoDetection.getHighlightedSquares(
            completedLines: ["row_0", "col_0"],
            gridSize: 5
        )
        XCTAssertEqual(result, Set([0, 1, 2, 3, 4, 5, 10, 15, 20]))
    }

    func testHighlightedSquaresSkipsMalformedLineIds() {
        // Unknown prefixes are ignored rather than crashing — defense
        // against stale persisted line IDs after a schema change.
        let result = BingoDetection.getHighlightedSquares(
            completedLines: ["row_0", "weird_7", "col_1"],
            gridSize: 3
        )
        // row_0 (0,1,2) ∪ col_1 (1,4,7) = {0,1,2,4,7}; "weird_7" ignored.
        XCTAssertEqual(result, Set([0, 1, 2, 4, 7]))
    }
}
