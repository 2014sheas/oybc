import XCTest
import GRDB
@testable import OYBC

/// Board Edit redesign slice 2 (T2) — `BoardPlayViewModel+BoardActions`'s
/// plain `async throws` write paths (Repeat / Archive / Delete), against an
/// injected in-memory `AppDatabase.makeTestInstance()`.
///
/// The test methods are ordinary SYNCHRONOUS `throws` functions (not
/// `async throws`) — matching every other VM test file in this target.
/// `RunLoop.current.run(until:)`-based `waitUntil` polling only reliably
/// pumps `DispatchQueue.main.async` callbacks when the test method itself
/// is running directly on the XCTest runner's (main) thread; inside an
/// `async` test method the run loop spin does not reliably observe those
/// callbacks (measured: every `loadedVM` wait maxed its 30s timeout, and
/// the one assertion that actually depended on the reload having applied —
/// `editSourceTemplate` — failed). Each async VM call is bridged with a
/// `_Concurrency.Task` + a completion flag polled the same way, mirroring
/// `BoardPlayViewModelTests.swift`'s house style throughout.
@MainActor
final class BoardPlayViewModelBoardActionsTests: XCTestCase {

    // MARK: - Fixtures

    private func makeDb() throws -> AppDatabase {
        try AppDatabase.makeTestInstance()
    }

    private func seedUser(_ db: AppDatabase, id: String = "u1") throws {
        let now = AppDatabase.currentTimestamp()
        try db.saveUser(User(
            id: id, email: "test@example.com", displayName: "Test User", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
    }

    private func makeBoard(
        id: String, userId: String = "u1", spawnedFromTemplateId: String? = nil,
        sealedAt: String? = nil, isDeleted: Bool = false
    ) -> Board {
        var dict: [String: Any] = [
            "id": id, "userId": userId, "name": "Board \(id)", "status": BoardStatus.active.rawValue,
            "boardSize": 1, "timeframe": Timeframe.monthly.rawValue,
            "startDate": "2026-06-01T00:00:00.000",
            "endDate": "2026-06-30T23:59:59.999",
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
            "totalTasks": 1, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": "2026-06-01T00:00:00.000", "updatedAt": "2026-06-01T00:00:00.000",
            "version": 1, "isDeleted": isDeleted,
        ]
        if let spawnedFromTemplateId { dict["spawnedFromTemplateId"] = spawnedFromTemplateId }
        if let sealedAt { dict["sealedAt"] = sealedAt }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    private func makeTask(_ id: String) -> Task {
        let now = AppDatabase.currentTimestamp()
        return Task(
            id: id, userId: "u1", title: "Task \(id)", type: .normal,
            operatorType: nil, threshold: nil, totalCompletions: 0, totalInstances: 0,
            isCompleted: false, createdAt: now, updatedAt: now, version: 1, isDeleted: false
        )
    }

    private func makeBoardTask(id: String, boardId: String, taskId: String, row: Int, col: Int) -> BoardTask {
        let now = AppDatabase.currentTimestamp()
        return BoardTask(
            id: id, boardId: boardId, taskId: taskId, row: row, col: col, isCenter: false,
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        )
    }

    private func makeTemplate(
        id: String, userId: String = "u1", timeframe: Timeframe = .weekly, isActive: Bool = true
    ) -> RecurringBoardTemplate {
        RecurringBoardTemplate(
            id: id, userId: userId, name: "Repeating Board", timeframe: timeframe,
            boardSize: 1, centerSquareType: .none, isRandomized: false,
            seedTaskIds: ["t1"], lastSpawnedWindowKey: nil, isActive: isActive,
            createdAt: "2026-06-01T00:00:00.000Z", updatedAt: "2026-06-01T00:00:00.000Z",
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        )
    }

    /// Pump the main run loop until `predicate` holds or `timeout` elapses —
    /// used both to wait out `reload()`'s background-then-main apply and to
    /// bridge an awaited VM call back to this synchronous test method.
    @discardableResult
    private func waitUntil(timeout: TimeInterval = 30, _ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !predicate() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return predicate()
    }

    private func loadedVM(_ db: AppDatabase, boardId: String) -> BoardPlayViewModel {
        let vm = BoardPlayViewModel(boardId: boardId, userId: "u1", database: db)
        vm.reload()
        _ = waitUntil { vm.board?.id == boardId }
        return vm
    }

    /// Bridges one of `BoardPlayViewModel`'s plain `async throws` methods
    /// back to this synchronous test method — dispatches it on a
    /// `_Concurrency.Task`, then polls `waitUntil` for completion.
    private func run(_ operation: @escaping () async throws -> Void) -> Error? {
        var caughtError: Error?
        var done = false
        _Concurrency.Task { @MainActor in
            do {
                try await operation()
            } catch {
                caughtError = error
            }
            done = true
        }
        XCTAssertTrue(waitUntil { done }, "the async operation never completed")
        return caughtError
    }

    // MARK: - saveRepeat(.startRepeating)

    func test_saveRepeat_startRepeating_mintsTemplate_andBackStampsBoard() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeTask("t1"))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b1", taskId: "t1", row: 0, col: 0))
        let vm = loadedVM(db, boardId: "b1")

        let error = run { try await vm.saveRepeat(.startRepeating(cadence: .weekly), weekStartDay: "monday") }
        XCTAssertNil(error)

        let saved = try XCTUnwrap(db.fetchBoard(id: "b1"))
        let templateId = try XCTUnwrap(saved.spawnedFromTemplateId, "the board is back-stamped")
        let template = try XCTUnwrap(db.dbQueue.read { d in
            try RecurringBoardTemplate.fetchOne(d, key: templateId)
        })
        XCTAssertEqual(template.timeframe, .weekly)
        XCTAssertEqual(template.userId, "u1")
    }

    // MARK: - saveRepeat(.setActive)

    func test_saveRepeat_setActive_flipsIsActive() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveRecurringBoardTemplate(makeTemplate(id: "tpl-1", isActive: true))
        try db.saveBoard(makeBoard(id: "b1", spawnedFromTemplateId: "tpl-1"))
        let vm = loadedVM(db, boardId: "b1")
        let template = try XCTUnwrap(vm.editSourceTemplate, "the source template resolves from the workspace load")

        let error = run { try await vm.saveRepeat(.setActive(template: template, isActive: false), weekStartDay: "monday") }
        XCTAssertNil(error)

        let saved = try db.dbQueue.read { d in try RecurringBoardTemplate.fetchOne(d, key: "tpl-1") }
        XCTAssertEqual(saved?.isActive, false)
    }

    // MARK: - deleteBoard

    func test_deleteBoard_tombstonesAndEnqueues() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        let vm = loadedVM(db, boardId: "b1")

        let error = run { try await vm.deleteBoard() }
        XCTAssertNil(error)

        let saved = try XCTUnwrap(db.fetchBoard(id: "b1"))
        XCTAssertTrue(saved.isDeleted)
        let queued = try db.dbQueue.read { d in
            try Int.fetchOne(
                d, sql: "SELECT COUNT(*) FROM sync_queue WHERE entityType = 'boards' AND entityId = ? AND operationType = 'delete'",
                arguments: ["b1"]
            ) ?? 0
        }
        XCTAssertGreaterThan(queued, 0, "the delete must enqueue a sync item or the row resurrects")
    }

    // MARK: - archiveBoard

    /// Migrated from `BoardPlayViewModelTests.
    /// test_handleEditArchive_setsBoardArchived_thenEmitsArchived` — Archive
    /// is now the plain `async throws` `archiveBoard()`, no `editEvent`.
    func test_archiveBoard_setsStatusArchived() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        let vm = loadedVM(db, boardId: "b1")

        let error = run { try await vm.archiveBoard() }
        XCTAssertNil(error)

        let saved = try XCTUnwrap(db.fetchBoard(id: "b1"))
        XCTAssertEqual(saved.status, .archived)
    }

    // MARK: - saveBoardDetails on a sealed board

    func test_saveBoardDetails_sealedBoard_throws() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1", sealedAt: "2026-09-01T00:00:00.000Z"))
        let vm = loadedVM(db, boardId: "b1")

        let error = run { try await vm.saveBoardDetails(AppDatabase.UpdateActiveBoardPatch(name: "Nope")) }
        XCTAssertEqual(error as? BoardEditError, .boardNotEditable)

        let after = try XCTUnwrap(db.fetchBoard(id: "b1"))
        XCTAssertEqual(after.name, "Board b1")
    }
}
