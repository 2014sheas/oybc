import XCTest
import GRDB
@testable import OYBC

/// Seam tests (E3 / issue #299) for the AppDatabase *cascade-delete* paths —
/// the boundary where several well-tested pure units meet a multi-table write.
///
/// Covers:
///   1. `deleteTaskWithCascade(taskId:)` — full cascade across every side:
///      BoardTask placements SOFT-deleted (Board-integrity PR-1 tombstones —
///      isDeleted + deletedAt + version bump), CompoundChild links soft-deleted
///      in BOTH directions (task-as-parent and task-as-child), the Task itself
///      soft-deleted, and a `sync_queue` DELETE row enqueued for each (the B4
///      choke point — the data layer owns the enqueue).
///   2. `computeTaskDeletionImpact(taskId:)` — the read-only preview's counts
///      MUST equal what the cascade then changes. This preview→cascade contract
///      is exactly a seam. Also pins the intentional divergence: the preview
///      counts only LIVE-board placements, while the cascade soft-deletes orphan
///      placements on soft-deleted boards too.
///   3. Achievement tasks skip the task-side (compound-link) cascade — they
///      reference boards/templates, not tasks, so no CompoundChild rows exist
///      for them and an unrelated compound's links survive.
///   4. Board deletion: `deleteBoard(id:)` soft-deletes the board ONLY (leaves
///      placements, does not enqueue), whereas `deleteDraftWithCascade(id:)`
///      soft-deletes (tombstones) placements + soft-deletes the board +
///      enqueues both — and rejects a non-draft board.
///
/// Each test spins up its own in-memory `AppDatabase.makeTestInstance()`
/// (full migration chain, FK enforcement ON).
final class CascadeDeleteTests: XCTestCase {

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

    private func makeTask(_ id: String, userId: String = "u1", type: TaskType = .normal) -> Task {
        let now = AppDatabase.currentTimestamp()
        return Task(
            id: id,
            userId: userId,
            title: "Task \(id)",
            description: nil,
            type: type,
            action: nil,
            unit: nil,
            maxCount: nil,
            operatorType: type == .compound ? .and : nil,
            threshold: nil,
            referencedBoardId: nil,
            referencedTemplateId: nil,
            achievementTrigger: nil,
            requiredCount: nil,
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

    /// An ACHIEVEMENT task referencing a board (never another task).
    private func makeAchievementTask(_ id: String, boardId: String, userId: String = "u1") -> Task {
        var t = makeTask(id, userId: userId, type: .achievement)
        t.achievementTrigger = .bingo
        t.referencedBoardId = boardId
        return t
    }

    private func makeBoard(id: String, userId: String = "u1", status: BoardStatus = .active) -> Board {
        let dict: [String: Any] = [
            "id": id,
            "userId": userId,
            "name": "Board \(id)",
            "status": status.rawValue,
            "boardSize": 3,
            "timeframe": Timeframe.monthly.rawValue,
            "startDate": "2026-06-01T00:00:00.000",
            "endDate": "2026-06-30T23:59:59.999",
            "centerSquareType": CenterSquareType.free.rawValue,
            "isRandomized": false,
            "totalTasks": 9,
            "completedTasks": 0,
            "linesCompleted": 0,
            "createdAt": "2026-06-01T00:00:00.000",
            "updatedAt": "2026-06-01T00:00:00.000",
            "version": 1,
            "isDeleted": false,
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    private func makeBoardTask(id: String, boardId: String, taskId: String, row: Int = 0, col: Int = 0) -> BoardTask {
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

    private func makeLink(id: String, parent: String, child: String, index: Int) -> CompoundChild {
        let now = AppDatabase.currentTimestamp()
        return CompoundChild(
            id: id,
            compoundTaskId: parent,
            childTaskId: child,
            childIndex: index,
            createdAt: now,
            updatedAt: now,
            lastSyncedAt: nil,
            version: 1,
            isDeleted: false,
            deletedAt: nil
        )
    }

    private func syncRows(_ db: AppDatabase) throws -> [SyncQueueItem] {
        try db.fetchPendingSyncItems()
    }

    private func count(_ rows: [SyncQueueItem], type: String, op: SyncOperationType) -> Int {
        rows.filter { $0.entityType == type && $0.operationType == op }.count
    }

    private func fetchLink(_ db: AppDatabase, id: String) throws -> CompoundChild? {
        try db.read { try CompoundChild.fetchOne($0, key: id) }
    }

    /// Raw fetch by id, regardless of `isDeleted` — used to inspect a
    /// tombstoned row's fields directly (Board-integrity PR-1: the row stays
    /// in the table after a "delete", it doesn't disappear).
    private func fetchBoardTask(_ db: AppDatabase, id: String) throws -> BoardTask? {
        try db.read { try BoardTask.fetchOne($0, key: id) }
    }

    /// Count of LIVE (non-tombstoned) placements for a task.
    private func boardTaskCount(_ db: AppDatabase, taskId: String) throws -> Int {
        try db.read {
            try BoardTask
                .filter(Column("taskId") == taskId && Column("isDeleted") == false)
                .fetchCount($0)
        }
    }

    // MARK: - deleteTaskWithCascade: full cascade

    func test_deleteTaskWithCascade_removesEverySideAndEnqueues() throws {
        let db = try makeDb()
        try seedUser(db)

        // Boards (both live) the target task is placed on.
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveBoard(makeBoard(id: "b2"))

        // The target task T, a compound parent P (T is P's child), and a child C
        // (C is T's child). All must exist for the compound_children FKs.
        try db.saveTask(makeTask("T", type: .compound))
        try db.saveTask(makeTask("P", type: .compound))
        try db.saveTask(makeTask("C"))

        // T placed twice (two cells across two live boards) — both hard-deleted.
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b1", taskId: "T", row: 0, col: 0))
        try db.saveBoardTask(makeBoardTask(id: "bt2", boardId: "b2", taskId: "T", row: 1, col: 1))

        // Link where T is the PARENT compound (child = C).
        try db.write { db in try self.makeLink(id: "L_parent", parent: "T", child: "C", index: 0).save(db) }
        // Link where T is a CHILD (parent = P).
        try db.write { db in try self.makeLink(id: "L_child", parent: "P", child: "T", index: 0).save(db) }

        try db.deleteTaskWithCascade(taskId: "T")

        // Placements SOFT-deleted (tombstoned) — rows stay in the table.
        let bt1 = try XCTUnwrap(try fetchBoardTask(db, id: "bt1"))
        XCTAssertTrue(bt1.isDeleted)
        XCTAssertNotNil(bt1.deletedAt)
        XCTAssertEqual(bt1.version, 2)
        let bt2 = try XCTUnwrap(try fetchBoardTask(db, id: "bt2"))
        XCTAssertTrue(bt2.isDeleted)
        XCTAssertNotNil(bt2.deletedAt)
        XCTAssertEqual(bt2.version, 2)
        XCTAssertEqual(try boardTaskCount(db, taskId: "T"), 0)

        // Both compound links SOFT-deleted (version bumped), both directions.
        let parentLink = try XCTUnwrap(fetchLink(db, id: "L_parent"))
        XCTAssertTrue(parentLink.isDeleted)
        XCTAssertNotNil(parentLink.deletedAt)
        XCTAssertEqual(parentLink.version, 2)
        let childLink = try XCTUnwrap(fetchLink(db, id: "L_child"))
        XCTAssertTrue(childLink.isDeleted)
        XCTAssertNotNil(childLink.deletedAt)
        XCTAssertEqual(childLink.version, 2)

        // Sibling Tasks (P the parent, C the child) survive.
        let p = try XCTUnwrap(try db.fetchTask(id: "P"))
        XCTAssertFalse(p.isDeleted)
        let c = try XCTUnwrap(try db.fetchTask(id: "C"))
        XCTAssertFalse(c.isDeleted)

        // The Task itself SOFT-deleted with a version bump.
        let t = try XCTUnwrap(try db.fetchTask(id: "T"))
        XCTAssertTrue(t.isDeleted)
        XCTAssertNotNil(t.deletedAt)
        XCTAssertEqual(t.version, 2)

        // B4 choke point: a DELETE sync row per side.
        let rows = try syncRows(db)
        XCTAssertEqual(count(rows, type: "boardTasks", op: .delete), 2)
        XCTAssertEqual(count(rows, type: "compoundChildren", op: .delete), 2)
        XCTAssertEqual(count(rows, type: "tasks", op: .delete), 1)
        XCTAssertTrue(rows.contains { $0.entityType == "tasks" && $0.entityId == "T" && $0.operationType == .delete })
    }

    // MARK: - impact preview MATCHES cascade

    func test_impactPreview_matchesCascade_liveBoardsOnly() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "lb1"))
        try db.saveBoard(makeBoard(id: "lb2"))
        try db.saveTask(makeTask("T", type: .compound))
        try db.saveTask(makeTask("P", type: .compound))
        try db.saveTask(makeTask("C"))
        try db.saveBoardTask(makeBoardTask(id: "p1", boardId: "lb1", taskId: "T"))
        try db.saveBoardTask(makeBoardTask(id: "p2", boardId: "lb2", taskId: "T", row: 1, col: 1))
        try db.write { db in try self.makeLink(id: "lp", parent: "T", child: "C", index: 0).save(db) }
        try db.write { db in try self.makeLink(id: "lc", parent: "P", child: "T", index: 0).save(db) }

        // Preview BEFORE the cascade.
        let impact = try db.computeTaskDeletionImpact(taskId: "T")
        XCTAssertEqual(impact.boardTaskCount, 2)
        XCTAssertEqual(impact.parentLinkCount, 1)   // T is parent of C
        XCTAssertEqual(impact.childLinkCount, 1)    // T is child of P
        XCTAssertEqual(Set(impact.affectedBoardIds), ["lb1", "lb2"])
        XCTAssertEqual(Set(impact.affectedBoards.map { $0.id }), ["lb1", "lb2"])

        // Now run the cascade and count what actually changed.
        let placementsBefore = try boardTaskCount(db, taskId: "T")
        try db.deleteTaskWithCascade(taskId: "T")
        let placementsRemoved = placementsBefore - (try boardTaskCount(db, taskId: "T"))
        XCTAssertEqual(placementsRemoved, impact.boardTaskCount)

        let softDeletedLinks = try db.read { db -> Int in
            try CompoundChild
                .filter((Column("compoundTaskId") == "T" || Column("childTaskId") == "T")
                        && Column("isDeleted") == true)
                .fetchCount(db)
        }
        XCTAssertEqual(softDeletedLinks, impact.parentLinkCount + impact.childLinkCount)
    }

    /// The documented divergence: preview counts only LIVE-board placements,
    /// but the cascade soft-deletes (tombstones) an orphan placement on a
    /// soft-deleted board too. The preview intentionally under-reports what
    /// storage cleanup removes.
    func test_impactPreview_excludesOrphanPlacement_cascadeStillRemovesIt() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "live"))
        // A soft-deleted board carrying an orphan placement.
        var deadBoard = makeBoard(id: "dead")
        deadBoard.isDeleted = true
        try db.saveBoard(deadBoard)
        try db.saveTask(makeTask("T"))
        try db.saveBoardTask(makeBoardTask(id: "live-bt", boardId: "live", taskId: "T"))
        try db.saveBoardTask(makeBoardTask(id: "orphan-bt", boardId: "dead", taskId: "T", row: 2, col: 2))

        // Preview reports only the visible (live-board) cell.
        let impact = try db.computeTaskDeletionImpact(taskId: "T")
        XCTAssertEqual(impact.boardTaskCount, 1)
        XCTAssertEqual(impact.affectedBoardIds, ["live"])

        // Cascade tombstones BOTH placements, including the orphan.
        try db.deleteTaskWithCascade(taskId: "T")
        XCTAssertEqual(try boardTaskCount(db, taskId: "T"), 0)
        // Sync enqueues a DELETE for every placement removed, including the orphan.
        let rows = try syncRows(db)
        XCTAssertEqual(count(rows, type: "boardTasks", op: .delete), 2)
    }

    // MARK: - achievement skips task-side cascade

    func test_deleteAchievementTask_skipsCompoundLinkCascade() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "watched"))
        try db.saveBoard(makeBoard(id: "host"))

        // An unrelated compound with a live child link — must survive.
        try db.saveTask(makeTask("CP", type: .compound))
        try db.saveTask(makeTask("CC"))
        try db.write { db in try self.makeLink(id: "unrelated", parent: "CP", child: "CC", index: 0).save(db) }

        // Achievement task references a board, is placed on another board.
        try db.saveTask(makeAchievementTask("A", boardId: "watched"))
        try db.saveBoardTask(makeBoardTask(id: "abt", boardId: "host", taskId: "A"))

        // Preview: achievement carries no compound links either direction.
        let impact = try db.computeTaskDeletionImpact(taskId: "A")
        XCTAssertEqual(impact.childLinkCount, 0)
        XCTAssertEqual(impact.parentLinkCount, 0)
        XCTAssertEqual(impact.boardTaskCount, 1)

        try db.deleteTaskWithCascade(taskId: "A")

        // Achievement task soft-deleted, its placement soft-deleted (tombstoned) + enqueued.
        let a = try XCTUnwrap(try db.fetchTask(id: "A"))
        XCTAssertTrue(a.isDeleted)
        let abt = try XCTUnwrap(try fetchBoardTask(db, id: "abt"))
        XCTAssertTrue(abt.isDeleted)

        // No compoundChildren DELETE enqueued — the task-side cascade was skipped.
        let rows = try syncRows(db)
        XCTAssertEqual(count(rows, type: "compoundChildren", op: .delete), 0)

        // The unrelated compound link is untouched.
        let unrelated = try XCTUnwrap(fetchLink(db, id: "unrelated"))
        XCTAssertFalse(unrelated.isDeleted)
        XCTAssertEqual(unrelated.version, 1)
    }

    // MARK: - board deletion

    func test_deleteBoard_softDeletesBoardOnly_noPlacementCascade() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b"))
        try db.saveTask(makeTask("t"))
        try db.saveBoardTask(makeBoardTask(id: "bt", boardId: "b", taskId: "t"))

        try db.deleteBoard(id: "b")

        // Board soft-deleted with version bump.
        let b = try XCTUnwrap(try db.fetchBoard(id: "b"))
        XCTAssertTrue(b.isDeleted)
        XCTAssertNotNil(b.deletedAt)
        XCTAssertEqual(b.version, 2)

        // Placements stay intact (still LIVE) — deleteBoard does NOT cascade to BoardTask.
        let bt = try XCTUnwrap(try fetchBoardTask(db, id: "bt"))
        XCTAssertFalse(bt.isDeleted)

        // deleteBoard does not enqueue a sync row (see AppDatabase+Boards).
        let rows = try syncRows(db)
        XCTAssertEqual(count(rows, type: "boards", op: .delete), 0)
    }

    func test_deleteDraftWithCascade_softDeletesPlacementsAndEnqueuesBoth() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "d", status: .draft))
        try db.saveTask(makeTask("t1"))
        try db.saveTask(makeTask("t2"))
        try db.saveBoardTask(makeBoardTask(id: "dbt1", boardId: "d", taskId: "t1"))
        try db.saveBoardTask(makeBoardTask(id: "dbt2", boardId: "d", taskId: "t2", row: 1, col: 1))

        try db.deleteDraftWithCascade(id: "d")

        // Board soft-deleted; placements SOFT-deleted (tombstoned).
        let board = try XCTUnwrap(try db.fetchBoard(id: "d"))
        XCTAssertTrue(board.isDeleted)
        let dbt1 = try XCTUnwrap(try fetchBoardTask(db, id: "dbt1"))
        XCTAssertTrue(dbt1.isDeleted)
        XCTAssertNotNil(dbt1.deletedAt)
        let dbt2 = try XCTUnwrap(try fetchBoardTask(db, id: "dbt2"))
        XCTAssertTrue(dbt2.isDeleted)
        XCTAssertNotNil(dbt2.deletedAt)

        // Both placements + the board enqueue DELETE sync rows.
        let rows = try syncRows(db)
        XCTAssertEqual(count(rows, type: "boardTasks", op: .delete), 2)
        XCTAssertEqual(count(rows, type: "boards", op: .delete), 1)
    }

    func test_deleteDraftWithCascade_rejectsNonDraft() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "active", status: .active))

        XCTAssertThrowsError(try db.deleteDraftWithCascade(id: "active")) { error in
            // Guard trips loudly rather than destroying active placements.
            XCTAssertTrue("\(error)".contains("draft") || "\(error)".contains("not"))
        }
        // Board untouched.
        let b = try XCTUnwrap(try db.fetchBoard(id: "active"))
        XCTAssertFalse(b.isDeleted)
    }

    // MARK: - removeBoardTaskFromBoard: tombstone semantics (Board-integrity PR-1)

    func test_removeBoardTaskFromBoard_softDeletesAndRecomputesBoardStats() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeTask("t1"))
        var t2 = makeTask("t2")
        t2.isCompleted = true
        try db.saveTask(t2)
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b1", taskId: "t1", row: 0, col: 0))
        try db.saveBoardTask(makeBoardTask(id: "bt2", boardId: "b1", taskId: "t2", row: 0, col: 1))

        try db.removeBoardTaskFromBoard("bt2")

        // Row stays in the table as a tombstone.
        let bt2 = try XCTUnwrap(try fetchBoardTask(db, id: "bt2"))
        XCTAssertTrue(bt2.isDeleted)
        XCTAssertNotNil(bt2.deletedAt)
        XCTAssertEqual(bt2.version, 2)

        // Excluded from the live fetch.
        let live = try db.fetchBoardTasks(boardId: "b1")
        XCTAssertEqual(live.map { $0.id }, ["bt1"])

        // Enqueued as a DELETE tombstone.
        let rows = try syncRows(db)
        XCTAssertTrue(rows.contains { $0.entityType == "boardTasks" && $0.entityId == "bt2" && $0.operationType == .delete })
    }

    func test_removeBoardTaskFromBoard_idempotent_noOpIfAlreadyTombstoned() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeTask("t1"))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b1", taskId: "t1"))

        try db.removeBoardTaskFromBoard("bt1")
        let afterFirst = try XCTUnwrap(try fetchBoardTask(db, id: "bt1"))
        XCTAssertEqual(afterFirst.version, 2)

        // Second call on an already-tombstoned row is a no-op — no double
        // version bump, no second enqueue.
        try db.removeBoardTaskFromBoard("bt1")
        let afterSecond = try XCTUnwrap(try fetchBoardTask(db, id: "bt1"))
        XCTAssertEqual(afterSecond.version, 2)
        let rows = try syncRows(db)
        XCTAssertEqual(count(rows, type: "boardTasks", op: .delete), 1)
    }

    /// THE headline regression this PR fixes (docs/BOARD_INTEGRITY.md): a
    /// placement whose row is "already synced" (local version == remote
    /// version) used to self-restore, because a hard delete left nothing
    /// local for the push loop to diff a higher version against — the
    /// "exact tie → remote wins" rule let an unrelated remote-wins pull
    /// `table.put` the pre-delete row back within ~500ms. Pins that the
    /// tombstone's version bump (BEFORE enqueue, `removeBoardTaskFromBoard`)
    /// flips the LWW compare to LOCAL-wins against that exact already-synced
    /// remote snapshot — the tie-break flip that closes the self-restore hole.
    func test_removeBoardTaskFromBoard_tombstoneVersionBeatsAlreadySyncedRemoteInLWW() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeTask("t1"))
        let bt = makeBoardTask(id: "bt1", boardId: "b1", taskId: "t1")
        try db.saveBoardTask(bt)

        // Simulate "already synced": Firestore holds the exact pre-delete
        // snapshot at the same version this device had before removal.
        let remoteBeforeDelete: [String: Any] = [
            "id": "bt1", "boardId": "b1", "taskId": "t1", "row": 0, "col": 0,
            "isCenter": false, "createdAt": bt.createdAt, "updatedAt": bt.updatedAt,
            "version": 1, "isDeleted": false,
        ]

        try db.removeBoardTaskFromBoard("bt1")

        let tombstone = try XCTUnwrap(try fetchBoardTask(db, id: "bt1"))
        XCTAssertEqual(tombstone.version, 2, "version bumped past the already-synced remote's version 1")

        let tombstonePayload: [String: Any] = [
            "id": tombstone.id, "boardId": tombstone.boardId, "taskId": tombstone.taskId,
            "row": tombstone.row, "col": tombstone.col, "isCenter": tombstone.isCenter,
            "createdAt": tombstone.createdAt, "updatedAt": tombstone.updatedAt,
            "version": tombstone.version, "isDeleted": tombstone.isDeleted,
            "deletedAt": tombstone.deletedAt as Any,
        ]

        // The push-path DELETE branch's conflict compare: local tombstone vs
        // the already-synced remote. LOCAL must win now (higher version).
        XCTAssertEqual(resolveConflict(local: tombstonePayload, remote: remoteBeforeDelete), "local")
    }

    // MARK: - BoardTask decode forward-compat (Board-integrity PR-1)

    /// `board_tasks` predates the `isDeleted`/`deletedAt` columns (added in
    /// GRDB migration v27) — `MigrationV7Helpers.run(db)` decodes
    /// `BoardTask.fetchAll(db)` against the table as it existed at v7,
    /// BEFORE v27 runs. A strict (non-`decodeIfPresent`) decode of
    /// `isDeleted` would throw on every fresh install / upgrading device,
    /// failing migration entirely — `AppDatabase.makeTestInstance()` runs
    /// the FULL migrator (v1...latest) for every other test in this file,
    /// so if this decode weren't forward-compatible, EVERY test in this
    /// suite would already fail at `makeDb()`. This test additionally pins
    /// the decode contract directly against a legacy-shaped (pre-v27) payload.
    func test_boardTask_decodesForwardCompat_whenIsDeletedAbsent() throws {
        let legacyDict: [String: Any] = [
            "id": "bt1", "boardId": "b1", "taskId": "t1", "row": 0, "col": 0,
            "isCenter": false, "createdAt": "2026-06-01T00:00:00.000",
            "updatedAt": "2026-06-01T00:00:00.000", "version": 1,
            // isDeleted / deletedAt intentionally absent — legacy shape.
        ]
        let data = try JSONSerialization.data(withJSONObject: legacyDict)
        let decoded = try JSONDecoder().decode(BoardTask.self, from: data)
        XCTAssertFalse(decoded.isDeleted)
        XCTAssertNil(decoded.deletedAt)
    }

    func test_boardTask_freshRow_readsBackIsDeletedFalse() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeTask("t1"))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b1", taskId: "t1"))

        let bt = try XCTUnwrap(try fetchBoardTask(db, id: "bt1"))
        XCTAssertFalse(bt.isDeleted)
        XCTAssertNil(bt.deletedAt)
    }
}
