import XCTest
import GRDB
@testable import OYBC

/// Seam tests (E3 / issue #299) for `SyncService.applyRemoteSubdoc(...)` — the
/// iOS pull-apply path. This is the integration boundary where several
/// well-tested pure units meet: `validateRemotePullDocument` → `resolveConflict`
/// (LWW) → `needsAdditiveMerge`/`additiveMergeCount` → `upsertLocalRecord` +
/// `runPullCascade`, all inside ONE GRDB write so a cascade failure rolls back
/// the upsert.
///
/// `SyncService` is constructed with an injected in-memory
/// `AppDatabase.makeTestInstance()` (E3 seam-injection: `init(database:)`); the
/// Firestore handle is `lazy`, so no `FirebaseApp.configure()` host is needed —
/// the pull-apply path is GRDB-only. `applyRemoteSubdoc` was widened to internal
/// (C4 precedent) so the test can feed crafted remote dicts directly.
///
/// Covers:
///   1. Remote-wins LWW → upsert lands AND the pull cascade recomputes board
///      stats, atomically (a `pulled` event fires, board version bumps).
///   2. Local-wins LWW → upsert skipped, no cascade, no pull event.
///   3. Cascade failure rolls back the upsert — a remote `tasks` doc with a
///      forward-incompatible `type` passes validation, upserts as a raw row,
///      then `runPullCascade`'s `Task.fetchAll` decode throws → the whole
///      transaction rolls back → the row never persists.
///   4. Additive-merge gate (the SharedCounterMerge integration seam): merge
///      fires only when ALL conditions hold (counting local+remote, both moved
///      off `lastSyncedCount`, and the task is a shared-counter source); a
///      non-source counting task falls through to plain LWW.
@MainActor
final class SyncPullApplyTests: XCTestCase {

    private let taskCol = (firestoreName: "tasks", grdbTable: "tasks")
    private let userId = "u1"

    // MARK: - Fixtures

    private func makeDb() throws -> AppDatabase {
        try AppDatabase.makeTestInstance()
    }

    private func makeSut(_ db: AppDatabase) -> SyncService {
        SyncService(database: db)
    }

    private func seedUser(_ db: AppDatabase, id: String = "u1") throws {
        let now = AppDatabase.currentTimestamp()
        let user = User(
            id: id, email: "t@e.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        )
        try db.saveUser(user)
    }

    private func makeTask(
        _ id: String, type: TaskType = .normal, title: String = "Task",
        version: Int = 1, isCompleted: Bool = false,
        currentCount: Int? = nil, lastSyncedCount: Int? = nil,
        sharedCounterId: String? = nil
    ) -> Task {
        let now = AppDatabase.currentTimestamp()
        return Task(
            id: id, userId: userId, title: title, description: nil, type: type,
            action: nil, unit: nil, maxCount: type == .counting ? 100 : nil,
            operatorType: nil, threshold: nil, isOrdered: nil,
            referencedBoardId: nil, referencedTemplateId: nil,
            achievementTrigger: nil, requiredCount: nil,
            parentStepId: nil, parentStepIndex: nil, progressCounters: nil,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: isCompleted, completedAt: isCompleted ? now : nil,
            currentCount: currentCount, createdAt: now, updatedAt: now,
            lastSyncedAt: nil, version: version, isDeleted: false, deletedAt: nil,
            timeframe: nil, startDate: nil, endDate: nil,
            sharedCounterId: sharedCounterId, baseline: nil,
            lastSyncedCount: lastSyncedCount, createdInWizard: false
        )
    }

    private func makeBoard(id: String, status: BoardStatus = .active) -> Board {
        let dict: [String: Any] = [
            "id": id, "userId": userId, "name": "Board", "status": status.rawValue,
            "boardSize": 3, "timeframe": Timeframe.monthly.rawValue,
            "startDate": "2026-06-01T00:00:00.000", "endDate": "2026-06-30T23:59:59.999",
            "centerSquareType": CenterSquareType.free.rawValue, "isRandomized": false,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": "2026-06-01T00:00:00.000", "updatedAt": "2026-06-01T00:00:00.000",
            "version": 1, "isDeleted": false,
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    private func makeBoardTask(id: String, boardId: String, taskId: String) -> BoardTask {
        let now = AppDatabase.currentTimestamp()
        return BoardTask(
            id: id, boardId: boardId, taskId: taskId, row: 0, col: 0,
            isCenter: false, createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        )
    }

    private func rawTaskCount(_ db: AppDatabase, id: String) throws -> Int {
        try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM tasks WHERE id = ?", arguments: [id]) ?? 0 }
    }

    private func syncRows(_ db: AppDatabase) throws -> [SyncQueueItem] {
        try db.fetchPendingSyncItems()
    }

    private func newId() -> String { AppDatabase.generateUUID() }

    // MARK: - 1. Remote-wins upsert + cascade, atomic

    func test_remoteWins_upsertLandsAndCascadeRecomputesBoardStats() throws {
        let db = try makeDb()
        try seedUser(db)
        let tid = newId()
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeTask(tid, version: 1, isCompleted: false))
        try db.saveBoardTask(makeBoardTask(id: "bt", boardId: "b1", taskId: tid))
        let sut = makeSut(db)

        // Remote marks the task complete at a higher version — remote wins.
        let remote: [String: Any] = [
            "id": tid, "userId": userId, "title": "Task", "type": "normal",
            "isCompleted": true, "version": 2,
            "updatedAt": "2026-06-02T00:00:00.000",
            "createdAt": "2026-06-01T00:00:00.000", "isDeleted": false,
        ]
        sut.applyRemoteSubdoc(collection: taskCol, remoteData: remote, authenticatedUserId: userId)

        // Upsert landed.
        let t = try XCTUnwrap(try db.fetchTask(id: tid))
        XCTAssertTrue(t.isCompleted)

        // Cascade recomputed board stats in the SAME write (version bumped by the
        // cascade UPDATE; 1 completed task + FREE center = 2 on a 3×3).
        let b = try XCTUnwrap(try db.fetchBoard(id: "b1"))
        XCTAssertEqual(b.completedTasks, 2)
        XCTAssertEqual(b.version, 2)

        // A pull event fired and the cascade enqueued a board push.
        XCTAssertEqual(sut.totalPulled, 1)
        let rows = try syncRows(db)
        XCTAssertTrue(rows.contains { $0.entityType == "boards" && $0.entityId == "b1" && $0.operationType == .update })
    }

    // MARK: - 2. Local-wins skips upsert

    func test_localWins_skipsUpsertAndCascade() throws {
        let db = try makeDb()
        try seedUser(db)
        let tid = newId()
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeTask(tid, title: "Local", version: 5))
        try db.saveBoardTask(makeBoardTask(id: "bt", boardId: "b1", taskId: tid))
        let boardBefore = try XCTUnwrap(try db.fetchBoard(id: "b1"))
        let sut = makeSut(db)

        // Stale remote (lower version) — local wins.
        let remote: [String: Any] = [
            "id": tid, "userId": userId, "title": "Remote", "type": "normal",
            "isCompleted": true, "version": 2,
            "updatedAt": "2026-06-02T00:00:00.000",
            "createdAt": "2026-06-01T00:00:00.000", "isDeleted": false,
        ]
        sut.applyRemoteSubdoc(collection: taskCol, remoteData: remote, authenticatedUserId: userId)

        // Local row untouched.
        let t = try XCTUnwrap(try db.fetchTask(id: tid))
        XCTAssertEqual(t.title, "Local")
        XCTAssertEqual(t.version, 5)
        XCTAssertFalse(t.isCompleted)

        // No cascade write, no pull event.
        let b = try XCTUnwrap(try db.fetchBoard(id: "b1"))
        XCTAssertEqual(b.version, boardBefore.version)
        XCTAssertEqual(sut.totalPulled, 0)
    }

    // MARK: - 3. Cascade failure rolls back the upsert

    /// Poison vector: a NEW `tasks` doc whose `type` is a value the local
    /// `TaskType` enum can't decode. It passes `validateRemotePullDocument`
    /// (valid UUID id, version ≥ 1, matching userId — validation never checks
    /// `type`), so `upsertLocalRecord` writes the raw row. Then
    /// `runPullCascade` calls `Task.fetchAll(db)`, which re-decodes every row
    /// including the poisoned one and throws — inside the same transaction as
    /// the upsert. The contract under test: the upsert is rolled back, so the
    /// row never persists (a partial write would leave an undecodeable task
    /// wedged in the table forever, with no safety net).
    func test_cascadeFailure_rollsBackUpsert() throws {
        let db = try makeDb()
        try seedUser(db)
        let tid = newId()
        let sut = makeSut(db)

        let poison: [String: Any] = [
            "id": tid, "userId": userId, "title": "Poison",
            "type": "not_a_real_type", "version": 1,
            "updatedAt": "2026-06-02T00:00:00.000",
            "createdAt": "2026-06-01T00:00:00.000", "isDeleted": false,
        ]
        sut.applyRemoteSubdoc(collection: taskCol, remoteData: poison, authenticatedUserId: userId)

        // Transaction rolled back — the poisoned row must not exist (raw count,
        // to avoid re-triggering the decode failure via the Codable fetch).
        XCTAssertEqual(try rawTaskCount(db, id: tid), 0)
        // No pull event was recorded (the apply threw before recordEvent).
        XCTAssertEqual(sut.totalPulled, 0)
    }

    // MARK: - 4. Additive-merge integration gate

    func test_additiveMerge_appliedWhenSharedCounterSourceAndBothMoved() throws {
        let db = try makeDb()
        try seedUser(db)
        let sourceId = newId()
        // Local source counting task: currentCount advanced 5 → 8 since sync.
        try db.saveTask(makeTask(sourceId, type: .counting, version: 1,
                                 currentCount: 8, lastSyncedCount: 5))
        // A second task LINKS to the source (makes it a shared-counter source →
        // linkedCount > 0, the 5th merge condition).
        try db.saveTask(makeTask(newId(), type: .counting, currentCount: 8,
                                 sharedCounterId: sourceId))
        let sut = makeSut(db)

        // Remote independently advanced 5 → 6. Both sides moved → additive merge.
        let remote: [String: Any] = [
            "id": sourceId, "userId": userId, "title": "Task", "type": "counting",
            "currentCount": 6, "version": 2, "isDeleted": false,
            "updatedAt": "2026-06-02T00:00:00.000",
            "createdAt": "2026-06-01T00:00:00.000",
        ]
        sut.applyRemoteSubdoc(collection: taskCol, remoteData: remote, authenticatedUserId: userId)

        // merged = remote + (local - base) = 6 + (8 - 5) = 9 (NOT plain LWW's 6).
        let t = try XCTUnwrap(try db.fetchTask(id: sourceId))
        XCTAssertEqual(t.currentCount, 9)
        XCTAssertEqual(t.lastSyncedCount, 6)          // advanced to remote's value
        XCTAssertEqual(t.version, 3)                  // max(1,2)+1
        // Merged result enqueued for push back to Firestore.
        let rows = try syncRows(db)
        XCTAssertTrue(rows.contains { $0.entityType == "tasks" && $0.entityId == sourceId && $0.operationType == .update })
    }

    func test_additiveMerge_notApplied_fallsToPlainLWW_whenNotSharedSource() throws {
        let db = try makeDb()
        try seedUser(db)
        let tid = newId()
        // Same count divergence, but NO task references this one → not a
        // shared-counter source → merge gate fails → plain LWW.
        try db.saveTask(makeTask(tid, type: .counting, version: 1,
                                 currentCount: 8, lastSyncedCount: 5))
        let sut = makeSut(db)

        let remote: [String: Any] = [
            "id": tid, "userId": userId, "title": "Task", "type": "counting",
            "currentCount": 6, "version": 2, "isDeleted": false,
            "updatedAt": "2026-06-02T00:00:00.000",
            "createdAt": "2026-06-01T00:00:00.000",
        ]
        sut.applyRemoteSubdoc(collection: taskCol, remoteData: remote, authenticatedUserId: userId)

        // Plain LWW remote-wins: currentCount is the remote value (6, NOT 9),
        // lastSyncedCount advances to remote's count (Issue #8 branch).
        let t = try XCTUnwrap(try db.fetchTask(id: tid))
        XCTAssertEqual(t.currentCount, 6)
        XCTAssertEqual(t.version, 2)
        XCTAssertEqual(t.lastSyncedCount, 6)
    }
}
