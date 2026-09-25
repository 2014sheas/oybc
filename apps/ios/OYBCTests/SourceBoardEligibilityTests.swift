import XCTest
@testable import OYBC

/// Twin of `packages/shared/tests/algorithms/sourceBoardEligibility.test.ts`.
/// Keep the two suites in lockstep — they pin the same cross-platform rule
/// for which boards the wizard may offer as (and pull supply from as)
/// sources. Owner ruling 2026-09-24 (supersedes #482's 30-day lookback):
/// "There is no REAL use case for ended boards as sources." The shared
/// pin is `eligibilityVectors` in `boardSourceVectors.json`.
final class SourceBoardEligibilityTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_789_000_000) // fixed instant
    private let day: TimeInterval = 24 * 60 * 60

    /// An ISO timestamp `seconds` from `now` (negative = before).
    private func iso(_ seconds: TimeInterval) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: now.addingTimeInterval(seconds))
    }

    /// A board candidate; defaults to an active, unsealed board whose window is open.
    private func candidate(
        status: BoardStatus = .active,
        endDate: String? = nil,
        /// Set false to omit `endDate` entirely (an INDEFINITE board).
        hasEndDate: Bool = true,
        sealedAt: String? = nil,
        isDeleted: Bool = false
    ) -> Board {
        var dict: [String: Any] = [
            "id": "b1",
            "userId": "u1",
            "name": "Board",
            "status": status.rawValue,
            "boardSize": 3,
            "timeframe": Timeframe.monthly.rawValue,
            "startDate": iso(-20 * day),
            "centerSquareType": CenterSquareType.free.rawValue,
            "isRandomized": false,
            "totalTasks": 9,
            "completedTasks": 0,
            "linesCompleted": 0,
            "createdAt": iso(-20 * day),
            "updatedAt": iso(-20 * day),
            "version": 1,
            "isDeleted": isDeleted,
        ]
        if hasEndDate { dict["endDate"] = endDate ?? iso(5 * day) }
        if let sealedAt { dict["sealedAt"] = sealedAt }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    // MARK: - Ended boards are never sources

    func testExcludesABoardWhoseWindowEndedYesterday() {
        XCTAssertFalse(BoardSources.isEligibleSourceBoard(candidate(endDate: iso(-day)), now: now))
    }

    func testExcludesABoardWhoseWindowEndedASecondAgo_noLookback() {
        XCTAssertFalse(BoardSources.isEligibleSourceBoard(candidate(endDate: iso(-1)), now: now))
    }

    func testExcludesAnEndedCompletedBoard_completedAtBranchRetired() {
        XCTAssertFalse(BoardSources.isEligibleSourceBoard(
            candidate(status: .completed, endDate: iso(-3 * day)), now: now))
    }

    func testExcludesASealedBoardEvenWhenItsWindowLooksOpen() {
        XCTAssertFalse(BoardSources.isEligibleSourceBoard(candidate(sealedAt: iso(0)), now: now))
    }

    // MARK: - Open windows

    func testOffersAnActiveBoardWhoseWindowIsStillOpen() {
        XCTAssertTrue(BoardSources.isEligibleSourceBoard(candidate(), now: now))
    }

    func testOffersABoardWhoseWindowEndsExactlyNow_inclusive() {
        XCTAssertTrue(BoardSources.isEligibleSourceBoard(candidate(endDate: iso(0)), now: now))
    }

    func testOffersACompletedBoardWhoseWindowIsStillOpen() {
        XCTAssertTrue(BoardSources.isEligibleSourceBoard(candidate(status: .completed), now: now))
    }

    func testOffersAnIndefiniteBoardForever() {
        XCTAssertTrue(BoardSources.isEligibleSourceBoard(candidate(hasEndDate: false), now: now))
    }

    func testFailsOpenOnAnUnparseableEndDate() {
        XCTAssertTrue(BoardSources.isEligibleSourceBoard(candidate(endDate: "not-a-date"), now: now))
    }

    // MARK: - Never a source

    func testExcludesDraftsArchivedAndDeletedBoards() {
        XCTAssertFalse(BoardSources.isEligibleSourceBoard(candidate(status: .draft), now: now))
        XCTAssertFalse(BoardSources.isEligibleSourceBoard(candidate(status: .archived), now: now))
        XCTAssertFalse(BoardSources.isEligibleSourceBoard(candidate(isDeleted: true), now: now))
    }

    func testHonoursAnExplicitNowRatherThanTheWallClock() {
        // Open at `now`, ended a year later. If `now` were ignored, both agree.
        let b = candidate()
        XCTAssertTrue(BoardSources.isEligibleSourceBoard(b, now: now))
        XCTAssertFalse(BoardSources.isEligibleSourceBoard(b, now: now.addingTimeInterval(365 * day)))
    }
}
