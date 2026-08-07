import XCTest
import GRDB
@testable import OYBC

/// Regression coverage for the windowed-bingo-cascade fix.
///
/// Edit/structure cascades (and the app-open self-heal) must resolve bingo
/// lines against each board's `[startDate, ∞)` window — reading the event log,
/// never the lifetime `Task.isCompleted` cache. Before the fix, a cell holding
/// a task that is lifetime-complete but has NO in-window completion event was
/// counted into a bingo line while rendering un-green (a phantom `diag_*`).
///
/// Twin of web's `windowedBingoCascade` Vitest suite. Runs against an
/// in-memory `AppDatabase.makeTestInstance()`.
@MainActor
final class WindowedBingoCascadeTests: XCTestCase {

    private let userId = "u1"

    // Board window: June 2026. Events dated inside it are in-window.
    private let windowStart = "2026-06-01T00:00:00.000"
    private let windowEnd = "2026-06-30T23:59:59.999"
    private let inWindowInstant = "2026-06-15T12:00:00.000"

    // MARK: - Fixtures

    private func makeDb() throws -> AppDatabase { try AppDatabase.makeTestInstance() }

    private func seedUser(_ db: AppDatabase) throws {
        let now = AppDatabase.currentTimestamp()
        try db.saveUser(User(
            id: userId, email: "t@e.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
    }

    /// A normal task, optionally lifetime-complete (`isCompleted` cache).
    private func makeTask(_ id: String, isCompleted: Bool) -> Task {
        let now = AppDatabase.currentTimestamp()
        return Task(
            id: id, userId: userId, title: id, description: nil, type: .normal,
            action: nil, unit: nil, maxCount: nil,
            operatorType: nil, threshold: nil,
            referencedBoardId: nil, referencedTemplateId: nil,
            achievementTrigger: nil, requiredCount: nil,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: isCompleted, completedAt: isCompleted ? now : nil,
            currentCount: nil, createdAt: now, updatedAt: now,
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil,
            timeframe: nil, startDate: nil, endDate: nil,
            sharedCounterId: nil, baseline: nil,
            lastSyncedCount: nil, createdInWizard: false
        )
    }

    /// A 3×3 active board over the June-2026 window, `centerSquareType == .none`
    /// (no FREE auto-fill). `completedLineIds` can be pre-seeded to simulate a
    /// board that already carries a stale phantom line.
    private func make3x3Board(id: String, completedLineIds: [String]? = nil,
                              linesCompleted: Int = 0, completedTasks: Int = 0,
                              status: BoardStatus = .active, completedAt: String? = nil) -> Board {
        var dict: [String: Any] = [
            "id": id, "userId": userId, "name": "Board", "status": status.rawValue,
            "boardSize": 3, "timeframe": Timeframe.monthly.rawValue,
            "startDate": windowStart, "endDate": windowEnd,
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
            "totalTasks": 9, "completedTasks": completedTasks, "linesCompleted": linesCompleted,
            "createdAt": windowStart, "updatedAt": windowStart,
            "version": 1, "isDeleted": false,
        ]
        if let ids = completedLineIds {
            // Stored as a JSON *string* (Board's custom Codable), so encode it.
            dict["completedLineIds"] = String(data: try! JSONEncoder().encode(ids), encoding: .utf8)!
        }
        if let completedAt { dict["completedAt"] = completedAt }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    private func makeBoardTask(id: String, boardId: String, taskId: String,
                               row: Int, col: Int) -> BoardTask {
        let now = AppDatabase.currentTimestamp()
        return BoardTask(
            id: id, boardId: boardId, taskId: taskId, row: row, col: col,
            isCenter: false, createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        )
    }

    private func makeCompletionEvent(_ id: String, taskId: String, occurredAt: String) -> TaskEvent {
        let now = AppDatabase.currentTimestamp()
        return TaskEvent(
            id: id, userId: userId, taskId: taskId, kind: .completion, delta: nil,
            occurredAt: occurredAt, boardId: nil, createdAt: now, updatedAt: now,
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        )
    }

    /// Seed the main-diagonal setup: `t_a`(0,0) + `t_b`(1,1) are windowed-complete
    /// (in-window events); `t_c` is lifetime-complete only (cache true, no event).
    /// Places `t_a` + `t_b` on the board; leaves `t_c` for the cascade to place.
    private func seedDiagonalScenario(_ db: AppDatabase, boardId: String) throws {
        try db.saveTask(makeTask("t_a", isCompleted: true))
        try db.saveTask(makeTask("t_b", isCompleted: true))
        try db.saveTask(makeTask("t_c", isCompleted: true)) // lifetime cache only

        try db.saveBoardTask(makeBoardTask(id: "bt_a", boardId: boardId, taskId: "t_a", row: 0, col: 0))
        try db.saveBoardTask(makeBoardTask(id: "bt_b", boardId: boardId, taskId: "t_b", row: 1, col: 1))

        try db.write { db in
            try makeCompletionEvent("e_a", taskId: "t_a", occurredAt: inWindowInstant).save(db)
            try makeCompletionEvent("e_b", taskId: "t_b", occurredAt: inWindowInstant).save(db)
            // t_c: deliberately NO event → not complete in this board's window.
        }
    }

    // MARK: - 1. Structure cascade resolves the window, not the lifetime cache

    func test_addBoardTaskCascade_doesNotWritePhantomDiagonalFromLifetimeCache() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveBoard(make3x3Board(id: "b1"))
        try seedDiagonalScenario(db, boardId: "b1")

        // Placing t_c on the diagonal's third cell triggers the structure
        // cascade. Windowed resolution: t_c is NOT in-window complete, so the
        // main diagonal must NOT be counted.
        _ = try db.addBoardTaskToBoard("b1", taskId: "t_c", position: (row: 2, col: 2))

        let board = try db.fetchBoard(id: "b1")!
        XCTAssertFalse(
            (board.completedLineIds ?? []).contains("diag_main"),
            "phantom diag_main written from lifetime cache (pre-fix regression)"
        )
        XCTAssertEqual(board.completedLineIds ?? [], [], "no bingo line is windowed-complete")
        XCTAssertEqual(board.linesCompleted, 0)
        // Only t_a + t_b are windowed-complete.
        XCTAssertEqual(board.completedTasks, 2)
    }

    // MARK: - 2. Self-heal clears a pre-seeded phantom line

    func test_reDeriveActiveBoards_clearsPreSeededPhantomDiagonal() throws {
        let db = try makeDb(); try seedUser(db)
        // Board already carries a stale phantom line from the pre-fix cascade.
        try db.saveBoard(make3x3Board(id: "b1", completedLineIds: ["diag_main"],
                                      linesCompleted: 1, completedTasks: 3))
        try seedDiagonalScenario(db, boardId: "b1")
        // Also place t_c so the diagonal is fully populated (as the stale state
        // would have been).
        try db.saveBoardTask(makeBoardTask(id: "bt_c", boardId: "b1", taskId: "t_c", row: 2, col: 2))

        // Pre-condition: the phantom is present.
        XCTAssertEqual(try db.fetchBoard(id: "b1")!.completedLineIds ?? [], ["diag_main"])

        let changed = try db.reDeriveActiveBoards(userId: userId)
        XCTAssertTrue(changed.contains("b1"), "self-heal rewrote the stale board")

        let board = try db.fetchBoard(id: "b1")!
        XCTAssertEqual(board.completedLineIds ?? [], [], "phantom diag_main cleared by windowed re-derive")
        XCTAssertEqual(board.linesCompleted, 0)
        XCTAssertEqual(board.completedTasks, 2, "t_c is not windowed-complete")
    }

    // MARK: - 3. Self-heal is idempotent (converged board → no-op)

    func test_reDeriveActiveBoards_isIdempotentOnConvergedBoard() throws {
        let db = try makeDb(); try seedUser(db)
        try db.saveBoard(make3x3Board(id: "b1"))
        try seedDiagonalScenario(db, boardId: "b1")
        try db.saveBoardTask(makeBoardTask(id: "bt_c", boardId: "b1", taskId: "t_c", row: 2, col: 2))

        // First pass converges the board (completedTasks 0 → 2).
        _ = try db.reDeriveActiveBoards(userId: userId)
        let versionAfterFirst = try db.fetchBoard(id: "b1")!.version

        // Second pass must be a no-op: no write, no version bump.
        let changedAgain = try db.reDeriveActiveBoards(userId: userId)
        XCTAssertFalse(changedAgain.contains("b1"), "converged board is not rewritten")
        XCTAssertEqual(try db.fetchBoard(id: "b1")!.version, versionAfterFirst,
                       "idempotent: no version bump on a converged board")
    }

    // MARK: - 4. Self-heal reverts a phantom-COMPLETED board to ACTIVE

    func test_reDeriveActiveBoards_revertsPhantomGreenlogToActive() throws {
        let db = try makeDb(); try seedUser(db)
        // A board wrongly written COMPLETED by the pre-fix lifetime cascade: all 9
        // cells hold lifetime-complete tasks, but NONE has an in-window event, so
        // windowed resolution finds 0 complete → not a greenlog.
        try db.saveBoard(make3x3Board(
            id: "b1",
            completedLineIds: ["row_0", "row_1", "row_2", "col_0", "col_1", "col_2", "diag_main", "diag_anti"],
            linesCompleted: 8, completedTasks: 9,
            status: .completed, completedAt: inWindowInstant
        ))
        for cell in 0..<9 {
            let tid = "t\(cell)"
            try db.saveTask(makeTask(tid, isCompleted: true)) // lifetime cache only, no event
            try db.saveBoardTask(makeBoardTask(id: "bt\(cell)", boardId: "b1", taskId: tid,
                                               row: cell / 3, col: cell % 3))
        }

        let changed = try db.reDeriveActiveBoards(userId: userId)
        XCTAssertTrue(changed.contains("b1"), "self-heal rewrote the phantom-completed board")

        let board = try db.fetchBoard(id: "b1")!
        XCTAssertEqual(board.status, .active, "phantom greenlog reverted to ACTIVE")
        XCTAssertNil(board.completedAt, "completedAt cleared on revert")
        XCTAssertEqual(board.completedLineIds ?? [], [], "all phantom lines cleared")
        XCTAssertEqual(board.completedTasks, 0, "no cell is windowed-complete")
    }
}
