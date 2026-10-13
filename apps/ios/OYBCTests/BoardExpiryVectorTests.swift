import XCTest
@testable import OYBC

/// Runs the shared `boardExpiryVectors.json` fixture (synced from
/// `packages/shared/tests/fixtures/`) through `BoardExpiry.isExpiringSoon`.
/// The SAME fixture drives `packages/shared/tests/algorithms/boardExpiry.test.ts`.
/// Every timestamp is local-ISO wall clock, so the expectations hold in any
/// time zone.
final class BoardExpiryVectorTests: XCTestCase {

    private struct VectorBoard: Decodable {
        let status: String
        let timeframe: String
        let startDate: String?
        let endDate: String?
    }

    private struct ExpiringVector: Decodable {
        let name: String
        let board: VectorBoard
        let now: String
        let expected: Bool
    }

    private struct Fixture: Decodable {
        let expiringSoon: [ExpiringVector]
    }

    private func loadFixture() throws -> Fixture {
        guard let url = Bundle(for: BoardExpiryVectorTests.self).url(
            forResource: "boardExpiryVectors", withExtension: "json"
        ) else {
            XCTFail("boardExpiryVectors.json not found in test bundle — re-run " +
                    "`pnpm --filter @oybc/shared run gen:sync-fixtures` and xcodegen generate.")
            throw XCTSkip("Fixture missing")
        }
        return try JSONDecoder().decode(Fixture.self, from: try Data(contentsOf: url))
    }

    func testExpiringSoonVectors() throws {
        let fixture = try loadFixture()
        XCTAssertGreaterThanOrEqual(fixture.expiringSoon.count, 15)
        for v in fixture.expiringSoon {
            let status = try XCTUnwrap(BoardStatus(rawValue: v.board.status), v.name)
            let timeframe = try XCTUnwrap(Timeframe(rawValue: v.board.timeframe), v.name)
            let now = try XCTUnwrap(DateFormatting.parseISO(v.now), v.name)
            XCTAssertEqual(
                BoardExpiry.isExpiringSoon(
                    status: status, timeframe: timeframe,
                    startDate: v.board.startDate, endDate: v.board.endDate, now: now
                ),
                v.expected,
                "Vector '\(v.name)'"
            )
        }
    }
}
