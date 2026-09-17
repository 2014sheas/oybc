import XCTest
@testable import OYBC

/// Twin of `packages/shared/tests/algorithms/sourceBoardEligibility.test.ts`.
/// Keep the two suites in lockstep — they pin the same cross-platform rule
/// for which boards the wizard may offer as sources.
final class SourceBoardEligibilityTests: XCTestCase {

    private let now = Date(timeIntervalSince1970: 1_789_000_000) // fixed instant
    private let day: TimeInterval = 24 * 60 * 60

    /// An ISO timestamp `days` before `now`.
    private func daysAgo(_ days: Double) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: now.addingTimeInterval(-days * day))
    }

    /// An ISO timestamp `days` after `now`.
    private func daysAhead(_ days: Double) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: now.addingTimeInterval(days * day))
    }

    /// A board candidate; defaults to an active board whose window is open.
    private func candidate(
        status: BoardStatus = .active,
        endDate: String? = nil,
        completedAt: String? = nil,
        isDeleted: Bool = false
    ) -> Board {
        var dict: [String: Any] = [
            "id": "b1",
            "userId": "u1",
            "name": "Board",
            "status": status.rawValue,
            "boardSize": 3,
            "timeframe": Timeframe.monthly.rawValue,
            "startDate": daysAgo(20),
            "centerSquareType": CenterSquareType.free.rawValue,
            "isRandomized": false,
            "totalTasks": 9,
            "completedTasks": 0,
            "linesCompleted": 0,
            "createdAt": daysAgo(20),
            "updatedAt": daysAgo(20),
            "version": 1,
            "isDeleted": isDeleted,
        ]
        dict["endDate"] = endDate ?? daysAhead(5)
        if let completedAt { dict["completedAt"] = completedAt }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    // MARK: - The defect being fixed: unbounded active boards

    func testExcludesAnActiveBoardWhoseWindowClosedLongAgo() {
        // The actual bug — a core board whose window passed without every
        // square filled stays .active forever and was offered indefinitely.
        let stale = candidate(endDate: daysAgo(240))
        XCTAssertFalse(BoardSources.isEligibleSourceBoard(stale, now: now))
    }

    func testStillOffersAnActiveBoardWhoseWindowClosedRecently() {
        // "Build October's board from September's" must keep working even
        // though September's board was never marked complete.
        let lastMonth = candidate(endDate: daysAgo(10))
        XCTAssertTrue(BoardSources.isEligibleSourceBoard(lastMonth, now: now))
    }

    func testDrawsTheLineAtTheLookbackWindow() {
        let lookback = Double(BoardSources.sourceBoardLookbackDays)
        XCTAssertTrue(BoardSources.isEligibleSourceBoard(
            candidate(endDate: daysAgo(lookback - 1)), now: now))
        XCTAssertFalse(BoardSources.isEligibleSourceBoard(
            candidate(endDate: daysAgo(lookback + 1)), now: now))
    }

    // MARK: - Open windows

    func testOffersAnActiveBoardWhoseWindowIsStillOpen() {
        XCTAssertTrue(BoardSources.isEligibleSourceBoard(candidate(), now: now))
    }

    func testFailsOpenOnAnUnparseableEndDate() {
        XCTAssertTrue(BoardSources.isEligibleSourceBoard(
            candidate(endDate: "not-a-date"), now: now))
    }

    // MARK: - Completed boards keep their existing rule

    func testOffersOneCompletedInsideTheWindow() {
        let b = candidate(status: .completed, completedAt: daysAgo(3))
        XCTAssertTrue(BoardSources.isEligibleSourceBoard(b, now: now))
    }

    func testDropsOneCompletedOutsideTheWindow() {
        let b = candidate(status: .completed, completedAt: daysAgo(90))
        XCTAssertFalse(BoardSources.isEligibleSourceBoard(b, now: now))
    }

    func testDropsCompletedWithMissingOrUnparseableCompletedAt() {
        XCTAssertFalse(BoardSources.isEligibleSourceBoard(
            candidate(status: .completed, completedAt: nil), now: now))
        XCTAssertFalse(BoardSources.isEligibleSourceBoard(
            candidate(status: .completed, completedAt: "nope"), now: now))
    }

    func testIgnoresEndDateForACompletedBoard() {
        // A board completed yesterday whose window ended months ago is
        // still a fine source.
        let b = candidate(status: .completed, endDate: daysAgo(200), completedAt: daysAgo(1))
        XCTAssertTrue(BoardSources.isEligibleSourceBoard(b, now: now))
    }

    // MARK: - Never a source

    func testExcludesDraftsAndArchivedAndDeleted() {
        XCTAssertFalse(BoardSources.isEligibleSourceBoard(candidate(status: .draft), now: now))
        XCTAssertFalse(BoardSources.isEligibleSourceBoard(candidate(status: .archived), now: now))
        XCTAssertFalse(BoardSources.isEligibleSourceBoard(candidate(isDeleted: true), now: now))
    }

    // MARK: - Clock independence

    func testHonoursAnExplicitNowRatherThanTheWallClock() {
        // A board that ended 10 days before `now` is eligible at `now`, but
        // not when judged from a year later. If `now` were ignored, both agree.
        let b = candidate(endDate: daysAgo(10))
        let muchLater = now.addingTimeInterval(365 * day)
        XCTAssertTrue(BoardSources.isEligibleSourceBoard(b, now: now))
        XCTAssertFalse(BoardSources.isEligibleSourceBoard(b, now: muchLater))
    }
}
