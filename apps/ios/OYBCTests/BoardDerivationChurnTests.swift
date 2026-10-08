import XCTest
import GRDB
@testable import OYBC

/// Sync churn (owner's Firestore: boards at v3517 / v14639, every launch
/// re-pushing every live board). Twin of web's `boardDerivationChurn.test.ts`:
///
///  F1 — a board derivation write only happens (version bump + enqueue) when a
///       derived field actually changed (`boardDerivedStateChanged`).
///  F2 — the pull path skips a row identical to the stored one (same version +
///       updatedAt — an echo of this device's own push): no upsert, no cascade.
///
/// Drives the real entry points (`SyncService.applyRemoteSubdoc` /
/// `applyTaskEventsBatch`, the `AppDatabase` cascades, `completeTaskOrchestrated`)
/// against `AppDatabase.makeTestInstance()`.
@MainActor
final class BoardDerivationChurnTests: XCTestCase {

    private let userId = "u1"
    // UUID-format ids: the pull validator rejects anything else.
    private let boardId = "20000000-0000-4000-8000-000000000001"
    private let draftId = "20000000-0000-4000-8000-000000000002"
    private let start = "2026-07-01T00:00:00.000Z"
    private let end = "2099-12-31T23:59:59.999Z"
    private let inWindow = "2026-07-02T12:00:00.000Z"

    private let tasksCol = (firestoreName: "tasks", grdbTable: "tasks")
    private let boardsCol = (firestoreName: "boards", grdbTable: "boards")
    private let boardTasksCol = (firestoreName: "boardTasks", grdbTable: "board_tasks")

    // MARK: - Fixtures

    private func makeDb() throws -> AppDatabase {
        let db = try AppDatabase.makeTestInstance()
        let now = AppDatabase.currentTimestamp()
        try db.saveUser(User(
            id: userId, email: "t@e.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
        return db
    }

    private func taskId(_ cell: Int) -> String { "10000000-0000-4000-8000-00000000000\(cell)" }
    private func placementId(_ board: String, _ cell: Int) -> String {
        "40000000-0000-4000-8000-\(board.suffix(4))0000000\(cell)"
    }
    private func eventId(_ cell: Int) -> String { "50000000-0000-4000-8000-00000000000\(cell)" }

    private func makeTask(_ id: String) -> Task {
        Task(
            id: id, userId: userId, title: "N", description: nil, type: .normal,
            action: nil, unit: nil, maxCount: nil, operatorType: nil, threshold: nil,
            referencedBoardId: nil, referencedTemplateId: nil, achievementTrigger: nil, requiredCount: nil,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: false, completedAt: nil, currentCount: nil,
            createdAt: start, updatedAt: start, lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil,
            timeframe: nil, startDate: nil, endDate: nil,
            sharedCounterId: nil, baseline: nil, lastSyncedCount: nil, createdInWizard: false
        )
    }

    private func saveBoard(_ db: AppDatabase, id: String, extra: [String: Any]) throws {
        var dict: [String: Any] = [
            "id": id, "userId": userId, "name": "B", "status": "active",
            "boardSize": 3, "timeframe": Timeframe.daily.rawValue,
            "startDate": start, "endDate": end,
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": start, "updatedAt": start, "version": 7, "isDeleted": false,
        ]
        for (k, v) in extra { dict[k] = v }
        let data = try JSONSerialization.data(withJSONObject: dict)
        try db.saveBoard(try JSONDecoder().decode(Board.self, from: data))
    }

    private func place(_ db: AppDatabase, board: String, cell: Int) throws {
        try db.saveBoardTask(BoardTask(
            id: placementId(board, cell), boardId: board, taskId: taskId(cell),
            row: cell / 3, col: cell % 3,
            isCenter: false, createdAt: start, updatedAt: start, lastSyncedAt: nil, version: 1
        ))
    }

    private func completionEvent(_ cell: Int) -> TaskEvent {
        TaskEvent(
            id: eventId(cell), userId: userId, taskId: taskId(cell), kind: .completion, delta: nil,
            occurredAt: inWindow, boardId: nil, createdAt: inWindow, updatedAt: inWindow,
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        )
    }

    /// A 3×3 board with every task placed; the first `completed` cells carry an
    /// in-window completion event, and the stored stats are already the CORRECT
    /// derivation (3 → row_0 bingo). The sync queue is emptied after seeding.
    private func seedConvergedBoard(_ db: AppDatabase, completed: Int) throws {
        let lines = completed >= 3 ? ["row_0"] : []
        var extra: [String: Any] = ["completedTasks": completed, "linesCompleted": lines.count]
        // GRDB-row shape: the JSON array column is a JSON string.
        if !lines.isEmpty { extra["completedLineIds"] = "[\"row_0\"]" }
        try saveBoard(db, id: boardId, extra: extra)
        for cell in 0..<9 {
            try db.saveTask(makeTask(taskId(cell)))
            try place(db, board: boardId, cell: cell)
        }
        try db.write { txn in
            for cell in 0..<completed { try self.completionEvent(cell).save(txn) }
        }
        try clearQueue(db)
    }

    private func clearQueue(_ db: AppDatabase) throws {
        try db.write { try $0.execute(sql: "DELETE FROM sync_queue") }
    }

    private func board(_ db: AppDatabase, _ id: String? = nil) throws -> Board {
        try XCTUnwrap(try db.fetchBoard(id: id ?? boardId))
    }

    private func queueCount(_ db: AppDatabase) throws -> Int {
        try db.read { try SyncQueueItem.fetchCount($0) }
    }

    private func boardQueueCount(_ db: AppDatabase, _ id: String? = nil) throws -> Int {
        try db.read {
            try SyncQueueItem
                .filter(Column("entityType") == "boards" && Column("entityId") == (id ?? boardId))
                .fetchCount($0)
        }
    }

    /// What this device pushed for a row — the model's encoding, expanded to
    /// the Firestore wire shape exactly as `writeFirestoreDoc` does.
    private func wireDict<T: Encodable>(_ value: T) throws -> [String: Any] {
        let data = try JSONEncoder().encode(value)
        let dict = try XCTUnwrap(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        // `writeFirestoreDoc` strips nil / NSNull values before writing.
        return SyncWirePayload.expandJSONStrings(dict).filter { !($0.value is NSNull) }
    }

    // MARK: - F2: identical echoes are skipped

    func test_echoesOfOwnTaskPlacementAndBoard_leaveTheBoardUntouched() throws {
        let db = try makeDb()
        try seedConvergedBoard(db, completed: 3)
        let before = try board(db)
        let sut = SyncService(database: db)

        let task = try XCTUnwrap(try db.fetchTask(id: taskId(0)))
        let bt = try XCTUnwrap(try db.read { try BoardTask.fetchOne($0, key: self.placementId(self.boardId, 0)) })
        XCTAssertFalse(sut.applyRemoteSubdoc(collection: tasksCol, remoteData: try wireDict(task), authenticatedUserId: userId))
        XCTAssertFalse(sut.applyRemoteSubdoc(collection: boardTasksCol, remoteData: try wireDict(bt), authenticatedUserId: userId))
        XCTAssertFalse(sut.applyRemoteSubdoc(collection: boardsCol, remoteData: try wireDict(before), authenticatedUserId: userId))

        let after = try board(db)
        XCTAssertEqual(after.version, before.version)
        XCTAssertEqual(after.updatedAt, before.updatedAt)
        XCTAssertEqual(try queueCount(db), 0)

        // Positive control: the same wire dicts DO apply once they genuinely
        // differ — so the `false`s above are the echo guard, not a validation
        // reject.
        var newerBt = try wireDict(bt)
        newerBt["version"] = 2
        newerBt["updatedAt"] = inWindow
        XCTAssertTrue(sut.applyRemoteSubdoc(collection: boardTasksCol, remoteData: newerBt, authenticatedUserId: userId))
        var newerBoard = try wireDict(before)
        newerBoard["version"] = 8
        newerBoard["updatedAt"] = inWindow
        XCTAssertTrue(sut.applyRemoteSubdoc(collection: boardsCol, remoteData: newerBoard, authenticatedUserId: userId))
    }

    /// The batch full-sync pull (`processPullCollection` → `applyPullBatch`)
    /// — the path the owner's re-pull replay went through.
    func test_batchPullPath_skipsEchoes_andAppliesANewerRow() async throws {
        let db = try makeDb()
        try seedConvergedBoard(db, completed: 3)
        let before = try board(db)
        let task = try XCTUnwrap(try db.fetchTask(id: taskId(0)))
        let bt = try XCTUnwrap(try db.read { try BoardTask.fetchOne($0, key: self.placementId(self.boardId, 0)) })

        var pulled = 0, conflicts = 0
        for (col, doc) in [(tasksCol, try wireDict(task)), (boardTasksCol, try wireDict(bt)), (boardsCol, try wireDict(before))] {
            let outcome = try await db.applyPullBatch(collection: col, docs: PullDocs(docs: [doc]), userId: userId, checkpoint: true)
            pulled += outcome.pulled
            conflicts += outcome.conflicts
        }

        XCTAssertEqual(pulled, 0)
        XCTAssertEqual(conflicts, 0)
        let after = try board(db)
        XCTAssertEqual(after.version, before.version)
        XCTAssertEqual(after.updatedAt, before.updatedAt)
        XCTAssertEqual(try queueCount(db), 0)

        // Positive control: a genuinely newer row through the same path applies.
        var newer = try wireDict(task)
        newer["title"] = "Renamed elsewhere"
        newer["version"] = 2
        newer["updatedAt"] = inWindow
        let applied = try await db.applyPullBatch(collection: tasksCol, docs: PullDocs(docs: [newer]), userId: userId, checkpoint: true)
        XCTAssertEqual(applied.pulled, 1)
        XCTAssertEqual(try db.fetchTask(id: taskId(0))?.title, "Renamed elsewhere")
        XCTAssertEqual(try board(db).version, before.version, "stats unchanged → still no board bump")
    }

    func test_echoedEventBatch_appliesNothingAndPushesNothing() throws {
        let db = try makeDb()
        try seedConvergedBoard(db, completed: 3)
        let sut = SyncService(database: db)
        let events = try db.read { try TaskEvent.fetchAll($0) }

        let result = sut.applyTaskEventsBatch(userId: userId, rawDocs: try events.map { try wireDict($0) })

        XCTAssertEqual(result.pulled, 0)
        XCTAssertEqual(try board(db).version, 7)
        XCTAssertEqual(try queueCount(db), 0)
    }

    // MARK: - F1: pull cascades only write on a real change

    func test_newerTaskRowWithUnchangedStats_doesNotBumpTheBoard() throws {
        let db = try makeDb()
        try seedConvergedBoard(db, completed: 3)
        let sut = SyncService(database: db)
        var remote = try wireDict(try XCTUnwrap(try db.fetchTask(id: taskId(4))))
        remote["title"] = "Renamed elsewhere"
        remote["version"] = 2
        remote["updatedAt"] = inWindow

        XCTAssertTrue(sut.applyRemoteSubdoc(collection: tasksCol, remoteData: remote, authenticatedUserId: userId))

        XCTAssertEqual(try db.fetchTask(id: taskId(4))?.title, "Renamed elsewhere")
        XCTAssertEqual(try board(db).version, 7)
        XCTAssertEqual(try boardQueueCount(db), 0)
    }

    func test_pullThatChangesDerivedState_bumpsOnceAndEnqueuesOnce() throws {
        let db = try makeDb()
        try seedConvergedBoard(db, completed: 2)
        let sut = SyncService(database: db)

        let result = sut.applyTaskEventsBatch(userId: userId, rawDocs: [try wireDict(completionEvent(2))])

        XCTAssertEqual(result.pulled, 1)
        let after = try board(db)
        XCTAssertEqual(after.completedTasks, 3)
        XCTAssertEqual(after.completedLineIds, ["row_0"])
        XCTAssertEqual(after.version, 8)
        XCTAssertEqual(try boardQueueCount(db), 1)
    }

    // MARK: - F1: local cascades skip a no-op write

    func test_localCascadeOnConvergedBoard_writesNothing() throws {
        let db = try makeDb()
        try seedConvergedBoard(db, completed: 3)
        let before = try board(db)

        try db.write { txn in
            try AppDatabase.runBoardCascadeForTasks(
                db: txn, changedTaskIds: [self.taskId(0), self.taskId(5)], now: AppDatabase.currentTimestamp()
            )
        }

        let after = try board(db)
        XCTAssertEqual(after.version, before.version)
        XCTAssertEqual(after.updatedAt, before.updatedAt)
        XCTAssertEqual(try queueCount(db), 0)
    }

    func test_pullCascadesOnConvergedBoard_writeNothing() throws {
        let db = try makeDb()
        try seedConvergedBoard(db, completed: 3)

        try db.write { txn in
            try AppDatabase.runPullCascadeForTasks(db: txn, changedTaskIds: [self.taskId(1)], ownerUid: self.userId)
            try AppDatabase.runPullCascadeForBoardTask(db: txn, boardId: self.boardId, ownerUid: self.userId)
        }

        XCTAssertEqual(try board(db).version, 7)
        XCTAssertEqual(try queueCount(db), 0)
    }

    func test_cascadeResultsStillReportedForAnUnchangedBoard() throws {
        let db = try makeDb()
        try seedConvergedBoard(db, completed: 3)

        let results = try db.write { txn in
            try AppDatabase.runBoardCascadeForTaskWithResults(
                db: txn, changedTaskId: self.taskId(0), now: AppDatabase.currentTimestamp()
            )
        }

        let entry = try XCTUnwrap(results[boardId])
        XCTAssertEqual(entry.update.completedLineIds, ["row_0"])
        XCTAssertTrue(entry.update.newBingos.isEmpty)
        XCTAssertEqual(try board(db).version, 7)
        XCTAssertEqual(try queueCount(db), 0)
    }

    func test_emptyDraft_isDerivedButNeverRewrittenWhenUnchanged() throws {
        let db = try makeDb()
        try seedConvergedBoard(db, completed: 3)
        try saveBoard(db, id: draftId, extra: ["status": "draft", "version": 14639])
        try place(db, board: draftId, cell: 8)
        try clearQueue(db)

        try db.write { txn in
            try AppDatabase.runBoardCascadeForTasks(
                db: txn, changedTaskIds: [self.taskId(8)], now: AppDatabase.currentTimestamp()
            )
        }

        XCTAssertEqual(try board(db, draftId).version, 14639)
        XCTAssertEqual(try boardQueueCount(db, draftId), 0)
    }

    // MARK: - F1: a real completion still bumps once + reports the bingo

    func test_completingTheThirdCellOfRow0_bumpsOnceAndReportsTheBingo() throws {
        let db = try makeDb()
        try seedConvergedBoard(db, completed: 2)
        let bt = try XCTUnwrap(try db.read { try BoardTask.fetchOne($0, key: self.placementId(self.boardId, 2)) })

        let results = try db.completeTaskOrchestrated(
            board: try board(db), taskId: taskId(2), intent: .setCompleted(true),
            boardTask: bt, now: AppDatabase.currentTimestamp()
        )

        XCTAssertEqual(results[boardId]?.update.newBingos, ["row_0"])
        let after = try board(db)
        XCTAssertEqual(after.completedTasks, 3)
        XCTAssertEqual(after.version, 8)
        XCTAssertEqual(try boardQueueCount(db), 1)
    }
}
