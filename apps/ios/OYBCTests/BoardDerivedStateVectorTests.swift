import XCTest
@testable import OYBC

/// Cross-platform pins for `BoardDerivedState.swift`, driven by the same
/// `boardDerivedStateVectors.json` as
/// `packages/shared/tests/algorithms/boardDerivedState.test.ts`.
final class BoardDerivedStateVectorTests: XCTestCase {
    private struct Vector: Decodable {
        let name: String
        let before: BoardDerivedState
        let after: BoardDerivedState
        let expected: Bool
    }
    private struct Fixture: Decodable { let cases: [Vector] }

    private func loadFixture() throws -> Fixture {
        guard let url = Bundle(for: BoardDerivedStateVectorTests.self)
            .url(forResource: "boardDerivedStateVectors", withExtension: "json") else {
            XCTFail("boardDerivedStateVectors.json missing from the test bundle — re-run gen:sync-fixtures and xcodegen generate.")
            throw XCTSkip("Fixture missing")
        }
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testVectors() throws {
        let cases = try loadFixture().cases
        XCTAssertFalse(cases.isEmpty)
        for v in cases {
            XCTAssertEqual(boardDerivedStateChanged(v.before, v.after), v.expected, v.name)
        }
    }

    func testVectorsAreSymmetric() throws {
        for v in try loadFixture().cases {
            XCTAssertEqual(boardDerivedStateChanged(v.after, v.before), v.expected, "symmetric: \(v.name)")
        }
    }
}
