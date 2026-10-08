import XCTest
@testable import OYBC

/// Cross-platform pins for `PullWatermark.swift`, driven by the same
/// `pullWatermarkVectors.json` as
/// `packages/shared/tests/algorithms/pullWatermark.test.ts`.
final class PullWatermarkVectorTests: XCTestCase {
    private struct Vector: Decodable {
        let name: String
        let prev: PullWatermark?
        let syncedAts: [PullWatermark?]
        let expected: PullWatermark?
    }
    private struct Fixture: Decodable { let cases: [Vector] }

    private func loadFixture() throws -> Fixture {
        guard let url = Bundle(for: PullWatermarkVectorTests.self)
            .url(forResource: "pullWatermarkVectors", withExtension: "json") else {
            XCTFail("pullWatermarkVectors.json missing from the test bundle — re-run gen:sync-fixtures and xcodegen generate.")
            throw XCTSkip("Fixture missing")
        }
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testVectors() throws {
        let cases = try loadFixture().cases
        XCTAssertFalse(cases.isEmpty)
        for v in cases {
            XCTAssertEqual(nextPullWatermark(v.prev, v.syncedAts), v.expected, v.name)
        }
    }

    func testReadsDatesAndRejectsUnknownValues() {
        XCTAssertEqual(PullWatermark(date: Date(timeIntervalSince1970: 12.5)), PullWatermark(seconds: 12, nanoseconds: 500_000_000))
        XCTAssertEqual(PullWatermark(syncedAtValue: Date(timeIntervalSince1970: 3)), PullWatermark(seconds: 3, nanoseconds: 0))
        XCTAssertNil(PullWatermark(syncedAtValue: nil))
        XCTAssertNil(PullWatermark(syncedAtValue: NSNull()))
        XCTAssertNil(PullWatermark(syncedAtValue: "2026-01-01T00:00:00Z"))
    }

    func testTimestampRoundTripIsExact() {
        let mark = PullWatermark(seconds: 1_790_000_123, nanoseconds: 987_654_321)
        XCTAssertEqual(PullWatermark(syncedAtValue: mark.timestamp), mark)
    }
}
