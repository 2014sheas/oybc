import XCTest
import GRDB
@testable import OYBC

/// Board Edit post-merge sweep — pull-path gaps (findings 1 + 3). Twin of web's
/// `boardPullLiveAndWatchers.test.ts`.
///
///  1. A pulled REOPEN (a board row sealed locally that arrives unsealed)
///     re-derives the board's LIVE stats from THIS device's event union —
///     non-authored (no version bump, no enqueue), inside the pull transaction.
///  2. Every pull cascade that changes a board (boards / boardTasks /
///     taskEvents) refreshes that board's achievement watchers — non-authored,
///     so a pull never pushes (no ping-pong).
///
/// Drives the REAL pull entry points (`SyncService.applyRemoteSubdoc` /
/// `applyTaskEventsBatch`) against `AppDatabase.makeTestInstance()` as the
/// receiving device ("B").
@MainActor
final class BoardPullLiveAndWatcherTests: XCTestCase {

    private let userId = "u1"
    private let boardsCol = (firestoreName: "boards", grdbTable: "boards")
    private let boardTasksCol = (firestoreName: "boardTasks", grdbTable: "board_tasks")

    private let start = "2026-07-01T00:00:00.000Z"
    private let end = "2026-07-01T23:59:59.999Z"
    private let inWindow = "2026-07-01T12:00:00.000Z"
    private let pastAutoClose = "2026-07-03T01:00:00.000Z"

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

    private func newId() -> String { AppDatabase.generateUUID() }

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

    private func makeWatcherTask(_ id: String, watching boardId: String, trigger: AchievementTrigger) -> Task {
        Task(
            id: id, userId: userId, title: "Watch", description: nil, type: .achievement,
            action: nil, unit: nil, maxCount: nil, operatorType: nil, threshold: nil,
            referencedBoardId: boardId, referencedTemplateId: nil,
            achievementTrigger: trigger, requiredCount: nil,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: false, completedAt: nil, currentCount: nil,
            createdAt: start, updatedAt: start, lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil,
            timeframe: nil, startDate: nil, endDate: nil,
            sharedCounterId: nil, baseline: nil, lastSyncedCount: nil, createdInWizard: false
        )
    }

    /// A 1×1 board's raw dict (what a pull delivers / what we seed from).
    private func boardDict(_ id: String, extra: [String: Any] = [:]) -> [String: Any] {
        var dict: [String: Any] = [
            "id": id, "userId": userId, "name": "B", "status": "active",
            "boardSize": 1, "timeframe": Timeframe.daily.rawValue,
            "startDate": start, "endDate": end,
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
            "totalTasks": 1, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": start, "updatedAt": start, "version": 1, "isDeleted": false,
        ]
        for (k, v) in extra { dict[k] = v }
        return dict
    }

    private func saveBoard(_ db: AppDatabase, _ dict: [String: Any]) throws {
        let data = try JSONSerialization.data(withJSONObject: dict)
        try db.saveBoard(try JSONDecoder().decode(Board.self, from: data))
    }

    private func placementDict(id: String, boardId: String, taskId: String) -> [String: Any] {
        [
            "id": id, "boardId": boardId, "taskId": taskId, "row": 0, "col": 0,
            "isCenter": false, "createdAt": start, "updatedAt": start, "version": 1, "isDeleted": false,
        ]
    }

    private func place(_ db: AppDatabase, boardId: String, taskId: String) throws {
        try db.saveBoardTask(BoardTask(
            id: newId(), boardId: boardId, taskId: taskId, row: 0, col: 0,
            isCenter: false, createdAt: start, updatedAt: start, lastSyncedAt: nil, version: 1
        ))
    }

    private func completionEventDict(taskId: String, occurredAt: String) -> [String: Any] {
        [
            "id": newId(), "userId": userId, "taskId": taskId, "kind": "completion",
            "occurredAt": occurredAt, "createdAt": occurredAt, "updatedAt": occurredAt,
            "version": 1, "isDeleted": false,
        ]
    }

    private func completeInWindow(_ db: AppDatabase, taskId: String) throws {
        try db.write { txn in
            try TaskEvent(
                id: self.newId(), userId: self.userId, taskId: taskId, kind: .completion, delta: nil,
                occurredAt: self.inWindow, boardId: nil,
                createdAt: self.inWindow, updatedAt: self.inWindow,
                lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
            ).save(txn)
        }
    }

    private func board(_ db: AppDatabase, _ id: String) throws -> Board { try XCTUnwrap(try db.fetchBoard(id: id)) }

    private func queuedRows(_ db: AppDatabase, _ entityId: String) throws -> Int {
        try db.read { try SyncQueueItem.filter(Column("entityId") == entityId).fetchCount($0) }
    }

    /// A WATCHER board placing a specific-board achievement on `watched`.
    private func seedWatcher(_ db: AppDatabase, watching watched: String, trigger: AchievementTrigger) throws -> String {
        let watcherBoard = newId(), ach = newId()
        try db.saveTask(makeWatcherTask(ach, watching: watched, trigger: trigger))
        try saveBoard(db, boardDict(watcherBoard))
        try place(db, boardId: watcherBoard, taskId: ach)
        return watcherBoard
    }

    // MARK: - 1. Pulled Reopen re-derives LIVE stats (non-authored)

    func test_pulledReopen_keepsThisDevicesLateLog_nonAuthored() throws {
        let db = try makeDb()
        let bid = newId(), tid = newId()
        try db.saveTask(makeTask(tid))
        try saveBoard(db, boardDict(bid))
        try place(db, boardId: bid, taskId: tid)
        // B: closed at 0/1, then a late log on its only square — the sealed
        // re-derive made B's snapshot 1/1 COMPLETED locally.
        try db.closeBoard(boardId: bid, now: pastAutoClose)
        try db.lateLogCompletion(boardId: bid, taskId: tid, now: "2026-07-04T00:00:00.000Z")
        let sealedLocal = try board(db, bid)
        XCTAssertEqual(sealedLocal.completedTasks, 1, "sanity: late log counted on the sealed record")
        let queuedBefore = try queuedRows(db, bid)

        // A never saw B's late log: it reopened at 0/1 ACTIVE, version bumped.
        let remote = boardDict(bid, extra: [
            "reopenedAt": "2026-07-05T00:00:00.000Z", "updatedAt": "2026-07-05T00:00:00.000Z",
            "version": sealedLocal.version + 1,
        ])
        let sut = SyncService(database: db)
        XCTAssertTrue(sut.applyRemoteSubdoc(collection: boardsCol, remoteData: remote, authenticatedUserId: userId))

        let after = try board(db, bid)
        XCTAssertNil(after.sealedAt)
        XCTAssertEqual(after.completedTasks, 1, "B's converged union (its late log) — not A's 0/1")
        XCTAssertEqual(after.status, .completed)
        XCTAssertEqual(after.version, sealedLocal.version + 1, "non-authored: the pulled version stands")
        XCTAssertEqual(try queuedRows(db, bid), queuedBefore, "non-authored: nothing pushed back")
    }

    // MARK: - 2. Pull cascades refresh achievement watchers (non-authored)

    func test_taskEventsPull_refreshesWatcher_nonAuthored() throws {
        let db = try makeDb()
        let watched = newId(), tid = newId()
        try db.saveTask(makeTask(tid))
        try saveBoard(db, boardDict(watched))
        try place(db, boardId: watched, taskId: tid)
        let watcherBoard = try seedWatcher(db, watching: watched, trigger: .bingo)
        let watcherBefore = try board(db, watcherBoard)

        let sut = SyncService(database: db)
        let result = sut.applyTaskEventsBatch(userId: userId, rawDocs: [completionEventDict(taskId: tid, occurredAt: inWindow)])
        XCTAssertEqual(result.pulled, 1)

        XCTAssertGreaterThan(try board(db, watched).linesCompleted, 0, "sanity: watched board bingos")
        let watcher = try board(db, watcherBoard)
        XCTAssertEqual(watcher.completedTasks, 1, "the watcher square must repaint on the pull")
        XCTAssertEqual(watcher.version, watcherBefore.version, "non-authored: no version bump")
        XCTAssertEqual(try queuedRows(db, watcherBoard), 0, "non-authored: nothing enqueued")
    }

    func test_boardTasksPull_refreshesWatcher_nonAuthored() throws {
        let db = try makeDb()
        let watched = newId(), tid = newId()
        try db.saveTask(makeTask(tid))
        try saveBoard(db, boardDict(watched))
        try completeInWindow(db, taskId: tid)
        let watcherBoard = try seedWatcher(db, watching: watched, trigger: .bingo)
        let watcherBefore = try board(db, watcherBoard)

        let sut = SyncService(database: db)
        XCTAssertTrue(sut.applyRemoteSubdoc(
            collection: boardTasksCol,
            remoteData: placementDict(id: newId(), boardId: watched, taskId: tid),
            authenticatedUserId: userId
        ))

        XCTAssertGreaterThan(try board(db, watched).linesCompleted, 0, "sanity: pulled placement bingos")
        let watcher = try board(db, watcherBoard)
        XCTAssertEqual(watcher.completedTasks, 1, "the watcher square must repaint on the pull")
        XCTAssertEqual(watcher.version, watcherBefore.version, "non-authored: no version bump")
        XCTAssertEqual(try queuedRows(db, watcherBoard), 0, "non-authored: nothing enqueued")
    }

    func test_boardsPull_refreshesWatcher_nonAuthored() throws {
        let db = try makeDb()
        let watched = newId()
        try saveBoard(db, boardDict(watched))
        let watcherBoard = try seedWatcher(db, watching: watched, trigger: .greenlog)
        let watcherBefore = try board(db, watcherBoard)

        let sut = SyncService(database: db)
        XCTAssertTrue(sut.applyRemoteSubdoc(
            collection: boardsCol,
            remoteData: boardDict(watched, extra: [
                "status": "completed", "completedTasks": 1, "linesCompleted": 1,
                "completedAt": inWindow, "updatedAt": inWindow, "version": 2,
            ]),
            authenticatedUserId: userId
        ))

        let watcher = try board(db, watcherBoard)
        XCTAssertEqual(watcher.completedTasks, 1, "the watcher square must repaint on the pull")
        XCTAssertEqual(watcher.version, watcherBefore.version, "non-authored: no version bump")
        XCTAssertEqual(try queuedRows(db, watcherBoard), 0, "non-authored: nothing enqueued")
    }
}
