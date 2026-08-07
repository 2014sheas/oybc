import XCTest
import GRDB
@testable import OYBC

/// Seam tests (E3 / issue #299) for `SyncService.applyRemoteSubdoc(...)` — the
/// iOS pull-apply path. This is the integration boundary where several
/// well-tested pure units meet: `validateRemotePullDocument` → `resolveConflict`
/// (LWW) → `upsertLocalRecord` + `runPullCascade`, all inside ONE GRDB write so a
/// cascade failure rolls back the upsert. (The Phase-4 additive-merge gate that
/// used to sit between LWW and the upsert was retired by Windowed Completion —
/// counting-task conflicts resolve by union-of-events; case 4 below now asserts
/// that retirement.)
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
///   4. Additive-merge is RETIRED (Windowed Completion): even a shared-counter
///      source with divergent local+remote counts falls through to plain LWW —
///      no merge, no version bump, `lastSyncedCount` left untouched.
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
            operatorType: nil, threshold: nil,
            referencedBoardId: nil, referencedTemplateId: nil,
            achievementTrigger: nil, requiredCount: nil,
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

        // Upsert landed (the lifetime cache flips complete via LWW).
        let t = try XCTUnwrap(try db.fetchTask(id: tid))
        XCTAssertTrue(t.isCompleted)

        // Windowed Completion — the cascade evaluates the task WINDOWED (no
        // backing TaskEvent arrived), so a bare `tasks`-doc isCompleted flip does
        // NOT green the windowed board; only the FREE center counts (= 1 on a
        // 3×3). The completion greens the board once its taskEvent pulls in via
        // `applyTaskEventsBatch`. The cascade still runs + bumps board.version.
        let b = try XCTUnwrap(try db.fetchBoard(id: "b1"))
        XCTAssertEqual(b.completedTasks, 1)
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

    // MARK: - 4. Additive-merge is NEUTERED (Windowed Completion, docs §Shared
    //            counters interaction — "Retired: sharedCounterMerge +
    //            lastSyncedCount stamping — in PR B"). Counting conflicts resolve
    //            by union-of-events now; the merge branch is hard-bypassed and
    //            `lastSyncedCount` is no longer stamped on the pull path.

    func test_additiveMerge_neutered_evenForSharedCounterSource_fallsToPlainLWW() throws {
        let db = try makeDb()
        try seedUser(db)
        let sourceId = newId()
        // Local source counting task: currentCount advanced 5 → 8 since sync.
        try db.saveTask(makeTask(sourceId, type: .counting, version: 1,
                                 currentCount: 8, lastSyncedCount: 5))
        // A second task LINKS to the source (pre-neuter this made it a merge
        // candidate). With the merge retired it no longer matters.
        try db.saveTask(makeTask(newId(), type: .counting, currentCount: 8,
                                 sharedCounterId: sourceId))
        let sut = makeSut(db)

        // Remote independently advanced 5 → 6 at a higher version → plain LWW
        // remote-wins (NOT additive merge's 9).
        let remote: [String: Any] = [
            "id": sourceId, "userId": userId, "title": "Task", "type": "counting",
            "currentCount": 6, "version": 2, "isDeleted": false,
            "updatedAt": "2026-06-02T00:00:00.000",
            "createdAt": "2026-06-01T00:00:00.000",
        ]
        sut.applyRemoteSubdoc(collection: taskCol, remoteData: remote, authenticatedUserId: userId)

        let t = try XCTUnwrap(try db.fetchTask(id: sourceId))
        XCTAssertEqual(t.currentCount, 6, "plain LWW remote value, not the merged 9")
        XCTAssertEqual(t.version, 2, "remote's version — no merge version bump")
        XCTAssertEqual(t.lastSyncedCount, 5, "lastSyncedCount stamping is retired — stays put")
        // No merge push enqueued (a plain remote-wins pull authors no task write).
        let rows = try syncRows(db)
        XCTAssertFalse(rows.contains { $0.entityType == "tasks" && $0.entityId == sourceId && $0.operationType == .update })
    }

    func test_countingPull_plainLWW_doesNotStampLastSyncedCount() throws {
        let db = try makeDb()
        try seedUser(db)
        let tid = newId()
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

        // Plain LWW remote-wins: currentCount is the remote value; lastSyncedCount
        // is NO LONGER advanced (retired in PR B).
        let t = try XCTUnwrap(try db.fetchTask(id: tid))
        XCTAssertEqual(t.currentCount, 6)
        XCTAssertEqual(t.version, 2)
        XCTAssertEqual(t.lastSyncedCount, 5)
    }

    // MARK: - 5. Sealed-board pull re-derive (bingo-pipeline hardening item 1)

    private let boardsCol = (firestoreName: "boards", grdbTable: "boards")

    /// A pulled SEALED `boards` doc may carry a stale snapshot (sealed OFFLINE
    /// on another device against a partial event union). Historically the
    /// pull-apply path LWW-upserted it verbatim and left it stale until a
    /// later `taskEvents` pull happened to touch a placed task — and since
    /// sealed re-derivation never bumps version/enqueues, the wrong snapshot
    /// would sit there (and could even push back out as the "converged"
    /// value on a subsequent, unrelated write). The fix: any pulled `boards`
    /// doc with `sealedAt` set re-derives from the LOCAL converged event
    /// union in the SAME transaction as the upsert.
    func test_sealedBoardPull_convergesStaleSnapshotFromLocalEvents() throws {
        let db = try makeDb()
        try seedUser(db)
        let tid = newId()
        let bid = newId()
        let sealedAt = "2026-06-05T00:00:00.000Z"

        // 3x3, centerSquareType NONE (no auto-fill) so the only green cell is
        // the one placed task.
        let boardDict: [String: Any] = [
            "id": bid, "userId": userId, "name": "Board", "status": "active",
            "boardSize": 3, "timeframe": Timeframe.monthly.rawValue,
            "startDate": "2026-06-01T00:00:00.000Z", "endDate": "2026-06-30T23:59:59.000Z",
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": "2026-06-01T00:00:00.000Z", "updatedAt": "2026-06-01T00:00:00.000Z",
            "version": 1, "isDeleted": false,
        ]
        let boardData = try JSONSerialization.data(withJSONObject: boardDict)
        try db.saveBoard(try JSONDecoder().decode(Board.self, from: boardData))
        try db.saveTask(makeTask(tid, isCompleted: false))
        try db.saveBoardTask(makeBoardTask(id: newId(), boardId: bid, taskId: tid)) // cell 0

        try db.write { txn in
            // In-window, pre-seal completion — the LOCAL converged event
            // union this device has (never leaves this device in this test).
            try TaskEvent(
                id: newId(), userId: userId, taskId: tid, kind: .completion, delta: nil,
                occurredAt: "2026-06-01T12:00:00.000Z", boardId: nil,
                createdAt: sealedAt, updatedAt: sealedAt,
                lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
            ).save(txn)
            // Authentic local seal — correct snapshot, version bumps 1 → 2.
            _ = try AppDatabase.sealBoardTx(db: txn, boardId: bid, now: sealedAt)
        }

        let sealedLocal = try XCTUnwrap(try db.fetchBoard(id: bid))
        XCTAssertEqual(sealedLocal.completedTasks, 1, "sanity: local seal derived the real snapshot")
        XCTAssertEqual(sealedLocal.sealedCompletedCells, [0])
        XCTAssertEqual(sealedLocal.version, 2)
        let syncRowsBefore = try syncRows(db).filter { $0.entityId == bid }.count

        let sut = makeSut(db)

        // A pulled remote doc for the SAME board / SAME sealedAt but a STALE
        // (wrong) snapshot at a HIGHER version — LWW must apply it, and only
        // the re-derive step corrects it back to the real snapshot.
        let remote: [String: Any] = [
            "id": bid, "userId": userId, "name": "Board", "status": "active",
            "boardSize": 3, "timeframe": Timeframe.monthly.rawValue,
            "startDate": "2026-06-01T00:00:00.000Z", "endDate": "2026-06-30T23:59:59.000Z",
            "centerSquareType": CenterSquareType.none.rawValue, "isRandomized": false,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": "2026-06-01T00:00:00.000Z", "updatedAt": "2026-06-06T00:00:00.000Z",
            "version": 5, "isDeleted": false,
            "sealedAt": sealedAt,
            "sealedCompletedCells": "[]",
        ]
        sut.applyRemoteSubdoc(collection: boardsCol, remoteData: remote, authenticatedUserId: userId)

        let after = try XCTUnwrap(try db.fetchBoard(id: bid))
        // Re-derived from the LOCAL converged event union — NOT the remote's
        // stale empty snapshot.
        XCTAssertEqual(after.completedTasks, 1)
        XCTAssertEqual(after.sealedCompletedCells, [0])
        // LWW upsert applied the remote's version verbatim; re-derivation is
        // local-only and must NOT bump it further.
        XCTAssertEqual(after.version, 5)

        // Nothing new enqueued by the re-derive itself — same sync_queue row
        // count for this board as right before the pull (pulls never author
        // board writes; the earlier local seal's own enqueue is the only row).
        let syncRowsAfter = try syncRows(db).filter { $0.entityId == bid }.count
        XCTAssertEqual(syncRowsAfter, syncRowsBefore)
    }

    // MARK: - 6. boardTasks-pull cascade (Board-integrity PR-1, docs/BOARD_INTEGRITY.md)

    private let boardTasksCol = (firestoreName: "boardTasks", grdbTable: "board_tasks")

    /// Appends an in-window `completion` TaskEvent so `taskId` reads WINDOWED
    /// complete on `bid`'s board — the lifetime `Task.isCompleted` cache
    /// alone is NOT read by the windowed board grid (docs/WINDOWED_COMPLETION.md).
    /// Mirrors the sealed-pull test's event-seeding pattern above.
    private func completeInWindow(_ db: AppDatabase, taskId: String, occurredAt: String = "2026-06-05T00:00:00.000Z") throws {
        try db.write { txn in
            try TaskEvent(
                id: self.newId(), userId: self.userId, taskId: taskId, kind: .completion, delta: nil,
                occurredAt: occurredAt, boardId: nil,
                createdAt: occurredAt, updatedAt: occurredAt,
                lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
            ).save(txn)
        }
    }

    /// Applying a pulled `boardTasks` TOMBSTONE removes that cell from the
    /// board's derived stats in the SAME transaction as the upsert — the
    /// gap this PR closes (previously a pulled `boardTasks` row triggered NO
    /// board re-derivation at all, so `completedTasks` stayed stale on the
    /// receiving device until an unrelated cascade happened to touch the
    /// same board). A second, untouched placement stays counted, proving
    /// the tombstoned cell specifically was excluded — not that windowed
    /// derivation just came up empty for unrelated reasons.
    func test_boardTasksPull_tombstoneRemovesCellFromDerivedStatsInSameTxn() throws {
        let db = try makeDb()
        try seedUser(db)
        // Pull validation requires UUID-format ids (validateRemotePullDocument)
        // — literal ids like "bt1" are rejected before the upsert ever runs.
        let bid = newId()
        var board = makeBoard(id: bid)
        board.centerSquareType = .none // no FREE auto-fill to muddy the count
        try db.saveBoard(board)

        let tid = newId()
        let staysId = newId()
        let removedBtId = newId(), staysBtId = newId()
        try db.saveTask(makeTask(tid))
        try db.saveTask(makeTask(staysId))
        try completeInWindow(db, taskId: tid)
        try completeInWindow(db, taskId: staysId)
        try db.saveBoardTask(makeBoardTask(id: removedBtId, boardId: bid, taskId: tid))
        try db.saveBoardTask(BoardTask(
            id: staysBtId, boardId: bid, taskId: staysId, row: 0, col: 1, isCenter: false,
            createdAt: AppDatabase.currentTimestamp(), updatedAt: AppDatabase.currentTimestamp(),
            lastSyncedAt: nil, version: 1
        ))
        let sut = makeSut(db)

        // Remote tombstone for bt1 at a higher version — this device's own
        // completed cell was removed from the board on another device.
        let remote: [String: Any] = [
            "id": removedBtId, "boardId": bid, "taskId": tid, "row": 0, "col": 0,
            "isCenter": false, "createdAt": "2026-06-01T00:00:00.000",
            "updatedAt": "2026-06-02T00:00:00.000", "version": 2,
            "isDeleted": true, "deletedAt": "2026-06-02T00:00:00.000",
        ]
        sut.applyRemoteSubdoc(collection: boardTasksCol, remoteData: remote, authenticatedUserId: userId)

        // The tombstone landed locally.
        let bt = try XCTUnwrap(try db.read { try BoardTask.fetchOne($0, key: removedBtId) })
        XCTAssertTrue(bt.isDeleted)

        // The cascade recomputed the board's stats WITHOUT the tombstoned
        // cell (in the same transaction as the upsert) while still counting
        // the surviving completed placement.
        let b = try XCTUnwrap(try db.fetchBoard(id: bid))
        XCTAssertEqual(b.completedTasks, 1, "only the surviving bt2 cell counts")
        XCTAssertEqual(sut.totalPulled, 1)
        let rows = try syncRows(db)
        XCTAssertTrue(rows.contains { $0.entityType == "boards" && $0.entityId == bid && $0.operationType == .update })
    }

    /// Applying a pulled LIVE `boardTasks` row with a CHANGED position
    /// recomputes `completedLineIds` — the positional-staleness regression.
    /// `completedLineIds` is a positional bingo cache: three already-complete
    /// (windowed, via TaskEvent) tasks placed across row 0 hold a `row_0`
    /// bingo; pulling a move of one of them off that row must drop the line
    /// even though every task's completion state is unchanged.
    func test_boardTasksPull_liveRowPositionChange_recomputesCompletedLineIds() throws {
        let db = try makeDb()
        try seedUser(db)
        let bid = newId()
        var board = makeBoard(id: bid)
        board.centerSquareType = .none
        // Seed the STALE-but-was-correct prior cascade output: a row_0 bingo.
        board.completedTasks = 3
        board.linesCompleted = 1
        board.completedLineIds = ["row_0"]
        try db.saveBoard(board)

        let t1 = newId(), t2 = newId(), t3 = newId()
        let bt1 = newId(), bt2 = newId(), bt3 = newId()
        try db.saveTask(makeTask(t1))
        try db.saveTask(makeTask(t2))
        try db.saveTask(makeTask(t3))
        try completeInWindow(db, taskId: t1)
        try completeInWindow(db, taskId: t2)
        try completeInWindow(db, taskId: t3)
        let now = AppDatabase.currentTimestamp()
        try db.saveBoardTask(BoardTask(
            id: bt1, boardId: bid, taskId: t1, row: 0, col: 0, isCenter: false,
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
        try db.saveBoardTask(BoardTask(
            id: bt2, boardId: bid, taskId: t2, row: 0, col: 1, isCenter: false,
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
        try db.saveBoardTask(BoardTask(
            id: bt3, boardId: bid, taskId: t3, row: 0, col: 2, isCenter: false,
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
        let sut = makeSut(db)

        // Remote MOVES bt3 down to (1, 2) — row 0 no longer fully covered.
        let remote: [String: Any] = [
            "id": bt3, "boardId": bid, "taskId": t3, "row": 1, "col": 2,
            "isCenter": false, "createdAt": now, "updatedAt": "2026-06-02T00:00:00.000",
            "version": 2, "isDeleted": false,
        ]
        sut.applyRemoteSubdoc(collection: boardTasksCol, remoteData: remote, authenticatedUserId: userId)

        let b = try XCTUnwrap(try db.fetchBoard(id: bid))
        XCTAssertEqual(b.completedTasks, 3, "completion count is unaffected by a pure position move")
        XCTAssertEqual(b.linesCompleted, 0, "row_0 no longer holds after the pulled move")
        XCTAssertEqual(b.completedLineIds ?? [], [])
    }

    // MARK: - 7. Local-wins re-assert (Board-integrity PR-4, Item 1)

    /// The push path's getDoc → setDoc race means a stale write can land
    /// AFTER a fresher one; before this fix, the next pull's local-wins
    /// resolution was a SILENT no-op, so the fresher local version never
    /// re-pushed. The fix: a local-wins pull now enqueues an UPDATE for the
    /// local row, coalescing (idempotent) with any existing PENDING item.
    func test_localWins_enqueuesUpdateForFresherLocalRow() throws {
        let db = try makeDb()
        try seedUser(db)
        let tid = newId()
        try db.saveTask(makeTask(tid, title: "Local", version: 5))
        let sut = makeSut(db)

        // Stale remote (lower version) — local wins.
        let remote: [String: Any] = [
            "id": tid, "userId": userId, "title": "Remote", "type": "normal",
            "isCompleted": false, "version": 2,
            "updatedAt": "2026-06-01T00:00:00.000",
            "createdAt": "2026-06-01T00:00:00.000", "isDeleted": false,
        ]
        sut.applyRemoteSubdoc(collection: taskCol, remoteData: remote, authenticatedUserId: userId)

        // A pending UPDATE was enqueued for the LOCAL row (not the remote's
        // stale data) so it re-asserts on the next push.
        let rows = try syncRows(db)
        let reassert = try XCTUnwrap(rows.first { $0.entityType == "tasks" && $0.entityId == tid })
        XCTAssertEqual(reassert.operationType, .update)
        XCTAssertEqual(reassert.status, .pending)
        let payloadData = try XCTUnwrap(reassert.payload.data(using: .utf8))
        let payloadDict = try XCTUnwrap(JSONSerialization.jsonObject(with: payloadData) as? [String: Any])
        XCTAssertEqual(payloadDict["title"] as? String, "Local", "payload is the LOCAL winner, not the remote loser")
        XCTAssertEqual(payloadDict["version"] as? Int, 5)
        // Wire-type fidelity (PR-4 review C1): the payload must come from the
        // TYPED model encode, not a raw GRDB row dict — booleans must be real
        // JSON booleans (a raw row dict serialises them as 0/1 integers,
        // which web's strict Zod rejects, silently defeating the reassert).
        // Asserted on the raw JSON text: NSNumber(0/1) bridges to Bool via
        // `as? Bool`, so a dictionary-level check could not catch the
        // regression.
        XCTAssertTrue(reassert.payload.contains("\"isCompleted\":false"),
                      "isCompleted must serialise as a JSON boolean, not 0/1")
        XCTAssertFalse(reassert.payload.contains("\"isCompleted\":0"),
                       "raw GRDB row-dict payload detected (0/1 boolean)")

        // Local GRDB row itself is untouched (matches test 2 above).
        let t = try XCTUnwrap(try db.fetchTask(id: tid))
        XCTAssertEqual(t.title, "Local")
        XCTAssertEqual(t.version, 5)
    }

    /// Repeated local-wins pulls (e.g. the 5-minute safety net re-pulling the
    /// same stale remote doc before the reasserted push lands) must coalesce
    /// into ONE pending row, not pile up duplicates.
    func test_localWins_repeatedPulls_coalesceIntoOnePendingRow() throws {
        let db = try makeDb()
        try seedUser(db)
        let tid = newId()
        try db.saveTask(makeTask(tid, title: "Local", version: 5))
        let sut = makeSut(db)

        let remote: [String: Any] = [
            "id": tid, "userId": userId, "title": "Remote", "type": "normal",
            "isCompleted": false, "version": 2,
            "updatedAt": "2026-06-01T00:00:00.000",
            "createdAt": "2026-06-01T00:00:00.000", "isDeleted": false,
        ]
        sut.applyRemoteSubdoc(collection: taskCol, remoteData: remote, authenticatedUserId: userId)
        sut.applyRemoteSubdoc(collection: taskCol, remoteData: remote, authenticatedUserId: userId)
        sut.applyRemoteSubdoc(collection: taskCol, remoteData: remote, authenticatedUserId: userId)

        let rows = try syncRows(db).filter { $0.entityType == "tasks" && $0.entityId == tid }
        XCTAssertEqual(rows.count, 1, "the coalescer must collapse repeat re-asserts into one pending row")
    }

    /// Remote-wins must NEVER enqueue a re-assert — the remote data just
    /// became the new local truth, so there is nothing fresher to push back.
    func test_remoteWins_doesNotEnqueueReassert() throws {
        let db = try makeDb()
        try seedUser(db)
        let tid = newId()
        try db.saveTask(makeTask(tid, title: "Local", version: 1))
        let sut = makeSut(db)

        let remote: [String: Any] = [
            "id": tid, "userId": userId, "title": "Remote", "type": "normal",
            "isCompleted": false, "version": 2,
            "updatedAt": "2026-06-02T00:00:00.000",
            "createdAt": "2026-06-01T00:00:00.000", "isDeleted": false,
        ]
        sut.applyRemoteSubdoc(collection: taskCol, remoteData: remote, authenticatedUserId: userId)

        // Remote-wins landed (sanity)...
        let t = try XCTUnwrap(try db.fetchTask(id: tid))
        XCTAssertEqual(t.title, "Remote")
        // ...and no re-assert was enqueued for this entity.
        let rows = try syncRows(db).filter { $0.entityType == "tasks" && $0.entityId == tid }
        XCTAssertTrue(rows.isEmpty, "remote-wins must not enqueue a push")
    }

    /// Loop guard: pulling back an ECHO of a row this device already holds
    /// (identical version + updatedAt — e.g. this device's own just-pushed
    /// write reflected back by a listener) must not enqueue anything. Per
    /// `resolveConflict`'s exact-tie→remote rule, an identical row always
    /// takes the remote-wins branch (never local-wins), so the loop-guard
    /// property holds by construction; this test pins that the one reachable
    /// "echo" path produces zero re-asserts.
    func test_identicalRowEcho_doesNotEnqueueReassert() throws {
        let db = try makeDb()
        try seedUser(db)
        let tid = newId()
        let sharedUpdatedAt = "2026-06-02T00:00:00.000"
        try db.saveTask(makeTask(tid, title: "Task", version: 3))
        try db.write { txn in
            try txn.execute(
                sql: "UPDATE tasks SET updatedAt = ? WHERE id = ?",
                arguments: [sharedUpdatedAt, tid]
            )
        }
        let sut = makeSut(db)

        // Byte-identical echo: same version, same updatedAt.
        let remote: [String: Any] = [
            "id": tid, "userId": userId, "title": "Task", "type": "normal",
            "isCompleted": false, "version": 3,
            "updatedAt": sharedUpdatedAt,
            "createdAt": "2026-06-01T00:00:00.000", "isDeleted": false,
        ]
        sut.applyRemoteSubdoc(collection: taskCol, remoteData: remote, authenticatedUserId: userId)

        let rows = try syncRows(db).filter { $0.entityType == "tasks" && $0.entityId == tid }
        XCTAssertTrue(rows.isEmpty, "an identical echo must not enqueue a re-assert")
    }
}
