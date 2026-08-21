import XCTest
import GRDB
@testable import OYBC

/// Tests for the AppDatabase methods that ABSORBED the sync-enqueue write
/// transactions in B4 (previously authored inline in view/component/service
/// code). Each test asserts BOTH that the entity rows landed AND that the
/// matching `sync_queue` rows exist (entity type, operation, count) — the
/// core B4 invariant: every local write also enqueues sync, and that enqueue
/// now lives in the data layer.
///
/// Regression parity for the board-play VM path stays in
/// `BoardPlayViewModelTests` (unchanged behavior via the new methods); these
/// tests hit the data-layer methods directly against a fresh in-memory
/// `AppDatabase.makeTestInstance()`.
final class AppDatabaseSyncEnqueueTests: XCTestCase {

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

    private func makeTask(
        _ id: String,
        userId: String = "u1",
        type: TaskType = .normal,
        maxCount: Int? = nil,
        isCounter: Bool = false
    ) -> Task {
        let now = AppDatabase.currentTimestamp()
        return Task(
            id: id,
            userId: userId,
            title: "Task \(id)",
            description: nil,
            type: type,
            action: nil,
            unit: nil,
            maxCount: maxCount,
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
            createdInWizard: false,
            isCounter: isCounter
        )
    }

    private func makeBoard(
        id: String, userId: String = "u1", status: BoardStatus = .active,
        boardSize: Int = 3, sealedAt: String? = nil, completedTasks: Int = 0
    ) -> Board {
        var dict: [String: Any] = [
            "id": id,
            "userId": userId,
            "name": "Board \(id)",
            "status": status.rawValue,
            "boardSize": boardSize,
            "timeframe": Timeframe.monthly.rawValue,
            "startDate": "2026-06-01T00:00:00.000",
            "endDate": "2026-06-30T23:59:59.999",
            "centerSquareType": CenterSquareType.free.rawValue,
            "isRandomized": false,
            "totalTasks": boardSize * boardSize,
            "completedTasks": completedTasks,
            "linesCompleted": 0,
            "createdAt": "2026-06-01T00:00:00.000",
            "updatedAt": "2026-06-01T00:00:00.000",
            "version": 1,
            "isDeleted": false,
        ]
        if let sealedAt { dict["sealedAt"] = sealedAt }
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

    // MARK: - createTaskAndEnqueue

    func test_createTaskAndEnqueue_writesTaskAndSyncRow() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()

        try db.createTaskAndEnqueue(makeTask("t1"), now: now)

        XCTAssertNotNil(try db.fetchTask(id: "t1"))
        let rows = try syncRows(db)
        XCTAssertTrue(rows.contains { $0.entityType == "tasks" && $0.entityId == "t1" && $0.operationType == .create })
        XCTAssertEqual(count(rows, type: "tasks", op: .create), 1)
    }

    // MARK: - createTaskWithPairedChildrenAndEnqueue

    func test_createTaskWithPairedChildren_writesAllRowsAndSync() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()

        let parent = makeTask("p1", type: .compound)
        let c1 = makeTask("c1")
        let c2 = makeTask("c2")
        let l1 = makeLink(id: "l1", parent: "p1", child: "c1", index: 0)
        let l2 = makeLink(id: "l2", parent: "p1", child: "c2", index: 1)

        try db.createTaskWithPairedChildrenAndEnqueue(
            task: parent, childTasks: [c1, c2], childLinks: [l1, l2], now: now
        )

        XCTAssertNotNil(try db.fetchTask(id: "p1"))
        XCTAssertNotNil(try db.fetchTask(id: "c1"))
        XCTAssertNotNil(try db.fetchTask(id: "c2"))
        let rows = try syncRows(db)
        // parent + 2 children = 3 task creates; 2 compoundChildren creates.
        XCTAssertEqual(count(rows, type: "tasks", op: .create), 3)
        XCTAssertEqual(count(rows, type: "compoundChildren", op: .create), 2)
    }

    // MARK: - createCompoundAndEnqueue

    func test_createCompoundAndEnqueue_newChildrenAndExistingRef() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()

        // An existing-library child already in GRDB (referenced by id only).
        try db.saveTask(makeTask("existing"))

        let parent = makeTask("cp1", type: .compound)
        let newChild = makeTask("newc")
        let linkNew = makeLink(id: "ln", parent: "cp1", child: "newc", index: 0)
        let linkExisting = makeLink(id: "le", parent: "cp1", child: "existing", index: 1)

        try db.createCompoundAndEnqueue(
            parent: parent,
            newChildTasks: [newChild],
            childLinks: [linkNew, linkExisting],
            now: now
        )

        XCTAssertNotNil(try db.fetchTask(id: "cp1"))
        XCTAssertNotNil(try db.fetchTask(id: "newc"))
        let rows = try syncRows(db)
        // parent + newChild = 2 task creates (existing child is NOT re-created).
        XCTAssertEqual(count(rows, type: "tasks", op: .create), 2)
        XCTAssertFalse(rows.contains { $0.entityType == "tasks" && $0.entityId == "existing" && $0.operationType == .create },
                       "existing-library child must not be re-created")
        // Both links enqueued.
        XCTAssertEqual(count(rows, type: "compoundChildren", op: .create), 2)
    }

    // MARK: - createCompoundAndEnqueue — P5 goal-less-counter child guard

    func test_createCompoundAndEnqueue_existingGoalLessCounterChild_throws() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()

        // An existing-library child that is a goal-less counter (COUNTING +
        // isCounter + no maxCount) — nothing evaluable to contribute.
        try db.saveTask(makeTask("goalless", type: .counting, maxCount: nil, isCounter: true))

        let parent = makeTask("cp2", type: .compound)
        let link = makeLink(id: "lg", parent: "cp2", child: "goalless", index: 0)

        XCTAssertThrowsError(
            try db.createCompoundAndEnqueue(parent: parent, newChildTasks: [], childLinks: [link], now: now)
        ) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(
                message.contains("goal-less counter tasks cannot be compound children"),
                "unexpected error message: \(message)"
            )
        }
        // Nothing should have been written — the guard runs before any write.
        XCTAssertNil(try db.fetchTask(id: "cp2"))
    }

    func test_createCompoundAndEnqueue_existingPromotedCounterChild_succeeds() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()

        // A promoted counter (isCounter + maxCount) is unaffected by the guard.
        try db.saveTask(makeTask("promoted", type: .counting, maxCount: 50, isCounter: true))

        let parent = makeTask("cp3", type: .compound)
        let link = makeLink(id: "lp", parent: "cp3", child: "promoted", index: 0)

        try db.createCompoundAndEnqueue(parent: parent, newChildTasks: [], childLinks: [link], now: now)

        XCTAssertNotNil(try db.fetchTask(id: "cp3"))
        let rows = try syncRows(db)
        XCTAssertEqual(count(rows, type: "compoundChildren", op: .create), 1)
    }

    func test_createTaskWithPairedChildren_existingGoalLessCounterChild_throws() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()

        try db.saveTask(makeTask("goalless2", type: .counting, maxCount: nil, isCounter: true))

        let parent = makeTask("p2", type: .compound)
        // Reference an existing goal-less counter with no paired new child task.
        let link = makeLink(id: "l3", parent: "p2", child: "goalless2", index: 0)

        XCTAssertThrowsError(
            try db.createTaskWithPairedChildrenAndEnqueue(task: parent, childTasks: [], childLinks: [link], now: now)
        ) { error in
            let message = (error as? LocalizedError)?.errorDescription ?? "\(error)"
            XCTAssertTrue(message.contains("goal-less counter tasks cannot be compound children"))
        }
        XCTAssertNil(try db.fetchTask(id: "p2"))
    }

    // MARK: - completeTaskOrchestrated

    func test_completeTaskOrchestrated_writesTaskBoardTaskBoardAndSync() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeTask("t1"))
        let bt = makeBoardTask(id: "bt1", boardId: "b1", taskId: "t1")
        try db.saveBoardTask(bt)
        let now = AppDatabase.currentTimestamp()

        // Windowed Completion — the VM now passes a completion INTENT; the DB
        // layer appends a TaskEvent + stamps the lifetime cache.
        let board = try XCTUnwrap(try db.fetchBoard(id: "b1"))
        let results = try db.completeTaskOrchestrated(
            board: board, taskId: "t1", intent: .setCompleted(true), boardTask: bt, now: now
        )

        // Task cache stamped complete; the authored stamp bumps version 1 → 2.
        let t1 = try XCTUnwrap(try db.fetchTask(id: "t1"))
        XCTAssertTrue(t1.isCompleted)
        XCTAssertEqual(t1.version, 2)
        // A completion TaskEvent was appended + enqueued.
        XCTAssertTrue(try syncRows(db).contains { $0.entityType == "taskEvents" && $0.operationType == .create })

        // BoardTask version bumped.
        let btAfter = try XCTUnwrap(try db.read { try BoardTask.fetchOne($0, key: "bt1") })
        XCTAssertEqual(btAfter.version, 2)

        // Board stats recomputed: t1 + FREE center = 2 completed on a 3×3.
        let b1 = try XCTUnwrap(try db.fetchBoard(id: "b1"))
        XCTAssertEqual(b1.completedTasks, 2)

        // Returned cascade map carries the current board.
        XCTAssertNotNil(results["b1"])

        // Sync rows: task update + boardTask update + board update.
        let rows = try syncRows(db)
        XCTAssertTrue(rows.contains { $0.entityType == "tasks" && $0.entityId == "t1" && $0.operationType == .update })
        XCTAssertTrue(rows.contains { $0.entityType == "boardTasks" && $0.entityId == "bt1" && $0.operationType == .update })
        XCTAssertTrue(rows.contains { $0.entityType == "boards" && $0.entityId == "b1" && $0.operationType == .update })
    }

    func test_completeTaskOrchestrated_activatesDraftBoard() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "bd", status: .draft))
        try db.saveTask(makeTask("t1"))
        let bt = makeBoardTask(id: "btd", boardId: "bd", taskId: "t1")
        try db.saveBoardTask(bt)
        let now = AppDatabase.currentTimestamp()

        let board = try XCTUnwrap(try db.fetchBoard(id: "bd"))
        _ = try db.completeTaskOrchestrated(
            board: board, taskId: "t1", intent: .setCompleted(true), boardTask: bt, now: now
        )

        // Draft flipped to active (2/9 completed is not GREENLOG, so it stays active).
        let after = try XCTUnwrap(try db.fetchBoard(id: "bd"))
        XCTAssertEqual(after.status, .active)
    }

    // MARK: - toggleCompoundChildFallback

    func test_toggleCompoundChildFallback_writesChildAndCascade() throws {
        let db = try makeDb()
        try seedUser(db)
        // A compound parent placed on a board; the child is NOT placed.
        try db.saveBoard(makeBoard(id: "b1"))
        let parent = makeTask("cp", type: .compound)
        let child = makeTask("ch")
        try db.saveTask(parent)
        try db.saveTask(child)
        try db.write { db in try self.makeLink(id: "lk", parent: "cp", child: "ch", index: 0).save(db) }
        try db.saveBoardTask(makeBoardTask(id: "btp", boardId: "b1", taskId: "cp"))
        let now = AppDatabase.currentTimestamp()

        let board = try XCTUnwrap(try db.fetchBoard(id: "b1"))
        let results = try db.toggleCompoundChildFallback(
            childTaskId: "ch", desiredCompleted: true,
            windowStart: board.startDate, boardId: "b1", now: now
        )

        let chAfter = try XCTUnwrap(try db.fetchTask(id: "ch"))
        XCTAssertTrue(chAfter.isCompleted)

        // The board carrying the parent compound is in the cascade set.
        XCTAssertNotNil(results["b1"])

        let rows = try syncRows(db)
        XCTAssertTrue(rows.contains { $0.entityType == "tasks" && $0.entityId == "ch" && $0.operationType == .update })
        XCTAssertTrue(rows.contains { $0.entityType == "boards" && $0.entityId == "b1" && $0.operationType == .update })
    }

    // MARK: - saveWizardBoard

    func test_saveWizardBoard_freshCreate_writesBoardTasksPendingAndSync() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()

        let board = makeBoard(id: "wb")
        let bt1 = makeBoardTask(id: "wbt1", boardId: "wb", taskId: "pending1", row: 0, col: 0)
        let pending = PendingTaskPayload(
            task: makeTask("pending1"),
            childTasks: [],
            childLinks: []
        )

        try db.saveWizardBoard(
            board: board, boardTasks: [bt1], pendingTasks: [pending], isUpdate: false, now: now
        )

        XCTAssertNotNil(try db.fetchBoard(id: "wb"))
        XCTAssertNotNil(try db.fetchTask(id: "pending1"))
        let rows = try syncRows(db)
        XCTAssertEqual(count(rows, type: "boards", op: .create), 1)
        XCTAssertEqual(count(rows, type: "boardTasks", op: .create), 1)
        XCTAssertEqual(count(rows, type: "tasks", op: .create), 1)
    }

    // MARK: - saveWizardBoard staged inline edits (Inline Task Editing)

    func test_saveWizardBoard_stagedEdit_updatesLibraryTaskAndEnqueues() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()

        // Existing library task placed on the new board, with a staged rename.
        try db.saveTask(makeTask("lib1"))
        let original = try XCTUnwrap(try db.fetchTask(id: "lib1"))
        let board = makeBoard(id: "wbS")
        let bt = makeBoardTask(id: "wbtS", boardId: "wbS", taskId: "lib1")

        try db.saveWizardBoard(
            board: board, boardTasks: [bt], pendingTasks: [],
            stagedEdits: ["lib1": TaskEditPatch(title: "Renamed task")],
            isUpdate: false, now: now
        )

        let updated = try XCTUnwrap(try db.fetchTask(id: "lib1"))
        XCTAssertEqual(updated.title, "Renamed task")
        XCTAssertEqual(updated.version, original.version + 1)
        // A tasks-UPDATE sync row was enqueued for the edited library task.
        XCTAssertEqual(count(try syncRows(db), type: "tasks", op: .update), 1)
    }

    func test_saveWizardBoard_stagedCompoundEdit_appliesChildCRUD() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()

        // Library compound "cmp" with two children: c1 (normal), c2 (counting).
        try db.saveTask(makeTask("cmp", type: .compound))
        try db.saveTask(makeTask("c1", type: .normal))
        try db.saveTask(makeTask("c2", type: .counting, maxCount: 5))
        try db.write { d in
            try CompoundChild(id: "l1", compoundTaskId: "cmp", childTaskId: "c1", childIndex: 0,
                              createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1,
                              isDeleted: false, deletedAt: nil).save(d)
            try CompoundChild(id: "l2", compoundTaskId: "cmp", childTaskId: "c2", childIndex: 1,
                              createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1,
                              isDeleted: false, deletedAt: nil).save(d)
        }

        // Active board placing the compound, with a staged edit: rename c1,
        // delete c2, and add a new simple step.
        let board = makeBoard(id: "wbCmp")
        let bt = makeBoardTask(id: "wbCmpbt", boardId: "wbCmp", taskId: "cmp")
        var patch = TaskEditPatch(title: "Morning routine")
        // Seeded as a real editor patch would be (TaskEditPatch(from:) carries
        // the base task's operator forward) — proves applied(to:) round-trips
        // it rather than silently resetting to nil.
        patch.operatorType = .and
        var deletedC2 = ChildPatch(id: "c2", childTaskId: "c2", title: "Old counting", isCounting: true)
        deletedC2.markedDeleted = true
        patch.children = [
            ChildPatch(id: "c1", childTaskId: "c1", title: "Renamed step", isCounting: false),
            deletedC2,
            ChildPatch(id: "new-1", childTaskId: nil, title: "Brand new step", isCounting: false),
        ]

        try db.saveWizardBoard(
            board: board, boardTasks: [bt], pendingTasks: [],
            stagedEdits: ["cmp": patch], isUpdate: false, now: now
        )

        // Parent: title applied.
        let cmp = try XCTUnwrap(try db.fetchTask(id: "cmp"))
        XCTAssertEqual(cmp.title, "Morning routine")

        // c1 renamed globally.
        XCTAssertEqual(try db.fetchTask(id: "c1")?.title, "Renamed step")

        // Live links = c1 + the new step (c2's link soft-deleted).
        let liveLinks = try db.fetchCompoundChildren(compoundTaskId: "cmp")
        XCTAssertEqual(liveLinks.count, 2)
        XCTAssertTrue(liveLinks.contains { $0.childTaskId == "c1" })
        XCTAssertFalse(liveLinks.contains { $0.childTaskId == "c2" }, "c2 link should be soft-deleted")
        // c2's Task row survives (orphans acceptable) even though its link is gone.
        XCTAssertNotNil(try db.fetchTask(id: "c2"))
        // The new step minted a fresh child Task.
        let newLink = try XCTUnwrap(liveLinks.first { $0.childTaskId != "c1" })
        XCTAssertEqual(try db.fetchTask(id: newLink.childTaskId)?.title, "Brand new step")

        // Sync coverage: renamed child → tasks.update; new child → tasks.create;
        // new link → compoundChildren.create; removed link → compoundChildren.delete.
        let rows = try syncRows(db)
        XCTAssertGreaterThanOrEqual(count(rows, type: "tasks", op: .update), 1)
        XCTAssertGreaterThanOrEqual(count(rows, type: "tasks", op: .create), 1)
        XCTAssertGreaterThanOrEqual(count(rows, type: "compoundChildren", op: .create), 1)
        XCTAssertEqual(count(rows, type: "compoundChildren", op: .delete), 1)
    }

    func test_saveWizardBoard_pendingCompoundEdit_appliesChildCRUDOnce() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()

        // A pending (deferred) compound with two inline children + links — the
        // shape CreateFormViewModel builds for a wizard-created compound.
        let payload = PendingTaskPayload(
            task: makeTask("pcmp", type: .compound),
            childTasks: [makeTask("pc1", type: .normal), makeTask("pc2", type: .normal)],
            childLinks: [
                CompoundChild(id: "pl1", compoundTaskId: "pcmp", childTaskId: "pc1", childIndex: 0,
                              createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1,
                              isDeleted: false, deletedAt: nil),
                CompoundChild(id: "pl2", compoundTaskId: "pcmp", childTaskId: "pc2", childIndex: 1,
                              createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1,
                              isDeleted: false, deletedAt: nil),
            ]
        )
        let board = makeBoard(id: "wbPC")
        let bt = makeBoardTask(id: "wbPCbt", boardId: "wbPC", taskId: "pcmp")

        // Edit the still-pending compound: rename pc1, delete pc2, add a new step.
        var patch = TaskEditPatch(title: "Edited pending compound")
        patch.operatorType = .and
        var deleted = ChildPatch(id: "pc2", childTaskId: "pc2", title: "gone", isCounting: false)
        deleted.markedDeleted = true
        patch.children = [
            ChildPatch(id: "pc1", childTaskId: "pc1", title: "Renamed pending", isCounting: false),
            deleted,
            ChildPatch(id: "newp", childTaskId: nil, title: "New pending step", isCounting: false),
        ]

        try db.saveWizardBoard(
            board: board, boardTasks: [bt], pendingTasks: [payload],
            stagedEdits: ["pcmp": patch], isUpdate: false, now: now
        )

        // Applied exactly once (not double-applied via a pre-merge): parent
        // fields set, pc1 renamed, pc2 unlinked, new step minted.
        let cmp = try XCTUnwrap(try db.fetchTask(id: "pcmp"))
        XCTAssertEqual(cmp.title, "Edited pending compound")
        XCTAssertEqual(try db.fetchTask(id: "pc1")?.title, "Renamed pending")
        let liveLinks = try db.fetchCompoundChildren(compoundTaskId: "pcmp")
        XCTAssertEqual(liveLinks.count, 2)
        XCTAssertFalse(liveLinks.contains { $0.childTaskId == "pc2" })
    }

    func test_saveWizardBoard_draftStatus_skipsStagedEdits() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()

        // Invariant: a DRAFT board must never carry a task edit. Saving a draft
        // with a staged edit must leave the library task untouched.
        try db.saveTask(makeTask("libD"))
        let original = try XCTUnwrap(try db.fetchTask(id: "libD"))
        let board = makeBoard(id: "wbDraft", status: .draft)
        let bt = makeBoardTask(id: "wbtDraft", boardId: "wbDraft", taskId: "libD")

        try db.saveWizardBoard(
            board: board, boardTasks: [bt], pendingTasks: [],
            stagedEdits: ["libD": TaskEditPatch(title: "Should NOT apply")],
            isUpdate: false, now: now
        )

        let after = try XCTUnwrap(try db.fetchTask(id: "libD"))
        XCTAssertEqual(after.title, original.title, "draft save must not apply staged edits")
        XCTAssertEqual(after.version, original.version)
        XCTAssertEqual(count(try syncRows(db), type: "tasks", op: .update), 0)
    }

    func test_saveWizardBoard_stagedEdit_reDerivesOtherBoardSharingTask() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()

        // Existing ACTIVE board B2 places the shared task, with a deliberately
        // stale completedTasks (99). Editing the shared task on a NEW active
        // board must cascade a re-derivation onto B2 (edits are global) — a bare
        // save would leave 99 stale until app-open self-heal.
        try db.saveTask(makeTask("sharedC"))
        try db.saveBoard(makeBoard(id: "b2", completedTasks: 99))
        try db.saveBoardTask(makeBoardTask(id: "b2bt", boardId: "b2", taskId: "sharedC"))

        let board = makeBoard(id: "wbNew")
        let bt = makeBoardTask(id: "wbNewbt", boardId: "wbNew", taskId: "sharedC")

        try db.saveWizardBoard(
            board: board, boardTasks: [bt], pendingTasks: [],
            stagedEdits: ["sharedC": TaskEditPatch(title: "Renamed shared")],
            isUpdate: false, now: now
        )

        let b2 = try XCTUnwrap(try db.fetchBoard(id: "b2"))
        XCTAssertNotEqual(b2.completedTasks, 99, "cascade must re-derive the other board sharing the edited task")
    }

    func test_saveWizardBoard_stagedEdit_skipsPendingTaskId() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()

        // persistWizardBoard already merges a pending task's patch into its
        // payload, so saveWizardBoard must NOT re-apply the same id — it should
        // write only the create row, never a spurious update.
        let board = makeBoard(id: "wbP")
        let bt = makeBoardTask(id: "wbtP", boardId: "wbP", taskId: "pend1")
        let merged = PendingTaskPayload(task: makeTask("pend1"), childTasks: [], childLinks: [])

        try db.saveWizardBoard(
            board: board, boardTasks: [bt], pendingTasks: [merged],
            stagedEdits: ["pend1": TaskEditPatch(title: "X")],
            isUpdate: false, now: now
        )

        let rows = try syncRows(db)
        XCTAssertEqual(count(rows, type: "tasks", op: .create), 1)
        XCTAssertEqual(count(rows, type: "tasks", op: .update), 0)
    }

    func test_saveWizardBoard_update_deletesOldTasksEnqueuesDeletes() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()

        // Seed an existing board with one old placement (both referenced
        // tasks must exist to satisfy the board_tasks.taskId foreign key).
        try db.saveBoard(makeBoard(id: "wb2"))
        try db.saveTask(makeTask("tX"))
        try db.saveTask(makeTask("tY"))
        try db.saveBoardTask(makeBoardTask(id: "old-bt", boardId: "wb2", taskId: "tX"))

        var board = makeBoard(id: "wb2")
        board.version = 2
        let newBt = makeBoardTask(id: "new-bt", boardId: "wb2", taskId: "tY", row: 1, col: 1)

        try db.saveWizardBoard(
            board: board, boardTasks: [newBt], pendingTasks: [], isUpdate: true, now: now
        )

        // Old placement soft-deleted (tombstoned), new placement present and LIVE.
        let livePlacements = try db.read {
            try BoardTask
                .filter(Column("boardId") == "wb2" && Column("isDeleted") == false)
                .fetchAll($0)
        }
        XCTAssertEqual(livePlacements.map { $0.id }, ["new-bt"])
        let oldBt = try XCTUnwrap(try db.read { try BoardTask.fetchOne($0, key: "old-bt") })
        XCTAssertTrue(oldBt.isDeleted)
        XCTAssertNotNil(oldBt.deletedAt)
        XCTAssertEqual(oldBt.version, 2)

        let rows = try syncRows(db)
        XCTAssertEqual(count(rows, type: "boards", op: .update), 1)
        XCTAssertEqual(count(rows, type: "boardTasks", op: .delete), 1)
        XCTAssertEqual(count(rows, type: "boardTasks", op: .create), 1)
    }

    // MARK: - writeWizardPendingTasksAndEnqueue staged inline edits (P4 recurring parity fix)
    //
    // `persistRecurringTemplate` (`BoardWizardPersist.swift`) has no single
    // Board row to share a transaction with, so it drains pending tasks AND
    // applies staged inline edits via this method instead of
    // `saveWizardBoard`. These tests hit the same per-type branches as the
    // `saveWizardBoard staged inline edits` section above, directly against
    // this method, to pin the fix at the data-layer unit-test level (the
    // higher-level regression through the real `persistRecurringTemplate`
    // free function lives in `BoardWizardPersistRecurringTemplateTests`).

    func test_writeWizardPendingTasksAndEnqueue_stagedEdit_updatesLibraryTaskAndEnqueues() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()

        try db.saveTask(makeTask("rlib1"))
        let original = try XCTUnwrap(try db.fetchTask(id: "rlib1"))

        try db.writeWizardPendingTasksAndEnqueue(
            [], stagedEdits: ["rlib1": TaskEditPatch(title: "Renamed recurring task")], now: now
        )

        let updated = try XCTUnwrap(try db.fetchTask(id: "rlib1"))
        XCTAssertEqual(updated.title, "Renamed recurring task")
        XCTAssertEqual(updated.version, original.version + 1)
        XCTAssertEqual(count(try syncRows(db), type: "tasks", op: .update), 1)
    }

    func test_writeWizardPendingTasksAndEnqueue_stagedEdit_skipsPendingTaskId() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()

        // The caller (`persistRecurringTemplate`) already merges a pending
        // simple/counting task's patch into its payload in-memory, so this
        // must NOT re-apply the same id — only the create row should land.
        let merged = PendingTaskPayload(task: makeTask("rpend1"), childTasks: [], childLinks: [])

        try db.writeWizardPendingTasksAndEnqueue(
            [merged], stagedEdits: ["rpend1": TaskEditPatch(title: "X")], now: now
        )

        let rows = try syncRows(db)
        XCTAssertEqual(count(rows, type: "tasks", op: .create), 1)
        XCTAssertEqual(count(rows, type: "tasks", op: .update), 0)
    }

    func test_writeWizardPendingTasksAndEnqueue_stagedCompoundEdit_appliesChildCRUD() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()

        // Library compound "rcmp" with two children: rc1 (normal), rc2 (counting).
        try db.saveTask(makeTask("rcmp", type: .compound))
        try db.saveTask(makeTask("rc1", type: .normal))
        try db.saveTask(makeTask("rc2", type: .counting, maxCount: 5))
        try db.write { d in
            try makeLink(id: "rl1", parent: "rcmp", child: "rc1", index: 0).save(d)
            try makeLink(id: "rl2", parent: "rcmp", child: "rc2", index: 1).save(d)
        }

        var patch = TaskEditPatch(title: "Morning routine (recurring)")
        patch.operatorType = .and
        var deletedRc2 = ChildPatch(id: "rc2", childTaskId: "rc2", title: "Old counting", isCounting: true)
        deletedRc2.markedDeleted = true
        patch.children = [
            ChildPatch(id: "rc1", childTaskId: "rc1", title: "Renamed step", isCounting: false),
            deletedRc2,
            ChildPatch(id: "rnew-1", childTaskId: nil, title: "Brand new step", isCounting: false),
        ]

        try db.writeWizardPendingTasksAndEnqueue([], stagedEdits: ["rcmp": patch], now: now)

        let cmp = try XCTUnwrap(try db.fetchTask(id: "rcmp"))
        XCTAssertEqual(cmp.title, "Morning routine (recurring)")
        XCTAssertEqual(try db.fetchTask(id: "rc1")?.title, "Renamed step")

        let liveLinks = try db.fetchCompoundChildren(compoundTaskId: "rcmp")
        XCTAssertEqual(liveLinks.count, 2)
        XCTAssertTrue(liveLinks.contains { $0.childTaskId == "rc1" })
        XCTAssertFalse(liveLinks.contains { $0.childTaskId == "rc2" }, "rc2 link should be soft-deleted")
        XCTAssertNotNil(try db.fetchTask(id: "rc2"), "orphaned child Task survives")
        let newLink = try XCTUnwrap(liveLinks.first { $0.childTaskId != "rc1" })
        XCTAssertEqual(try db.fetchTask(id: newLink.childTaskId)?.title, "Brand new step")
    }

    func test_writeWizardPendingTasksAndEnqueue_pendingCompoundEdit_appliesChildCRUDOnce() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()

        // A pending (deferred) compound with two inline children + links.
        let payload = PendingTaskPayload(
            task: makeTask("rpcmp", type: .compound),
            childTasks: [makeTask("rpc1", type: .normal), makeTask("rpc2", type: .normal)],
            childLinks: [
                makeLink(id: "rpl1", parent: "rpcmp", child: "rpc1", index: 0),
                makeLink(id: "rpl2", parent: "rpcmp", child: "rpc2", index: 1),
            ]
        )

        var patch = TaskEditPatch(title: "Edited pending recurring compound")
        patch.operatorType = .and
        var deleted = ChildPatch(id: "rpc2", childTaskId: "rpc2", title: "gone", isCounting: false)
        deleted.markedDeleted = true
        patch.children = [
            ChildPatch(id: "rpc1", childTaskId: "rpc1", title: "Renamed pending", isCounting: false),
            deleted,
            ChildPatch(id: "rnewp", childTaskId: nil, title: "New pending step", isCounting: false),
        ]

        try db.writeWizardPendingTasksAndEnqueue([payload], stagedEdits: ["rpcmp": patch], now: now)

        // Applied exactly once (not double-applied via a pre-merge): parent
        // fields set, rpc1 renamed, rpc2 unlinked, new step minted.
        let cmp = try XCTUnwrap(try db.fetchTask(id: "rpcmp"))
        XCTAssertEqual(cmp.title, "Edited pending recurring compound")
        XCTAssertEqual(try db.fetchTask(id: "rpc1")?.title, "Renamed pending")
        let liveLinks = try db.fetchCompoundChildren(compoundTaskId: "rpcmp")
        XCTAssertEqual(liveLinks.count, 2)
        XCTAssertFalse(liveLinks.contains { $0.childTaskId == "rpc2" })
    }

    // MARK: - saveWizardBoard: isCenter uniqueness guard (board-integrity PR-5, Item 3)

    /// A single `isCenter: true` row (the normal CHOSEN-center case) must
    /// still save cleanly — the guard only rejects a SECOND live center.
    func test_saveWizardBoard_singleCenterRow_stillSucceeds() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()
        try db.saveTask(makeTask("centerTask"))

        let board = makeBoard(id: "wb-center-ok", boardSize: 3)
        let centerBt = BoardTask(
            id: "bt-center", boardId: "wb-center-ok", taskId: "centerTask",
            row: 1, col: 1, isCenter: true,
            createdAt: now, updatedAt: now, version: 1
        )

        try db.saveWizardBoard(
            board: board, boardTasks: [centerBt], pendingTasks: [], isUpdate: false, now: now
        )

        let live = try db.fetchBoardTasks(boardId: "wb-center-ok")
        XCTAssertEqual(live.map { $0.id }, ["bt-center"])
    }

    /// Board-integrity PR-5 (Item 3): nothing upstream previously prevented
    /// two rows both claiming `isCenter: true` at DIFFERENT cells on the same
    /// board. `saveWizardBoard`'s per-row insert loop now rejects a second
    /// live center — mirrors web's `createBoardTask` guard (the per-cell
    /// wizard-write-loop equivalent). The whole write rolls back: no board,
    /// no placements, no sync rows.
    func test_saveWizardBoard_twoCenterRows_throwsAndWritesNothing() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()
        try db.saveTask(makeTask("centerTask"))
        try db.saveTask(makeTask("otherCenterTask"))

        let board = makeBoard(id: "wb-dup-center", boardSize: 3)
        let centerBt1 = BoardTask(
            id: "bt-center-1", boardId: "wb-dup-center", taskId: "centerTask",
            row: 1, col: 1, isCenter: true,
            createdAt: now, updatedAt: now, version: 1
        )
        // A SECOND center at a different cell — the bug this guard prevents.
        let centerBt2 = BoardTask(
            id: "bt-center-2", boardId: "wb-dup-center", taskId: "otherCenterTask",
            row: 0, col: 0, isCenter: true,
            createdAt: now, updatedAt: now, version: 1
        )

        XCTAssertThrowsError(
            try db.saveWizardBoard(
                board: board, boardTasks: [centerBt1, centerBt2],
                pendingTasks: [], isUpdate: false, now: now
            )
        ) { error in
            guard case AppDatabase.AppDatabaseError.invalidPlacement = error else {
                return XCTFail("expected .invalidPlacement, got \(error)")
            }
        }

        // Whole transaction rolled back — no board, no placements, no sync rows.
        XCTAssertNil(try db.fetchBoard(id: "wb-dup-center"))
        XCTAssertTrue(try db.fetchBoardTasks(boardId: "wb-dup-center").isEmpty)
        let rows = try syncRows(db)
        XCTAssertEqual(count(rows, type: "boards", op: .create), 0)
        XCTAssertEqual(count(rows, type: "boardTasks", op: .create), 0)
    }

    // MARK: - saveWizardBoard: derivation pass (bingo-pipeline hardening item 2)
    //
    // Before the fix, stats were hand-init'd to 0 (or preserved from the prior
    // draft row) instead of derived from the just-written placements — a board
    // placing an already-in-window-complete task, or with a FREE center, would
    // store + sync wrong stats until the next app-open self-heal.

    func test_saveWizardBoard_freshCreate_derivesStatsFromWindowedCompleteTaskAndFreeCenter() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()

        // Pre-existing library task, already complete WITHIN the new board's
        // window (an in-window completion event — not just the lifetime cache,
        // which windowed derivation never trusts).
        try db.saveTask(makeTask("done1"))
        try db.write { txn in
            try TaskEvent(
                id: "ev1", userId: "u1", taskId: "done1", kind: .completion, delta: nil,
                occurredAt: "2026-06-15T00:00:00.000", boardId: nil,
                createdAt: now, updatedAt: now,
                lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
            ).save(txn)
        }

        // `makeBoard` defaults `centerSquareType` to FREE (3×3, so the center
        // auto-fills) — this exercises both halves of the item-2 test note in
        // one board: an already-windowed-complete placed task AND a FREE
        // center both landing in the derived count.
        let board = makeBoard(id: "wb-derive")
        let bt = makeBoardTask(id: "wbt-derive", boardId: "wb-derive", taskId: "done1", row: 0, col: 0)

        try db.saveWizardBoard(
            board: board, boardTasks: [bt], pendingTasks: [], isUpdate: false, now: now
        )

        let saved = try XCTUnwrap(try db.fetchBoard(id: "wb-derive"))
        XCTAssertEqual(
            saved.completedTasks, 2,
            "derivation output (placed complete task + FREE center auto-fill), not the hand-init 0"
        )
    }

    func test_saveWizardBoard_draftToActiveResume_derivesStatsAtActivation() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()

        try db.saveTask(makeTask("done2"))
        try db.write { txn in
            try TaskEvent(
                id: "ev2", userId: "u1", taskId: "done2", kind: .completion, delta: nil,
                occurredAt: "2026-06-15T00:00:00.000", boardId: nil,
                createdAt: now, updatedAt: now,
                lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
            ).save(txn)
        }

        // First save: a DRAFT with nothing placed yet — only the FREE center
        // auto-fill counts.
        var draft = makeBoard(id: "wb-resume", status: .draft)
        try db.saveWizardBoard(board: draft, boardTasks: [], pendingTasks: [], isUpdate: false, now: now)
        XCTAssertEqual(try db.fetchBoard(id: "wb-resume")?.completedTasks, 1)

        // Resume the draft and save it ACTIVE with the complete task now
        // placed — activation must derive from the just-written placements,
        // not preserve/hand-init a stale value.
        draft.status = .active
        draft.version = 2
        let bt = makeBoardTask(id: "wbt-resume", boardId: "wb-resume", taskId: "done2", row: 0, col: 0)
        try db.saveWizardBoard(board: draft, boardTasks: [bt], pendingTasks: [], isUpdate: true, now: now)

        let activated = try XCTUnwrap(try db.fetchBoard(id: "wb-resume"))
        XCTAssertEqual(
            activated.completedTasks, 2,
            "derived from the just-written placements at activation, not a hand-init/preserved value"
        )
        XCTAssertNotNil(activated.activatedAt, "activation instant stamped")
    }

    // MARK: - spawnRecurringBoard

    private func seedSpawnTasks(_ db: AppDatabase, count n: Int) throws -> [String] {
        var ids: [String] = []
        for i in 0..<n {
            let id = "seed\(i)"
            try db.saveTask(makeTask(id))
            ids.append(id)
        }
        return ids
    }

    /// Builds a template already in the migrated shape (`poolIds: [pool]`,
    /// `manualTaskIds: []`, `removedTaskIds: []`) — mints and saves the
    /// backing `Pool` directly against `db` so `spawnRecurringBoard`'s
    /// `PoolMix.resolveMix` call resolves the same task ids `seedIds`
    /// used to resolve to pre-P1. A template with no `poolIds` would
    /// resolve to an EMPTY mix post-P1 (spawn never falls back to
    /// `seedTaskIds` — see `RecurringBoardTemplate`'s "seedTaskIds end
    /// state" doc), so every spawn-path test needs a real pool.
    private func makeTemplate(_ db: AppDatabase, id: String, seedIds: [String]) throws -> RecurringBoardTemplate {
        let now = AppDatabase.currentTimestamp()
        let pool = Pool(
            id: "\(id)-pool", userId: "u1", name: "\(id) pool", taskIds: seedIds,
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1,
            isDeleted: false, deletedAt: nil
        )
        try db.write { grdb in try pool.insert(grdb) }
        return RecurringBoardTemplate(
            id: id,
            userId: "u1",
            name: "Weekly",
            timeframe: .monthly,
            boardSize: 3,
            centerSquareType: .free,
            isRandomized: false,
            seedTaskIds: seedIds,
            poolIds: [pool.id],
            manualTaskIds: [],
            removedTaskIds: [],
            isActive: true,
            createdAt: now,
            updatedAt: now,
            version: 1
        )
    }

    func test_spawnRecurringBoard_writesBoardTasksTemplateAndSync() throws {
        let db = try makeDb()
        try seedUser(db)
        // 3×3 FREE center → 8 fillable cells.
        let seedIds = try seedSpawnTasks(db, count: 8)
        let template = try makeTemplate(db, id: "tpl", seedIds: seedIds)
        try db.saveRecurringBoardTemplate(template)
        let now = AppDatabase.currentTimestamp()

        let spawn = PendingTemplateSpawn(
            template: template,
            windowStart: "2026-07-01T00:00:00.000",
            windowEnd: "2026-07-31T23:59:59.999",
            suggestedName: "Weekly — Jul"
        )
        let boardId = AppDatabase.generateUUID()
        let outcome = try db.spawnRecurringBoard(spawn, boardId: boardId, now: now)

        guard case .spawned(let bid, let tid, _) = outcome else {
            return XCTFail("expected .spawned, got \(outcome)")
        }
        XCTAssertEqual(bid, boardId)
        XCTAssertEqual(tid, "tpl")

        XCTAssertNotNil(try db.fetchBoard(id: boardId))
        let placements = try db.read { try BoardTask.filter(Column("boardId") == boardId).fetchAll($0) }
        XCTAssertEqual(placements.count, 8)

        // Template's lastSpawnedWindowKey updated.
        let tplAfter = try XCTUnwrap(try db.fetchRecurringBoardTemplate(id: "tpl"))
        XCTAssertEqual(tplAfter.lastSpawnedWindowKey, "2026-07-01T00:00:00.000")

        let rows = try syncRows(db)
        XCTAssertEqual(count(rows, type: "boards", op: .create), 1)
        XCTAssertEqual(count(rows, type: "boardTasks", op: .create), 8)
        XCTAssertEqual(count(rows, type: "recurringBoardTemplates", op: .update), 1)
    }

    func test_spawnRecurringBoard_poolTooSmall_skipsNoWrite() throws {
        let db = try makeDb()
        try seedUser(db)
        let seedIds = try seedSpawnTasks(db, count: 2) // < 8 required
        let template = try makeTemplate(db, id: "tpl2", seedIds: seedIds)
        try db.saveRecurringBoardTemplate(template)
        let now = AppDatabase.currentTimestamp()

        let spawn = PendingTemplateSpawn(
            template: template,
            windowStart: "2026-07-01T00:00:00.000",
            windowEnd: "2026-07-31T23:59:59.999",
            suggestedName: "Weekly — Jul"
        )
        let boardId = AppDatabase.generateUUID()
        let outcome = try db.spawnRecurringBoard(spawn, boardId: boardId, now: now)

        guard case .skipped(_, let reason) = outcome else {
            return XCTFail("expected .skipped, got \(outcome)")
        }
        XCTAssertEqual(reason, .poolTooSmall)

        // No board written; no sync rows enqueued (txn rolled back).
        XCTAssertNil(try db.fetchBoard(id: boardId))
        let rows = try syncRows(db)
        XCTAssertEqual(count(rows, type: "boards", op: .create), 0)
    }

    // MARK: - Tombstone guards on placement write paths (PR-1 review)

    /// A placement tombstoned by a concurrent cross-device delete must not be
    /// resurrected/mutated by a stale edit-session swap or rearrange — the
    /// write paths guard on `isDeleted` and silently no-op.
    func test_tombstonedPlacement_isImmuneToSwapAndRearrange() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "tg1"))
        try db.saveTask(makeTask("tA"))
        try db.saveTask(makeTask("tB"))
        try db.saveBoardTask(makeBoardTask(id: "bt-dead", boardId: "tg1", taskId: "tA"))

        // Tombstone it (the PR-1 soft-delete path).
        try db.removeBoardTaskFromBoard("bt-dead")
        let deadV = try XCTUnwrap(try db.read { try BoardTask.fetchOne($0, key: "bt-dead") }).version

        // Swap must no-op: taskId unchanged, version unchanged, still tombstoned.
        try db.updateBoardTaskAndCascade(boardTaskId: "bt-dead", newTaskId: "tB")
        var bt = try XCTUnwrap(try db.read { try BoardTask.fetchOne($0, key: "bt-dead") })
        XCTAssertTrue(bt.isDeleted)
        XCTAssertEqual(bt.taskId, "tA", "swap on a tombstone must not mutate it")
        XCTAssertEqual(bt.version, deadV, "swap on a tombstone must not bump version")

        // Rearrange must skip it: position unchanged.
        try db.updateBoardTaskPositions(
            boardId: "tg1",
            moves: [AppDatabase.BoardTaskPositionMove(boardTaskId: "bt-dead", row: 2, col: 2)]
        )
        bt = try XCTUnwrap(try db.read { try BoardTask.fetchOne($0, key: "bt-dead") })
        XCTAssertEqual(bt.row, 0)
        XCTAssertEqual(bt.col, 0)
        XCTAssertEqual(bt.version, deadV, "rearrange on a tombstone must not bump version")
    }

    // MARK: - Board-integrity PR-2 (Part 3) — addBoardTaskToBoard write-invariant guards

    func test_addBoardTaskToBoard_occupiedCell_throwsAndDoesNotWrite() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeTask("tA"))
        try db.saveTask(makeTask("tB"))
        try db.saveBoardTask(makeBoardTask(id: "bt-existing", boardId: "b1", taskId: "tA", row: 0, col: 0))

        XCTAssertThrowsError(try db.addBoardTaskToBoard("b1", taskId: "tB", position: (row: 0, col: 0))) { error in
            guard case AppDatabase.AppDatabaseError.invalidPlacement = error else {
                return XCTFail("expected .invalidPlacement, got \(error)")
            }
        }
        // No new row landed at the cell; the existing occupant is unchanged.
        let live = try db.fetchBoardTasks(boardId: "b1")
        XCTAssertEqual(live.count, 1)
        XCTAssertEqual(live.first?.id, "bt-existing")
    }

    func test_addBoardTaskToBoard_taskAlreadyOnBoard_throwsAndDoesNotWrite() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeTask("tA"))
        try db.saveBoardTask(makeBoardTask(id: "bt-existing", boardId: "b1", taskId: "tA", row: 0, col: 0))

        XCTAssertThrowsError(try db.addBoardTaskToBoard("b1", taskId: "tA", position: (row: 1, col: 1))) { error in
            guard case AppDatabase.AppDatabaseError.invalidPlacement = error else {
                return XCTFail("expected .invalidPlacement, got \(error)")
            }
        }
        let live = try db.fetchBoardTasks(boardId: "b1")
        XCTAssertEqual(live.count, 1, "the duplicate placement was rejected, not added")
    }

    func test_addBoardTaskToBoard_outOfBounds_throwsAndDoesNotWrite() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1", boardSize: 3))
        try db.saveTask(makeTask("tA"))

        XCTAssertThrowsError(try db.addBoardTaskToBoard("b1", taskId: "tA", position: (row: 3, col: 0))) { error in
            guard case AppDatabase.AppDatabaseError.invalidPlacement = error else {
                return XCTFail("expected .invalidPlacement, got \(error)")
            }
        }
        XCTAssertTrue(try db.fetchBoardTasks(boardId: "b1").isEmpty)
    }

    func test_addBoardTaskToBoard_validPlacement_stillSucceeds() throws {
        // Guardrail: the new invariant checks don't false-positive-reject a
        // legitimate add-to-empty-cell.
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeTask("tA"))

        let created = try db.addBoardTaskToBoard("b1", taskId: "tA", position: (row: 1, col: 1))
        XCTAssertEqual(created.row, 1)
        XCTAssertEqual(created.col, 1)
        XCTAssertEqual(try db.fetchBoardTasks(boardId: "b1").count, 1)
    }

    // MARK: - Board-integrity PR-2 (Part 4) — sealed-board guards on the three placement mutators

    func test_addBoardTaskToBoard_sealedBoard_throwsAndDoesNotWrite() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b-sealed", sealedAt: "2026-06-15T00:00:00.000"))
        try db.saveTask(makeTask("tA"))

        XCTAssertThrowsError(try db.addBoardTaskToBoard("b-sealed", taskId: "tA", position: (row: 0, col: 0))) { error in
            guard case AppDatabase.AppDatabaseError.invalidPlacement = error else {
                return XCTFail("expected .invalidPlacement, got \(error)")
            }
        }
        XCTAssertTrue(try db.fetchBoardTasks(boardId: "b-sealed").isEmpty)
    }

    func test_removeBoardTaskFromBoard_sealedBoard_noOpsLeavesRowLive() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b-sealed", sealedAt: "2026-06-15T00:00:00.000"))
        try db.saveTask(makeTask("tA"))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b-sealed", taskId: "tA"))

        try db.removeBoardTaskFromBoard("bt1")

        let bt = try XCTUnwrap(try db.read { try BoardTask.fetchOne($0, key: "bt1") })
        XCTAssertFalse(bt.isDeleted, "a sealed board's placement must not be removed")
        XCTAssertEqual(bt.version, 1, "no write happened — version untouched")
        XCTAssertEqual(count(try syncRows(db), type: "boardTasks", op: .delete), 0)
    }

    func test_updateBoardTaskAndCascade_sealedBoard_noOpsLeavesRowUnchanged() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b-sealed", sealedAt: "2026-06-15T00:00:00.000"))
        try db.saveTask(makeTask("tA"))
        try db.saveTask(makeTask("tB"))
        try db.saveBoardTask(makeBoardTask(id: "bt1", boardId: "b-sealed", taskId: "tA"))

        try db.updateBoardTaskAndCascade(boardTaskId: "bt1", newTaskId: "tB")

        let bt = try XCTUnwrap(try db.read { try BoardTask.fetchOne($0, key: "bt1") })
        XCTAssertEqual(bt.taskId, "tA", "a sealed board's placement must not be swapped")
        XCTAssertEqual(bt.version, 1, "no write happened — version untouched")
    }

    // MARK: - deleteBoard / deleteTask enqueue the sync-push fix
    //
    // Regression coverage for the deleted-boards-resurrect bugfix: both bare
    // soft-delete methods previously bumped isDeleted/version locally but
    // never enqueued a sync_queue row, so the tombstone never reached
    // Firestore and the entity resurrected (reinstall, re-auth, another
    // device). `deleteBoard` is the primary (user-facing, Boards-tab)
    // fix; `deleteTask` closes the same latent trap on the currently
    // caller-less bare method.

    func test_deleteBoard_enqueuesBoardsDeleteWithTombstonedPayload() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "delb"))

        try db.deleteBoard(id: "delb")

        let rows = try syncRows(db)
        XCTAssertEqual(count(rows, type: "boards", op: .delete), 1)

        let item = try XCTUnwrap(rows.first { $0.entityType == "boards" && $0.operationType == .delete })
        let payloadData = try XCTUnwrap(item.payload.data(using: .utf8))
        let payloadBoard = try JSONDecoder().decode(Board.self, from: payloadData)
        XCTAssertEqual(payloadBoard.id, "delb")
        XCTAssertTrue(payloadBoard.isDeleted, "the enqueued snapshot must carry the tombstone, not the pre-delete state")
        XCTAssertNotNil(payloadBoard.deletedAt)
    }

    func test_deleteTask_enqueuesTasksDeleteWithTombstonedPayload() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveTask(makeTask("delt"))

        try db.deleteTask(id: "delt")

        let rows = try syncRows(db)
        XCTAssertEqual(count(rows, type: "tasks", op: .delete), 1)

        let item = try XCTUnwrap(rows.first { $0.entityType == "tasks" && $0.operationType == .delete })
        let payloadData = try XCTUnwrap(item.payload.data(using: .utf8))
        let payloadTask = try JSONDecoder().decode(Task.self, from: payloadData)
        XCTAssertEqual(payloadTask.id, "delt")
        XCTAssertTrue(payloadTask.isDeleted, "the enqueued snapshot must carry the tombstone, not the pre-delete state")
        XCTAssertNotNil(payloadTask.deletedAt)
    }
}
