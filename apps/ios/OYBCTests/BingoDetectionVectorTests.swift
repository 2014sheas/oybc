import XCTest
@testable import OYBC

/// Cross-platform bingo-detection enforcement (workstream C1 / issue #267).
///
/// Runs the hand-authored fixture (`packages/bingo-core/tests/fixtures/bingoDetectionVectors.json`)
/// through iOS's `BingoDetection` in `Services/BingoDetection.swift`. The
/// SAME fixture is exercised on the shared/web side by
/// `packages/bingo-core/tests/bingoDetection.test.ts` against
/// `@oybc/bingo-core`'s `bingoDetection.ts`. Both suites passing against the
/// same vectors is what proves the two hand-mirrored implementations agree,
/// not just an audit claim. Lives under `packages/bingo-core` (not
/// `packages/shared`) because the algorithm does; `apps/ios/OYBCTests/BingoDetectionTests.swift`
/// (pre-existing, hand-written) is untouched — this is an additive vector suite.
final class BingoDetectionVectorTests: XCTestCase {

    private struct ExpectedResult: Decodable {
        let completedLines: [String]
        let isGreenlog: Bool
        let totalCompleted: Int
        let totalSquares: Int
    }

    private struct DetectVector: Decodable {
        let name: String
        let gridSize: Int
        let completedIndices: [Int]
        let expected: ExpectedResult
    }

    private struct ErrorVector: Decodable {
        let name: String
        let completionGrid: [Bool]
        let gridSize: Int
        let expectedError: String
    }

    private struct FormatMessageVector: Decodable {
        let name: String
        let result: ExpectedResult
        let expected: String?
    }

    private struct HighlightVector: Decodable {
        let name: String
        let completedLines: [String]
        let gridSize: Int
        let expected: [Int]
    }

    private struct Fixture: Decodable {
        let detectBingos: [DetectVector]
        let errorHandling: [ErrorVector]
        let formatBingoMessage: [FormatMessageVector]
        let getHighlightedSquares: [HighlightVector]
    }

    private func loadFixture() throws -> Fixture {
        guard let url = Bundle(for: BingoDetectionVectorTests.self).url(
            forResource: "bingoDetectionVectors",
            withExtension: "json"
        ) else {
            XCTFail(
                "bingoDetectionVectors.json not found in test bundle — check project.yml's " +
                "OYBCTests `resources` entry for Fixtures, and that xcodegen generate has been re-run."
            )
            throw XCTSkip("Fixture missing")
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    private func makeGrid(size: Int, completed: [Int]) -> [Bool] {
        var grid = Array(repeating: false, count: size * size)
        for i in completed { grid[i] = true }
        return grid
    }

    func testDetectBingosVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.detectBingos.isEmpty)
        for v in fixture.detectBingos {
            let grid = makeGrid(size: v.gridSize, completed: v.completedIndices)
            let result = BingoDetection.detectBingos(completionGrid: grid, gridSize: v.gridSize)
            XCTAssertEqual(result.completedLines, v.expected.completedLines, "Vector '\(v.name)' completedLines")
            XCTAssertEqual(result.isGreenlog, v.expected.isGreenlog, "Vector '\(v.name)' isGreenlog")
            XCTAssertEqual(result.totalCompleted, v.expected.totalCompleted, "Vector '\(v.name)' totalCompleted")
            XCTAssertEqual(result.totalSquares, v.expected.totalSquares, "Vector '\(v.name)' totalSquares")
        }
    }

    // Note: Swift's `detectBingos` enforces the length invariant via
    // `precondition`, which traps rather than throwing a catchable error —
    // this suite documents the invariant structurally (see the pre-existing
    // `BingoDetectionTests.testDetectBingosAcceptsGridMatchingExpectedLength`)
    // rather than crash-boxing the three `errorHandling` fixture vectors,
    // which assert a catchable `.toThrow(message)` on the TS side. A future
    // pass could crash-box these; tracked here rather than silently dropped.
    func testErrorHandlingFixtureIsNonEmpty() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.errorHandling.isEmpty)
    }

    func testFormatBingoMessageVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.formatBingoMessage.isEmpty)
        for v in fixture.formatBingoMessage {
            let result = BingoDetectionResult(
                completedLines: v.result.completedLines,
                isGreenlog: v.result.isGreenlog,
                totalCompleted: v.result.totalCompleted,
                totalSquares: v.result.totalSquares
            )
            let message = BingoDetection.formatBingoMessage(result: result)
            XCTAssertEqual(message, v.expected, "Vector '\(v.name)'")
        }
    }

    func testGetHighlightedSquaresVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.getHighlightedSquares.isEmpty)
        for v in fixture.getHighlightedSquares {
            let result = BingoDetection.getHighlightedSquares(completedLines: v.completedLines, gridSize: v.gridSize)
            XCTAssertEqual(Set(result), Set(v.expected), "Vector '\(v.name)'")
        }
    }
}
