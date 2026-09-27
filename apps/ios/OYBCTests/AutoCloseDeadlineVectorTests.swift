import XCTest
@testable import OYBC

/// Board Edit redesign slice 4 (D4 / owner ruling R5, D12): runs the shared
/// `autoCloseDeadlineVectors.json` fixture (synced from
/// `packages/shared/tests/fixtures/`) through the Swift twins in
/// `Helpers/Sealing.swift` — `computeAutoCloseDeadlineMs`,
/// `isBoardPastBackstop`, `isBoardEnded`, `isBoardClosed`. The SAME fixture
/// drives `packages/shared/tests/algorithms/sealing.test.ts`. Every timestamp
/// is local-ISO wall clock, so the expectations hold in any time zone.
final class AutoCloseDeadlineVectorTests: XCTestCase {

    private struct VectorBoard: Decodable {
        let isDeleted: Bool?
        let status: String?
        let timeframe: String
        let startDate: String
        let endDate: String?
        let sealedAt: String?
        let activatedAt: String?
        let reopenedAt: String?
    }

    private struct DeadlineVector: Decodable {
        let name: String
        let board: VectorBoard
        let expectedDeadline: String?
    }

    private struct PastBackstopVector: Decodable {
        let name: String
        let board: VectorBoard
        let now: String
        let expected: Bool
    }

    private struct LifecycleVector: Decodable {
        let name: String
        let board: VectorBoard
        let now: String
        let ended: Bool
        let closed: Bool
    }

    private struct Fixture: Decodable {
        let deadlines: [DeadlineVector]
        let pastBackstop: [PastBackstopVector]
        let lifecycle: [LifecycleVector]
    }

    private func loadFixture() throws -> Fixture {
        guard let url = Bundle(for: AutoCloseDeadlineVectorTests.self).url(
            forResource: "autoCloseDeadlineVectors", withExtension: "json"
        ) else {
            XCTFail("autoCloseDeadlineVectors.json not found in test bundle — re-run " +
                    "`pnpm --filter @oybc/shared run gen:sync-fixtures` and xcodegen generate.")
            throw XCTSkip("Fixture missing")
        }
        return try JSONDecoder().decode(Fixture.self, from: try Data(contentsOf: url))
    }

    /// Vector board → a decoded `Board` (nulls become absent keys, like a row).
    private func makeBoard(_ v: VectorBoard) throws -> Board {
        var dict: [String: Any] = [
            "id": "b1", "userId": "u1", "name": "B", "status": v.status ?? "active",
            "boardSize": 3, "timeframe": v.timeframe, "startDate": v.startDate,
            "centerSquareType": "none", "isRandomized": false,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": v.startDate, "updatedAt": v.startDate, "version": 1,
            "isDeleted": v.isDeleted ?? false,
        ]
        if let endDate = v.endDate { dict["endDate"] = endDate }
        if let sealedAt = v.sealedAt { dict["sealedAt"] = sealedAt }
        if let activatedAt = v.activatedAt { dict["activatedAt"] = activatedAt }
        if let reopenedAt = v.reopenedAt { dict["reopenedAt"] = reopenedAt }
        let data = try JSONSerialization.data(withJSONObject: dict)
        return try JSONDecoder().decode(Board.self, from: data)
    }

    private func ms(_ iso: String) throws -> Double {
        let date = try XCTUnwrap(DateFormatting.parseISO(iso), "unparseable \(iso)")
        return (date.timeIntervalSince1970 * 1000).rounded()
    }

    func testDeadlineVectors() throws {
        let fixture = try loadFixture()
        XCTAssertGreaterThanOrEqual(fixture.deadlines.count, 15)
        for v in fixture.deadlines {
            let tf = try XCTUnwrap(Timeframe(rawValue: v.board.timeframe), v.name)
            let deadline = computeAutoCloseDeadlineMs(
                timeframe: tf,
                startDate: v.board.startDate,
                endDate: v.board.endDate,
                activatedAt: v.board.activatedAt
            )
            if let expected = v.expectedDeadline {
                XCTAssertEqual(deadline, try ms(expected), "Vector '\(v.name)'")
            } else {
                XCTAssertNil(deadline, "Vector '\(v.name)'")
            }
        }
    }

    func testPastBackstopVectors() throws {
        let fixture = try loadFixture()
        XCTAssertGreaterThanOrEqual(fixture.pastBackstop.count, 8)
        for v in fixture.pastBackstop {
            let board = try makeBoard(v.board)
            XCTAssertEqual(isBoardPastBackstop(board, nowMs: try ms(v.now)), v.expected, "Vector '\(v.name)'")
        }
    }

    func testLifecycleVectors() throws {
        let fixture = try loadFixture()
        XCTAssertGreaterThanOrEqual(fixture.lifecycle.count, 8)
        for v in fixture.lifecycle {
            let board = try makeBoard(v.board)
            XCTAssertEqual(isBoardEnded(board, nowMs: try ms(v.now)), v.ended, "Vector '\(v.name)' ended")
            XCTAssertEqual(isBoardClosed(board), v.closed, "Vector '\(v.name)' closed")
        }
    }

    func testUnparseableEndDateNeverAutoCloses() {
        XCTAssertNil(computeAutoCloseDeadlineMs(
            timeframe: .daily, startDate: "2026-09-15T00:00:00.000", endDate: "not-a-date"
        ))
    }

    func testUnparseableActivatedAtIsIgnored() {
        let plain = computeAutoCloseDeadlineMs(
            timeframe: .daily, startDate: "2026-09-15T00:00:00.000", endDate: "2026-09-15T23:59:59.999"
        )
        let garbage = computeAutoCloseDeadlineMs(
            timeframe: .daily, startDate: "2026-09-15T00:00:00.000", endDate: "2026-09-15T23:59:59.999",
            activatedAt: "garbage"
        )
        XCTAssertNotNil(plain)
        XCTAssertEqual(plain, garbage)
    }

    func testUnparseableCustomStartFloorsGraceToOneDay() throws {
        XCTAssertEqual(
            computeAutoCloseDeadlineMs(timeframe: .custom, startDate: "garbage", endDate: "2026-07-10T12:00:00.000"),
            try ms("2026-07-11T12:00:00.000")
        )
    }
}
