import GRDB
import XCTest
@testable import OYBC

/// The "Add a pool or board" sheet's board rows.
///
/// Owner-reported (2026-09-16, with a screenshot): the sheet showed four
/// boards all named "Today" plus a "June 2026" board months out of window.
/// Both fixes had landed on `fetchEligibleSourceBoards` — which feeds the
/// *other* picker ("From a board") — while this sheet has its own fetcher
/// (`fetchSourceSheetBoardEntries`) that filtered on `status == .active`
/// alone and returned the raw board.
///
/// These tests assert what the FETCHER ACTUALLY RETURNS, because the
/// helpers were correct all along; nothing called them here.
///
/// Twin of `apps/web/src/db/operations/__tests__/sourceSheetBoardEntries.test.ts`.
final class SourceSheetBoardEntriesTests: XCTestCase {

    private let userId = "u1"
    private let day: TimeInterval = 24 * 60 * 60

    private func makeDb() throws -> AppDatabase {
        let db = try AppDatabase.makeTestInstance()
        try db.write { grdb in
            try User(
                id: userId, email: "t@e.com", displayName: "T", photoURL: nil,
                preferences: User.encodePreferences(.defaults),
                createdAt: iso(Date()), updatedAt: iso(Date()),
                lastSyncedAt: nil, version: 1
            ).insert(grdb)
        }
        return db
    }

    private func iso(_ d: Date) -> String {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f.string(from: d)
    }

    private func daysAgo(_ n: Double) -> String { iso(Date().addingTimeInterval(-n * day)) }
    private func daysAhead(_ n: Double) -> String { iso(Date().addingTimeInterval(n * day)) }

    @discardableResult
    private func seedBoard(
        _ db: AppDatabase,
        id: String,
        name: String = "Board",
        status: String = "active",
        timeframe: String = "daily",
        startDate: String? = nil,
        endDate: String? = nil,
        completedAt: String? = nil,
        isCore: Bool = false,
        userId: String? = nil
    ) throws -> Board {
        var dict: [String: Any] = [
            "id": id, "userId": userId ?? self.userId, "name": name,
            "status": status, "boardSize": 3, "timeframe": timeframe,
            "startDate": startDate ?? daysAgo(1),
            "endDate": endDate ?? daysAhead(5),
            "centerSquareType": "none", "isRandomized": true, "isCore": isCore,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": daysAgo(1), "updatedAt": daysAgo(1),
            "version": 1, "isDeleted": false,
        ]
        if let completedAt { dict["completedAt"] = completedAt }
        let board = try JSONDecoder().decode(
            Board.self, from: JSONSerialization.data(withJSONObject: dict)
        )
        try db.write { grdb in try board.insert(grdb) }
        return board
    }

    // MARK: - Naming

    func test_healsAFrozenTodayName() throws {
        let db = try makeDb()
        try seedBoard(
            db, id: "core-1", name: "Today",
            startDate: "2026-03-15T00:00:00.000", endDate: daysAhead(5), isCore: true
        )

        let entries = try db.fetchSourceSheetBoardEntries(userId: userId)

        XCTAssertEqual(entries.count, 1)
        XCTAssertEqual(entries.first?.board.name, "Mar 15, 2026")
    }

    func test_twoFrozenTodayBoardsGetDifferentNames() throws {
        // The screenshot showed four indistinguishable "Today" rows.
        let db = try makeDb()
        try seedBoard(db, id: "a", name: "Today",
                      startDate: "2026-03-15T00:00:00.000", endDate: daysAhead(5), isCore: true)
        try seedBoard(db, id: "b", name: "Today",
                      startDate: "2026-03-16T00:00:00.000", endDate: daysAhead(5), isCore: true)

        let names = try db.fetchSourceSheetBoardEntries(userId: userId)
            .map { $0.board.name }.sorted()

        XCTAssertEqual(names, ["Mar 15, 2026", "Mar 16, 2026"])
        XCTAssertEqual(Set(names).count, 2)
    }

    // MARK: - Recency

    func test_excludesAnActiveBoardWhoseWindowClosedMonthsAgo() throws {
        // The "June 2026" row: still .active because it was never finished,
        // so the old `status == .active` filter kept offering it forever.
        let db = try makeDb()
        try seedBoard(db, id: "stale", name: "June 2026", timeframe: "monthly",
                      startDate: daysAgo(100), endDate: daysAgo(70))

        XCTAssertTrue(try db.fetchSourceSheetBoardEntries(userId: userId).isEmpty)
    }

    func test_keepsAnActiveBoardWhoseWindowClosedRecently() throws {
        let db = try makeDb()
        try seedBoard(db, id: "last-month", name: "Last month", timeframe: "monthly",
                      startDate: daysAgo(40), endDate: daysAgo(10))

        XCTAssertEqual(
            try db.fetchSourceSheetBoardEntries(userId: userId).map { $0.board.id },
            ["last-month"]
        )
    }

    func test_keepsAnActiveBoardWhoseWindowIsStillOpen() throws {
        let db = try makeDb()
        try seedBoard(db, id: "live", name: "Live")

        XCTAssertEqual(
            try db.fetchSourceSheetBoardEntries(userId: userId).map { $0.board.id },
            ["live"]
        )
    }

    func test_nowAdmitsARecentlyCompletedBoard() throws {
        // Deliberate behaviour change: the sheet shares the "From a board"
        // eligibility rule, so "build October's from September's" works here
        // too. Pinned so the change is intentional, not accidental drift.
        let db = try makeDb()
        try seedBoard(db, id: "done", name: "Finished", status: "completed",
                      endDate: daysAgo(4), completedAt: daysAgo(3))

        XCTAssertEqual(
            try db.fetchSourceSheetBoardEntries(userId: userId).map { $0.board.id },
            ["done"]
        )
    }

    // MARK: - Never a source

    func test_stillExcludesDraftsAndArchived() throws {
        let db = try makeDb()
        try seedBoard(db, id: "draft", status: "draft")
        try seedBoard(db, id: "archived", status: "archived")

        XCTAssertTrue(try db.fetchSourceSheetBoardEntries(userId: userId).isEmpty)
    }

    func test_doesNotReturnAnotherUsersBoards() throws {
        let db = try makeDb()
        // `boards.userId` is a real FK — the other user must exist.
        try db.write { grdb in
            try User(
                id: "u2", email: "o@e.com", displayName: "O", photoURL: nil,
                preferences: User.encodePreferences(.defaults),
                createdAt: self.iso(Date()), updatedAt: self.iso(Date()),
                lastSyncedAt: nil, version: 1
            ).insert(grdb)
        }
        try seedBoard(db, id: "mine")
        try seedBoard(db, id: "theirs", userId: "u2")

        XCTAssertEqual(
            try db.fetchSourceSheetBoardEntries(userId: userId).map { $0.board.id },
            ["mine"]
        )
    }
}
