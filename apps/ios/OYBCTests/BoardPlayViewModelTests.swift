import XCTest
import GRDB
@testable import OYBC

/// Tests for `BoardPlayViewModel` (B2-I1) against an injected in-memory
/// `AppDatabase.makeTestInstance()`.
///
/// Covers:
///   1. `reload()` populates all seven published arrays from the DB.
///   2. `reload()` with a nil userId leaves the user-scoped arrays empty
///      (matching the pre-refactor `loadTaskData` behavior) while the
///      board-scoped + global fetches still populate.
///   3. `reloadBoardTasksAndTaskData()` refreshes placements + task data but
///      never fetches the board record (partial scope preserved).
///   4. `boardChanged(to:)` re-points the view model at a new board.
///   5. The `reloadToken` stale-result guard: after two rapid reloads the
///      newest one wins and the stale result does not clobber it.
///
/// Reloads dispatch onto a background queue and apply on the main queue, so
/// the tests are `@MainActor` and pump the run loop via `waitUntil` — full
/// async ordering isn't controllable in XCTest, so the stale-guard test
/// asserts the observable invariant (last-write-wins, stable) rather than the
/// private token value.
@MainActor
final class BoardPlayViewModelTests: XCTestCase {

    // MARK: - Fixtures

    private func makeDb() throws -> AppDatabase {
        try AppDatabase.makeTestInstance()
    }

    private func seedUser(_ db: AppDatabase, id: String = "u1") throws {
        let now = AppDatabase.currentTimestamp()
        let user = User(
            id: id,
            email: "test@example.com",
            displayName: "Test User",
            photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now,
            updatedAt: now,
            lastSyncedAt: nil,
            version: 1
        )
        try db.saveUser(user)
    }

    /// Build a Board via JSON (the same path production uses).
    private func makeBoard(id: String, userId: String = "u1") -> Board {
        let dict: [String: Any] = [
            "id": id,
            "userId": userId,
            "name": "Board \(id)",
            "status": BoardStatus.active.rawValue,
            "boardSize": 3,
            "timeframe": Timeframe.monthly.rawValue,
            "startDate": "2026-06-21T00:00:00.000",
            "endDate": "2026-06-30T23:59:59.999",
            "centerSquareType": CenterSquareType.free.rawValue,
            "isRandomized": false,
            "totalTasks": 9,
            "completedTasks": 0,
            "linesCompleted": 0,
            "createdAt": "2026-06-21T00:00:00.000",
            "updatedAt": "2026-06-21T00:00:00.000",
            "version": 1,
            "isDeleted": false,
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    private func makeTask(_ id: String, userId: String = "u1") -> Task {
        let now = AppDatabase.currentTimestamp()
        return Task(
            id: id,
            userId: userId,
            title: "Task \(id)",
            description: nil,
            type: .normal,
            action: nil,
            unit: nil,
            maxCount: nil,
            operatorType: nil,
            threshold: nil,
            isOrdered: nil,
            referencedBoardId: nil,
            referencedTemplateId: nil,
            achievementTrigger: nil,
            requiredCount: nil,
            parentStepId: nil,
            parentStepIndex: nil,
            progressCounters: nil,
            totalCompletions: 0,
            totalInstances: 0,
            isCompleted: false,
            completedAt: nil,
            currentCount: nil,
            createdAt: now,
            updatedAt: now,
            lastSyncedAt: nil,
            version: 1,
            isDeleted: false,
            deletedAt: nil,
            timeframe: nil,
            startDate: nil,
            endDate: nil,
            sharedCounterId: nil,
            baseline: nil,
            lastSyncedCount: nil,
            createdInWizard: false
        )
    }

    private func makeBoardTask(id: String, boardId: String, taskId: String, row: Int, col: Int) -> BoardTask {
        let now = AppDatabase.currentTimestamp()
        return BoardTask(
            id: id,
            boardId: boardId,
            taskId: taskId,
            row: row,
            col: col,
            isCenter: false,
            createdAt: now,
            updatedAt: now,
            lastSyncedAt: nil,
            version: 1
        )
    }

    private func makeCompoundChild(parent: String, child: String, idx: Int) -> CompoundChild {
        CompoundChild(
            id: "\(parent)-\(child)-\(idx)",
            compoundTaskId: parent,
            childTaskId: child,
            childIndex: idx,
            createdAt: "2026-06-21T00:00:00.000",
            updatedAt: "2026-06-21T00:00:00.000",
            version: 1,
            isDeleted: false
        )
    }

    private func makeTemplate(id: String = "tmpl-1", userId: String = "u1") -> RecurringBoardTemplate {
        RecurringBoardTemplate(
            id: id,
            userId: userId,
            name: "Weekly",
            timeframe: .weekly,
            boardSize: 3,
            centerSquareType: .free,
            centerSquareCustomName: nil,
            isRandomized: false,
            seedTaskIds: ["t1", "t2"],
            lastSpawnedWindowKey: nil,
            isActive: true,
            createdAt: "2026-06-21T00:00:00.000",
            updatedAt: "2026-06-21T00:00:00.000",
            lastSyncedAt: nil,
            version: 1,
            isDeleted: false,
            deletedAt: nil
        )
    }

    /// Seed: user u1, board b1 (2 placements), board b2 (1 placement),
    /// tasks t1/t2, one compound-child link (t1→t2), one template.
    private func seedWorkspace(_ db: AppDatabase) throws {
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveBoard(makeBoard(id: "b2"))
        try db.saveTask(makeTask("t1"))
        try db.saveTask(makeTask("t2"))
        try db.saveBoardTask(makeBoardTask(id: "bt-b1-1", boardId: "b1", taskId: "t1", row: 0, col: 0))
        try db.saveBoardTask(makeBoardTask(id: "bt-b1-2", boardId: "b1", taskId: "t2", row: 0, col: 1))
        try db.saveBoardTask(makeBoardTask(id: "bt-b2-1", boardId: "b2", taskId: "t1", row: 0, col: 0))
        try db.dbQueue.write { database in
            try makeCompoundChild(parent: "t1", child: "t2", idx: 0).insert(database)
            try makeTemplate().insert(database)
        }
    }

    /// Pump the main run loop until `predicate` holds or `timeout` elapses.
    /// Lets the `DispatchQueue.main.async` apply blocks run. Returns whether
    /// the predicate held.
    @discardableResult
    private func waitUntil(
        timeout: TimeInterval = 2,
        _ predicate: () -> Bool
    ) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return predicate()
    }

    // MARK: - 1. reload populates everything

    func test_reload_populatesAllPublishedArrays() throws {
        let db = try makeDb()
        try seedWorkspace(db)

        let vm = BoardPlayViewModel(boardId: "b1", userId: "u1", database: db)
        vm.reload()

        XCTAssertTrue(waitUntil { vm.board != nil }, "reload never applied")

        XCTAssertEqual(vm.board?.id, "b1")
        XCTAssertEqual(vm.boardTasks.count, 2, "b1 has 2 placements")
        XCTAssertEqual(vm.allTasks.count, 2)
        XCTAssertEqual(vm.allCompoundChildren.count, 1)
        XCTAssertEqual(vm.allBoardsInWorkspace.count, 2)
        XCTAssertEqual(vm.allTemplatesInWorkspace.count, 1)
        XCTAssertEqual(vm.allBoardTasksInWorkspace.count, 3, "3 placements across b1+b2")
    }

    // MARK: - 2. nil userId

    func test_reload_withNilUserId_leavesUserScopedArraysEmpty() throws {
        let db = try makeDb()
        try seedWorkspace(db)

        // nil userId mirrors the view constructing the VM before its
        // @EnvironmentObject AuthService is available.
        let vm = BoardPlayViewModel(boardId: "b1", userId: nil, database: db)
        vm.reload()

        XCTAssertTrue(waitUntil { vm.board != nil }, "board fetch is not user-scoped and should still apply")

        // Board + its placements + the global tables load regardless of userId.
        XCTAssertEqual(vm.board?.id, "b1")
        XCTAssertEqual(vm.boardTasks.count, 2)
        XCTAssertEqual(vm.allCompoundChildren.count, 1)
        XCTAssertEqual(vm.allBoardTasksInWorkspace.count, 3)
        // User-scoped fetches resolve to empty.
        XCTAssertTrue(vm.allTasks.isEmpty)
        XCTAssertTrue(vm.allBoardsInWorkspace.isEmpty)
        XCTAssertTrue(vm.allTemplatesInWorkspace.isEmpty)
    }

    // MARK: - 3. partial reload never touches board

    func test_reloadBoardTasksAndTaskData_doesNotFetchBoard() throws {
        let db = try makeDb()
        try seedWorkspace(db)

        let vm = BoardPlayViewModel(boardId: "b1", userId: "u1", database: db)
        vm.reloadBoardTasksAndTaskData()

        XCTAssertTrue(waitUntil { !vm.boardTasks.isEmpty }, "partial reload never applied")

        XCTAssertNil(vm.board, "partial reload must not fetch the board record")
        XCTAssertEqual(vm.boardTasks.count, 2)
        XCTAssertEqual(vm.allTasks.count, 2)
    }

    // MARK: - 4. boardChanged

    func test_boardChanged_switchesBoardAndReloads() throws {
        let db = try makeDb()
        try seedWorkspace(db)

        let vm = BoardPlayViewModel(boardId: "b1", userId: "u1", database: db)
        vm.reload()
        XCTAssertTrue(waitUntil { vm.board?.id == "b1" && vm.boardTasks.count == 2 })

        vm.boardChanged(to: "b2")
        XCTAssertTrue(waitUntil { vm.board?.id == "b2" })

        XCTAssertEqual(vm.board?.id, "b2")
        XCTAssertEqual(vm.boardTasks.count, 1, "b2 has 1 placement")
    }

    // MARK: - 5. stale-result guard

    func test_staleGuard_newestReloadWins() throws {
        let db = try makeDb()
        try seedWorkspace(db)

        let vm = BoardPlayViewModel(boardId: "b1", userId: "u1", database: db)

        // Two rapid reloads with no wait in between: reload() (token N, board b1)
        // then boardChanged(to: "b2") (token N+1, board b2). The token guard
        // must drop the older b1 result so the newest (b2) wins.
        vm.reload()
        vm.boardChanged(to: "b2")

        XCTAssertTrue(waitUntil { vm.board?.id == "b2" }, "newest reload result never applied")
        XCTAssertEqual(vm.board?.id, "b2")
        XCTAssertEqual(vm.boardTasks.count, 1)

        // Spin the run loop further so any late (stale) b1 apply would have a
        // chance to fire; the guard must have dropped it, so state stays b2.
        RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        XCTAssertEqual(vm.board?.id, "b2", "a stale earlier reload clobbered the newer result")
        XCTAssertEqual(vm.boardTasks.count, 1)
    }
}
