import XCTest
@testable import OYBC

/// Swift twin of `packages/shared/tests/algorithms/boardListSort.test.ts` —
/// pins `compareBoardsForList` (TimeframeFormatting.swift) to the same
/// ordering as the shared TS comparator. Mirrors that file's cases 1:1
/// against a fixed `now` so the two suites stay in lock-step (rule 6).
final class BoardListSortTests: XCTestCase {

    private let now = ISO8601DateFormatter.reference.date(from: "2026-06-15T12:00:00Z")!

    private func makeBoard(
        id: String = "b",
        status: BoardStatus = .active,
        timeframe: Timeframe = .custom,
        startDate: String = "2026-06-01T00:00:00.000Z",
        endDate: String? = "2026-06-30T00:00:00.000Z",
        sealedAt: String? = nil,
        updatedAt: String = "2026-06-01T00:00:00.000Z"
    ) -> Board {
        var dict: [String: Any] = [
            "id": id, "userId": "u", "name": "Board", "status": status.rawValue,
            "boardSize": 5, "timeframe": timeframe.rawValue,
            "startDate": startDate,
            "centerSquareType": "free", "isRandomized": true,
            "totalTasks": 25, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": startDate, "updatedAt": updatedAt,
            "version": 1, "isDeleted": false,
        ]
        if timeframe != .indefinite, let endDate {
            dict["endDate"] = endDate
        }
        if let sealedAt { dict["sealedAt"] = sealedAt }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    /// Sorts a list with the comparator against the fixed `now`, returning ids.
    private func sortIds(_ boards: [Board]) -> [String] {
        boards.sorted { compareBoardsForList($0, $1, now: now) }.map(\.id)
    }

    // MARK: - Cases mirroring boardListSort.test.ts

    func test_ordersActiveBoardsBeforeNonActiveBoards() {
        let active = makeBoard(id: "active", status: .active)
        let completed = makeBoard(id: "completed", status: .completed)
        XCTAssertEqual(sortIds([completed, active]), ["active", "completed"])
    }

    func test_withinActive_soonestEndDateFirst() {
        let soon = makeBoard(id: "soon", endDate: "2026-06-20T00:00:00.000Z")
        let later = makeBoard(id: "later", endDate: "2026-06-28T00:00:00.000Z")
        XCTAssertEqual(sortIds([later, soon]), ["soon", "later"])
    }

    func test_withinActive_indefiniteBoardsSortLast() {
        let dated = makeBoard(id: "dated", endDate: "2026-06-25T00:00:00.000Z")
        let indefinite = makeBoard(id: "indef", timeframe: .indefinite, endDate: nil)
        XCTAssertEqual(sortIds([indefinite, dated]), ["dated", "indef"])
    }

    func test_withinActive_sameEndDateBreaksTiesByMostRecentActivity() {
        let stale = makeBoard(
            id: "stale", endDate: "2026-06-25T00:00:00.000Z",
            updatedAt: "2026-06-02T00:00:00.000Z"
        )
        let fresh = makeBoard(
            id: "fresh", endDate: "2026-06-25T00:00:00.000Z",
            updatedAt: "2026-06-10T00:00:00.000Z"
        )
        XCTAssertEqual(sortIds([stale, fresh]), ["fresh", "stale"])
    }

    func test_withinNonActive_mostRecentActivityFirst() {
        let older = makeBoard(id: "older", status: .completed, updatedAt: "2026-06-05T00:00:00.000Z")
        let newer = makeBoard(id: "newer", status: .completed, updatedAt: "2026-06-12T00:00:00.000Z")
        XCTAssertEqual(sortIds([older, newer]), ["newer", "older"])
    }

    func test_expiredActiveBoardSortsAsNonActive() {
        let active = makeBoard(id: "active", endDate: "2026-06-25T00:00:00.000Z")
        let expired = makeBoard(id: "expired", status: .active, endDate: "2026-06-01T00:00:00.000Z") // before now
        XCTAssertEqual(sortIds([expired, active]), ["active", "expired"])
    }

    func test_sealedActiveBoardSortsAsNonActive() {
        let active = makeBoard(id: "active", endDate: "2026-06-25T00:00:00.000Z")
        let sealed = makeBoard(
            id: "sealed", status: .active, endDate: "2026-06-20T00:00:00.000Z",
            sealedAt: "2026-06-10T00:00:00.000Z"
        )
        XCTAssertEqual(sortIds([sealed, active]), ["active", "sealed"])
    }

    func test_mixedAllTab_activeByDeadlineThenNonActiveByRecency() {
        let activeSoon = makeBoard(id: "activeSoon", endDate: "2026-06-18T00:00:00.000Z")
        let activeLate = makeBoard(id: "activeLate", endDate: "2026-06-29T00:00:00.000Z")
        let activeIndef = makeBoard(id: "activeIndef", timeframe: .indefinite, endDate: nil)
        let doneOld = makeBoard(id: "doneOld", status: .completed, updatedAt: "2026-06-03T00:00:00.000Z")
        let doneNew = makeBoard(id: "doneNew", status: .completed, updatedAt: "2026-06-14T00:00:00.000Z")
        XCTAssertEqual(
            sortIds([doneOld, activeLate, doneNew, activeIndef, activeSoon]),
            ["activeSoon", "activeLate", "activeIndef", "doneNew", "doneOld"]
        )
    }

    func test_draftBoardsSortWithNonActiveRecencyGroup() {
        let active = makeBoard(id: "active", endDate: "2026-06-25T00:00:00.000Z")
        let draftOld = makeBoard(id: "draftOld", status: .draft, updatedAt: "2026-06-04T00:00:00.000Z")
        let draftNew = makeBoard(id: "draftNew", status: .draft, updatedAt: "2026-06-11T00:00:00.000Z")
        XCTAssertEqual(sortIds([draftOld, active, draftNew]), ["active", "draftNew", "draftOld"])
    }
}

private extension ISO8601DateFormatter {
    /// Shared formatter for parsing fixed test timestamps.
    static let reference: ISO8601DateFormatter = ISO8601DateFormatter()
}
