import XCTest
import GRDB
@testable import OYBC

/// Board Edit "Edit task…" compound support: converting a Simple / Counting
/// square INTO a Compound, editing an existing compound's rule + sub-tasks, and
/// the pending-compound link write. Drives the REAL view-model path
/// (`handleEditTaskOverride` → `handleEditSave` → reload) against an in-memory
/// `AppDatabase`.
@MainActor
final class BoardEditCompoundTests: XCTestCase {

    // MARK: - Fixtures

    private func makeDb() throws -> AppDatabase { try AppDatabase.makeTestInstance() }

    private func seedUser(_ db: AppDatabase) throws {
        let now = AppDatabase.currentTimestamp()
        try db.saveUser(User(
            id: "u1", email: "t@example.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
    }

    private func makeBoard(id: String) -> Board {
        let dict: [String: Any] = [
            "id": id, "userId": "u1", "name": "Board \(id)",
            "status": BoardStatus.active.rawValue, "boardSize": 3,
            "timeframe": Timeframe.monthly.rawValue,
            "startDate": "2026-06-21T00:00:00.000",
            "endDate": "2026-06-30T23:59:59.999",
            "centerSquareType": CenterSquareType.free.rawValue,
            "isRandomized": false, "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": "2026-06-21T00:00:00.000", "updatedAt": "2026-06-21T00:00:00.000",
            "version": 1, "isDeleted": false,
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    private func makeTask(
        _ id: String, type: TaskType = .normal, title: String? = nil,
        action: String? = nil, unit: String? = nil, maxCount: CountValue? = nil
    ) -> Task {
        let now = AppDatabase.currentTimestamp()
        return Task(
            id: id, userId: "u1", title: title ?? "Task \(id)", description: nil, type: type,
            action: action, unit: unit, maxCount: maxCount,
            operatorType: type == .compound ? .and : nil, threshold: nil,
            referencedBoardId: nil, referencedTemplateId: nil, achievementTrigger: nil, requiredCount: nil,
            totalCompletions: 0, totalInstances: 0, isCompleted: false, completedAt: nil, currentCount: nil,
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil,
            timeframe: nil, startDate: nil, endDate: nil, sharedCounterId: nil, baseline: nil,
            lastSyncedCount: nil, createdInWizard: false
        )
    }

    private func place(_ db: AppDatabase, _ taskId: String, col: Int) throws {
        let now = AppDatabase.currentTimestamp()
        try db.saveBoardTask(BoardTask(
            id: "bt-\(taskId)", boardId: "b1", taskId: taskId, row: 0, col: col, isCenter: false,
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
    }

    private func link(_ parent: String, _ child: String, _ idx: Int) -> CompoundChild {
        CompoundChild(
            id: "\(parent)-\(child)", compoundTaskId: parent, childTaskId: child, childIndex: idx,
            createdAt: "2026-06-21T00:00:00.000", updatedAt: "2026-06-21T00:00:00.000",
            version: 1, isDeleted: false
        )
    }

    private func newSub(_ id: String, _ title: String) -> ChildPatch {
        ChildPatch(id: id, childTaskId: nil, title: title, isCounting: false)
    }

    private func dbTask(_ db: AppDatabase, _ id: String) -> Task? {
        (try? db.fetchTasks(userId: "u1"))?.first { $0.id == id }
    }

    private func waitUntil(_ predicate: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(30)
        while !predicate() && Date() < deadline {
            RunLoop.current.run(until: Date().addingTimeInterval(0.01))
        }
        return predicate()
    }

    private func loadedVM(_ db: AppDatabase) -> BoardPlayViewModel {
        let vm = BoardPlayViewModel(boardId: "b1", userId: "u1", database: db)
        vm.reload()
        _ = waitUntil { vm.board?.id == "b1" && !vm.allTasks.isEmpty }
        vm.seedEditDraft(from: vm.board!)
        return vm
    }

    private func patch(
        _ title: String, _ type: TaskType, compound: TaskEditPatch? = nil,
        action: String = "", unit: String = "", maxCount: CountValue? = nil
    ) -> SquareEditTaskSheet.Patch {
        .init(title: title, type: type, action: action, unit: unit, maxCount: maxCount, compound: compound)
    }

    private func save(_ vm: BoardPlayViewModel) -> BoardPlayEditEvent.Outcome? {
        XCTAssertTrue(vm.handleEditSave(), "save should dispatch")
        XCTAssertTrue(waitUntil { vm.editEvent?.outcome != nil }, "no outcome emitted")
        return vm.editEvent?.outcome
    }

    // MARK: - Counting → Compound

    func test_countingToCompound_convertsRowAndWritesChildren() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        var counting = makeTask("tc", type: .counting, action: "Run", unit: "km", maxCount: 5)
        counting.isCompleted = true
        counting.completedAt = "2026-06-22T00:00:00.000"
        counting.currentCount = 3
        try db.saveTask(counting)
        try place(db, "tc", col: 0)

        let vm = loadedVM(db)
        var structure = TaskEditPatch(title: "Routine")
        structure.operatorType = .or
        structure.children = [newSub("n1", "Stretch"), newSub("n2", "Hydrate")]
        vm.handleEditTaskOverride(taskId: "tc", patch: patch("Routine", .compound, compound: structure))
        XCTAssertEqual(vm.editDraftTaskMap["tc"]?.type, .compound, "the staged grid renders the conversion")

        XCTAssertEqual(save(vm), .saved)

        let row = try XCTUnwrap(dbTask(db, "tc"))
        XCTAssertEqual(row.type, .compound)
        XCTAssertEqual(row.title, "Routine")
        XCTAssertEqual(row.operatorType, .or)
        XCTAssertNil(row.action); XCTAssertNil(row.unit); XCTAssertNil(row.maxCount)
        XCTAssertFalse(row.isCompleted)
        XCTAssertNil(row.completedAt)
        XCTAssertNil(row.currentCount, "conversion clears the counting latch (web parity)")
        XCTAssertGreaterThan(row.version, 1, "version bumped")
        XCTAssertEqual(try db.fetchCompoundChildrenTasks(parentTaskId: "tc").map(\.title), ["Stretch", "Hydrate"])
        let sync = try db.fetchPendingSyncItems()
        XCTAssertTrue(sync.contains { $0.entityType == "tasks" && $0.entityId == "tc" })
        XCTAssertEqual(sync.filter { $0.entityType == "compoundChildren" }.count, 2)
        XCTAssertEqual(try db.fetchBoardTasks(boardId: "b1").first { $0.id == "bt-tc" }?.taskId, "tc",
                       "the placement keeps its task id")
    }

    // MARK: - Existing compound

    func test_existingCompound_ruleChangeRemoveChildLinkExisting() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeTask("cmp", type: .compound))
        for id in ["c1", "c2", "c3"] { try db.saveTask(makeTask(id)) }
        try place(db, "cmp", col: 0)
        try db.dbQueue.write { d in
            try link("cmp", "c1", 0).insert(d)
            try link("cmp", "c2", 1).insert(d)
        }

        let vm = loadedVM(db)
        let existing = try db.fetchCompoundChildrenTasks(parentTaskId: "cmp")
        var structure = EditTaskSheet.seedCompoundDraft(task: try XCTUnwrap(dbTask(db, "cmp")), children: existing)
        structure.operatorType = .or
        structure.children[1].markedDeleted = true                      // drop c2
        structure.children.append(ChildPatch(from: try XCTUnwrap(dbTask(db, "c3"))))  // link library c3
        structure.title = "Renamed"
        vm.handleEditTaskOverride(taskId: "cmp", patch: patch("Renamed", .compound, compound: structure))

        XCTAssertEqual(save(vm), .saved)

        let row = try XCTUnwrap(dbTask(db, "cmp"))
        XCTAssertEqual(row.operatorType, .or)
        XCTAssertEqual(row.title, "Renamed")
        XCTAssertEqual(try db.fetchCompoundChildrenTasks(parentTaskId: "cmp").map(\.id), ["c1", "c3"])
        XCTAssertNotNil(dbTask(db, "c2"), "an unlinked sub-task survives in the library")
    }

    // MARK: - Invalid compound → Save rejected, nothing written

    func test_invalidCompound_rejectsSave_writesNothing() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeTask("tn"))
        try db.saveTask(makeTask("other"))
        try place(db, "tn", col: 0)
        try place(db, "other", col: 1)

        let vm = loadedVM(db)
        var structure = TaskEditPatch(title: "Solo")
        structure.operatorType = .and
        structure.children = [] // zero sub-tasks: the only remaining structural block
        vm.handleEditTaskOverride(taskId: "tn", patch: patch("Solo", .compound, compound: structure))
        vm.handleEditTaskOverride(taskId: "other", patch: patch("Renamed other", .normal))

        XCTAssertFalse(vm.handleEditSave(), "an invalid compound never dispatches")
        guard case .saveFailed(let message) = try XCTUnwrap(vm.editEvent?.outcome) else {
            return XCTFail("expected .saveFailed")
        }
        XCTAssertTrue(message.contains("needs a sub-task"), message)
        XCTAssertEqual(dbTask(db, "tn")?.type, .normal)
        XCTAssertEqual(dbTask(db, "other")?.title, "Task other", "the other staged edit did not commit")
        XCTAssertTrue(try db.fetchAllCompoundChildren().isEmpty)
        XCTAssertFalse(vm.editSaveInFlight)
    }

    /// A link the guard refuses (the compound picked as its own sub-task) is
    /// caught before the write too — nothing written.
    func test_linkGuardProblem_rejectsSave_writesNothing() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeTask("tn"))
        try place(db, "tn", col: 0)
        try db.saveTask(makeTask("lib"))

        let vm = loadedVM(db)
        var structure = TaskEditPatch(title: "Bad")
        structure.operatorType = .and
        structure.children = [newSub("n1", "A"), ChildPatch(from: try XCTUnwrap(dbTask(db, "lib")))]
        // Loop guard: the compound being converted can't contain itself.
        structure.children.append(ChildPatch(from: try XCTUnwrap(dbTask(db, "tn"))))
        vm.handleEditTaskOverride(taskId: "tn", patch: patch("Bad", .compound, compound: structure))

        XCTAssertFalse(vm.handleEditSave())
        guard case .saveFailed = try XCTUnwrap(vm.editEvent?.outcome) else { return XCTFail("expected .saveFailed") }
        XCTAssertEqual(dbTask(db, "tn")?.type, .normal)
        XCTAssertTrue(try db.fetchAllCompoundChildren().isEmpty)
    }

    // MARK: - Pending (picker-born) tasks

    func test_pendingTask_withCompoundOverride_isInsertedConverted() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeTask("lib"))

        let vm = loadedVM(db)
        vm.handleEditAdd(
            cellKey: "0-0", taskId: "pend",
            pending: PendingTaskPayload(task: makeTask("pend"), childTasks: [], childLinks: [])
        )
        var structure = TaskEditPatch(title: "Fresh compound")
        structure.operatorType = .and
        structure.children = [newSub("n1", "One"), ChildPatch(from: try XCTUnwrap(dbTask(db, "lib")))]
        vm.handleEditTaskOverride(taskId: "pend", patch: patch("Fresh compound", .compound, compound: structure))

        XCTAssertEqual(save(vm), .saved)

        let row = try XCTUnwrap(dbTask(db, "pend"))
        XCTAssertEqual(row.type, .compound)
        XCTAssertEqual(row.title, "Fresh compound")
        XCTAssertEqual(try db.fetchCompoundChildrenTasks(parentTaskId: "pend").map(\.title), ["One", "Task lib"])
        XCTAssertEqual(try db.fetchBoardTasks(boardId: "b1").first?.taskId, "pend")
    }

    /// Bug fix: a pending compound with one NEW and one EXISTING sub-task has
    /// `childLinks.count > childTasks.count`; the old `zip` wrote the wrong
    /// pair / dropped a link.
    func test_pendingCompound_newAndExistingChild_writesBothLinks() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeTask("existing"))
        try db.saveTask(makeTask("lib"))

        let vm = loadedVM(db)
        let parent = makeTask("pcmp", type: .compound)
        let newChild = makeTask("newkid")
        let payload = PendingTaskPayload(
            task: parent,
            childTasks: [newChild],
            childLinks: [link("pcmp", "existing", 0), link("pcmp", "newkid", 1)]
        )
        vm.handleEditAdd(cellKey: "0-0", taskId: "pcmp", pending: payload)

        XCTAssertEqual(save(vm), .saved)

        XCTAssertEqual(try db.fetchCompoundChildrenTasks(parentTaskId: "pcmp").map(\.id), ["existing", "newkid"])
        XCTAssertNotNil(dbTask(db, "newkid"))
        let sync = try db.fetchPendingSyncItems()
        XCTAssertEqual(sync.filter { $0.entityType == "compoundChildren" }.count, 2)
    }

    // MARK: - Reopen (the sheet's seeding + Done, driven through the real VM path)

    /// What the presenter hands the sheet for `id`, then what reopen-and-Done
    /// stages: seeds via the sheet's own `compoundSeed`, submits via its own
    /// `compoundSubmission`, then `handleEditTaskOverride`. Returns the seed.
    @discardableResult
    private func reopenAndDone(
        _ vm: BoardPlayViewModel, _ id: String, chooseType: TaskType? = nil,
        title: String? = nil, children: [Task]? = nil
    ) throws -> SquareEditTaskSheet.CompoundSeed {
        let merged = try XCTUnwrap(vm.editDraftTaskMap[id])
        let original = vm.taskMap[id]
        let seed = SquareEditTaskSheet.compoundSeed(
            task: merged, original: original,
            staged: vm.editTaskOverrides[id]?.compound, children: children
        )
        let type = chooseType ?? merged.type
        let compound = SquareEditTaskSheet.compoundSubmission(
            type: type, originalType: (original ?? merged).type, seededFromStaged: seed.fromStaged,
            baseline: seed.baseline, draft: seed.draft, title: title ?? merged.title
        )
        vm.handleEditTaskOverride(taskId: id, patch: patch(title ?? merged.title, type, compound: compound))
        return seed
    }

    /// Critical: convert → reopen → the editor shows the staged sub-tasks →
    /// Done re-stages them (it used to overwrite the override with nil, which
    /// silently dropped the conversion) → Save converts.
    func test_convertThenReopenDone_keepsStagedConversion() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeTask("tn"))
        try place(db, "tn", col: 0)

        let vm = loadedVM(db)
        var structure = SquareEditTaskSheet.newCompoundDraft(for: try XCTUnwrap(dbTask(db, "tn")))
        structure.children = [newSub("n1", "Stretch"), newSub("n2", "Hydrate")]
        vm.handleEditTaskOverride(taskId: "tn", patch: patch("Task tn", .compound, compound: structure))

        let seed = try reopenAndDone(vm, "tn")
        XCTAssertTrue(seed.fromStaged)
        XCTAssertEqual(seed.draft?.children.map(\.title), ["Stretch", "Hydrate"], "reopen shows the staged sub-tasks")
        XCTAssertEqual(vm.editTaskOverrides["tn"]?.compound?.children.count, 2, "Done re-stages, not nil")
        XCTAssertEqual(vm.editDraftTaskMap["tn"]?.type, .compound)

        XCTAssertEqual(save(vm), .saved)
        XCTAssertEqual(dbTask(db, "tn")?.type, .compound)
        XCTAssertEqual(try db.fetchCompoundChildrenTasks(parentTaskId: "tn").map(\.title), ["Stretch", "Hydrate"])
    }

    /// The same for an existing compound: a staged rule + sub-task edit
    /// survives reopen-then-Done and applies at Save.
    func test_existingCompoundStagedEdit_reopenDone_applies() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeTask("cmp", type: .compound))
        for id in ["c1", "c2", "c3"] { try db.saveTask(makeTask(id)) }
        try place(db, "cmp", col: 0)
        try db.dbQueue.write { d in
            try link("cmp", "c1", 0).insert(d)
            try link("cmp", "c2", 1).insert(d)
        }

        let vm = loadedVM(db)
        let existing = try db.fetchCompoundChildrenTasks(parentTaskId: "cmp")
        var structure = EditTaskSheet.seedCompoundDraft(task: try XCTUnwrap(dbTask(db, "cmp")), children: existing)
        structure.operatorType = .or
        structure.children[1].markedDeleted = true
        structure.children.append(ChildPatch(from: try XCTUnwrap(dbTask(db, "c3"))))
        vm.handleEditTaskOverride(taskId: "cmp", patch: patch("Task cmp", .compound, compound: structure))

        // Reopen: children are NOT passed (the staged draft wins over the DB).
        let seed = try reopenAndDone(vm, "cmp")
        XCTAssertTrue(seed.fromStaged)
        XCTAssertEqual(seed.draft?.operatorType, .or)
        XCTAssertNotNil(vm.editTaskOverrides["cmp"]?.compound, "Done keeps the staged edit")

        XCTAssertEqual(save(vm), .saved)
        XCTAssertEqual(dbTask(db, "cmp")?.operatorType, .or)
        XCTAssertEqual(try db.fetchCompoundChildrenTasks(parentTaskId: "cmp").map(\.id), ["c1", "c3"])
    }

    /// An UNEDITED existing compound reopened and Done'd stages no structure.
    func test_existingCompoundUntouched_reopenDone_stagesNoStructure() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeTask("cmp", type: .compound))
        try db.saveTask(makeTask("c1")); try db.saveTask(makeTask("c2"))
        try place(db, "cmp", col: 0)
        try db.dbQueue.write { d in
            try link("cmp", "c1", 0).insert(d)
            try link("cmp", "c2", 1).insert(d)
        }
        let vm = loadedVM(db)
        try reopenAndDone(vm, "cmp", title: "Just a rename",
                          children: try db.fetchCompoundChildrenTasks(parentTaskId: "cmp"))
        XCTAssertNil(vm.editTaskOverrides["cmp"]?.compound)
        XCTAssertEqual(save(vm), .saved)
        XCTAssertEqual(dbTask(db, "cmp")?.title, "Just a rename")
    }

    // MARK: - Switch back before Save

    func test_stagedCompound_reopen_switchBackToSimple_isPlainTitleEdit() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeTask("tn"))
        try place(db, "tn", col: 0)

        let vm = loadedVM(db)
        var structure = SquareEditTaskSheet.newCompoundDraft(for: try XCTUnwrap(dbTask(db, "tn")))
        structure.children = [newSub("n1", "A"), newSub("n2", "B")]
        vm.handleEditTaskOverride(taskId: "tn", patch: patch("Task tn", .compound, compound: structure))

        // Reopen: the merged task is Compound, but the sheet knows the original.
        let merged = try XCTUnwrap(vm.editDraftTaskMap["tn"])
        XCTAssertEqual(merged.type, .compound)
        XCTAssertTrue(SquareEditTaskSheet.showsTypePicker(task: merged, original: vm.taskMap["tn"]),
                      "the picker stays so the user can switch back")
        XCTAssertFalse(SquareEditTaskSheet.showsTypePicker(task: merged, original: nil),
                       "without the original a merged compound would look fixed")

        try reopenAndDone(vm, "tn", chooseType: .normal, title: "Renamed")
        XCTAssertNil(vm.editTaskOverrides["tn"]?.compound)
        XCTAssertEqual(vm.editDraftTaskMap["tn"]?.type, .normal)

        XCTAssertEqual(save(vm), .saved)
        let row = try XCTUnwrap(dbTask(db, "tn"))
        XCTAssertEqual(row.type, .normal, "no conversion")
        XCTAssertEqual(row.title, "Renamed")
        XCTAssertTrue(try db.fetchAllCompoundChildren().isEmpty)
        XCTAssertNil(dbTask(db, "n1"), "no sub-task rows were minted")
    }

    // MARK: - Linked counters are not convertible

    private func linkedCounter(_ id: String) -> Task {
        var t = makeTask(id, type: .counting, action: "Run", unit: "km", maxCount: 5)
        t.sharedCounterId = "sc1"
        return t
    }

    func test_linkedCounter_sheetShowsFixedType() {
        let t = linkedCounter("lc")
        XCTAssertFalse(SquareEditTaskSheet.showsTypePicker(task: t, original: t))
        XCTAssertTrue(SquareEditTaskSheet.showsTypePicker(task: makeTask("plain", type: .counting), original: nil))
    }

    func test_linkedCounter_typeOrCompoundOverride_rejectedBeforeSave() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(linkedCounter("lc"))
        try db.saveTask(makeTask("other"))
        try place(db, "lc", col: 0)
        try place(db, "other", col: 1)

        let vm = loadedVM(db)
        var structure = TaskEditPatch(title: "X")
        structure.operatorType = .and
        structure.children = [newSub("n1", "A"), newSub("n2", "B")]
        vm.handleEditTaskOverride(taskId: "lc", patch: patch("X", .compound, compound: structure))
        vm.handleEditTaskOverride(taskId: "other", patch: patch("Renamed other", .normal))
        XCTAssertEqual(vm.editDraftTaskMap["lc"]?.type, .counting, "the grid never shows a linked conversion")

        XCTAssertFalse(vm.handleEditSave())
        guard case .saveFailed(let m) = try XCTUnwrap(vm.editEvent?.outcome) else { return XCTFail("expected .saveFailed") }
        XCTAssertEqual(m, BoardPlayViewModel.linkedCounterTypeMessage)
        XCTAssertEqual(dbTask(db, "lc")?.type, .counting)
        XCTAssertEqual(dbTask(db, "other")?.title, "Task other")

        // Counting → Simple is refused too.
        vm.editTaskOverrides = [:]
        vm.handleEditTaskOverride(taskId: "lc", patch: patch("Plain", .normal))
        XCTAssertFalse(vm.handleEditSave())
    }

    /// The in-transaction guard throws (and rolls the write back) even if the
    /// pre-validation were bypassed.
    func test_linkedCounter_typeOverride_throwsInTransaction() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(linkedCounter("lc"))
        try place(db, "lc", col: 0)
        let task = try XCTUnwrap(dbTask(db, "lc"))
        let override = StagedTaskOverride(title: "Plain", type: .normal, action: nil, unit: nil, maxCount: nil, compound: nil)
        let cell = BoardPlayViewModel.StagedCellRef(boardTaskId: "bt-lc", isNew: false, row: 0, col: 0, stagedTaskId: "lc")
        XCTAssertThrowsError(try db.write { d in
            try BoardPlayViewModel.applyStagedOverrides(
                db: d, boardId: "b1",
                overrides: [.init(stagedId: "lc", override: override, mapTask: task)],
                cells: [cell], now: AppDatabase.currentTimestamp()
            )
        })
        XCTAssertEqual(dbTask(db, "lc")?.type, .counting)
    }

    // MARK: - Overrides for squares no longer on the board are dropped

    func test_convertThenRemove_commitsNothing() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeTask("ta"))
        try db.saveTask(makeTask("tb"))
        try place(db, "ta", col: 0)
        try place(db, "tb", col: 1)

        let vm = loadedVM(db)
        var structure = SquareEditTaskSheet.newCompoundDraft(for: try XCTUnwrap(dbTask(db, "ta")))
        structure.children = [newSub("n1", "A"), newSub("n2", "B")]
        vm.handleEditTaskOverride(taskId: "ta", patch: patch("Task ta", .compound, compound: structure))
        vm.handleEditRemove(cellKey: "0-0")

        XCTAssertEqual(save(vm), .saved)
        XCTAssertEqual(dbTask(db, "ta")?.type, .normal, "the removed square's conversion must not commit")
        XCTAssertTrue(try db.fetchAllCompoundChildren().isEmpty)
    }

    /// An INVALID staged compound on a square that was then removed must not
    /// block the Save either.
    func test_invalidCompoundOnRemovedSquare_doesNotBlockSave() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeTask("ta"))
        try db.saveTask(makeTask("tb"))
        try place(db, "ta", col: 0)
        try place(db, "tb", col: 1)

        let vm = loadedVM(db)
        var structure = TaskEditPatch(title: "Solo")
        structure.operatorType = .and
        structure.children = [newSub("n1", "Only")]
        vm.handleEditTaskOverride(taskId: "ta", patch: patch("Solo", .compound, compound: structure))
        vm.handleEditRemove(cellKey: "0-0")
        XCTAssertEqual(save(vm), .saved)
        XCTAssertEqual(dbTask(db, "ta")?.type, .normal)
    }

    func test_convertThenReplace_commitsNothingOnOriginal() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeTask("ta"))
        try db.saveTask(makeTask("tb"))
        try place(db, "ta", col: 0)

        let vm = loadedVM(db)
        var structure = SquareEditTaskSheet.newCompoundDraft(for: try XCTUnwrap(dbTask(db, "ta")))
        structure.children = [newSub("n1", "A"), newSub("n2", "B")]
        vm.handleEditTaskOverride(taskId: "ta", patch: patch("Task ta", .compound, compound: structure))
        vm.handleEditReplace(cellKey: "0-0", taskId: "tb")

        XCTAssertEqual(save(vm), .saved)
        XCTAssertEqual(dbTask(db, "ta")?.type, .normal)
        XCTAssertEqual(dbTask(db, "tb")?.type, .normal)
        XCTAssertTrue(try db.fetchAllCompoundChildren().isEmpty)
        XCTAssertEqual(try db.fetchBoardTasks(boardId: "b1").first { $0.id == "bt-ta" }?.taskId, "tb")
    }

    // MARK: - Default operator + real derivation

    /// The sheet's default rule is "all" (`.and`); a converted compound
    /// completes only when BOTH sub-tasks are complete, through the real
    /// completion + derivation path.
    func test_convertedCompound_defaultsToAnd_andCompletesWhenBothChildrenDo() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeTask("tn"))
        let bt = BoardTask(
            id: "bt-tn", boardId: "b1", taskId: "tn", row: 0, col: 0, isCenter: false,
            createdAt: AppDatabase.currentTimestamp(), updatedAt: AppDatabase.currentTimestamp(),
            lastSyncedAt: nil, version: 1
        )
        try db.saveBoardTask(bt)

        let vm = loadedVM(db)
        var structure = SquareEditTaskSheet.newCompoundDraft(for: try XCTUnwrap(dbTask(db, "tn")))
        XCTAssertEqual(structure.operatorType, .and, "the sheet's default rule")
        structure.children = [newSub("n1", "One"), newSub("n2", "Two")]
        vm.handleEditTaskOverride(taskId: "tn", patch: patch("Task tn", .compound, compound: structure))
        XCTAssertEqual(save(vm), .saved)

        let row = try XCTUnwrap(dbTask(db, "tn"))
        XCTAssertEqual(row.operatorType, .and)
        let kids = try db.fetchCompoundChildrenTasks(parentTaskId: "tn")
        XCTAssertEqual(kids.count, 2)

        let now = AppDatabase.currentTimestamp()
        func complete(_ id: String) throws {
            let board = try XCTUnwrap(try db.fetchBoard(id: "b1"))
            _ = try db.completeTaskOrchestrated(
                board: board, taskId: id, intent: .setCompleted(true), boardTask: bt, now: now
            )
        }
        // Board stats: the FREE center counts as 1; the compound adds 1 only once derived complete.
        try complete(kids[0].id)
        XCTAssertEqual(try XCTUnwrap(try db.fetchBoard(id: "b1")).completedTasks, 1,
                       "one of two is not enough under AND")
        try complete(kids[1].id)
        XCTAssertEqual(try XCTUnwrap(try db.fetchBoard(id: "b1")).completedTasks, 2,
                       "both children complete the compound")
    }

    // MARK: - Simple ⇄ Counting (unchanged)

    func test_simpleCountingSwitch_unchanged() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        try db.saveTask(makeTask("s"))
        try db.saveTask(makeTask("c", type: .counting, action: "Run", unit: "km", maxCount: 5))
        try place(db, "s", col: 0)
        try place(db, "c", col: 1)

        let vm = loadedVM(db)
        vm.handleEditTaskOverride(taskId: "s", patch: patch("Now counting", .counting, action: "Read", unit: "pages", maxCount: 20))
        vm.handleEditTaskOverride(taskId: "c", patch: patch("Now simple", .normal))
        XCTAssertEqual(save(vm), .saved)

        let s = try XCTUnwrap(dbTask(db, "s"))
        XCTAssertEqual(s.type, .counting)
        XCTAssertEqual(s.maxCount, 20)
        XCTAssertEqual(s.unit, "pages")
        let c = try XCTUnwrap(dbTask(db, "c"))
        XCTAssertEqual(c.type, .normal)
        XCTAssertNil(c.action); XCTAssertNil(c.unit); XCTAssertNil(c.maxCount)
    }

    // MARK: - Counting title: auto seeds blank, blank regenerates at Save

    func test_seededTitle_autoCountingTitleSeedsBlank_customAndOtherTypesVerbatim() {
        typealias Sheet = SquareEditTaskSheet
        // Auto ("Run 5 km" for Run / 5 / km) → blank; end-whitespace and an
        // empty title are auto too.
        XCTAssertEqual(Sheet.seededTitle(for: makeTask("a", type: .counting, title: "Run 5 km", action: "Run", unit: "km", maxCount: 5)), "")
        XCTAssertEqual(Sheet.seededTitle(for: makeTask("a", type: .counting, title: " Run 5 km ", action: "Run", unit: "km", maxCount: 5)), "")
        XCTAssertEqual(Sheet.seededTitle(for: makeTask("a", type: .counting, title: "", action: "Run", unit: "km", maxCount: 5)), "")
        // Custom (case-sensitive compare) → verbatim.
        XCTAssertEqual(Sheet.seededTitle(for: makeTask("a", type: .counting, title: "Morning run", action: "Run", unit: "km", maxCount: 5)), "Morning run")
        XCTAssertEqual(Sheet.seededTitle(for: makeTask("a", type: .counting, title: "run 5 km", action: "Run", unit: "km", maxCount: 5)), "run 5 km")
        // Never blanks a non-Counting title, even one that looks generated.
        XCTAssertEqual(Sheet.seededTitle(for: makeTask("a", title: "Run 5 km", action: "Run", unit: "km", maxCount: 5)), "Run 5 km")
        XCTAssertEqual(Sheet.seededTitle(for: makeTask("a", type: .compound, title: "Combo")), "Combo")
    }

    /// The staged grid (`editDraftTaskMap`) reads through `applyingOverride`
    /// too, so a blank Counting title shows regenerated — never an empty cell.
    func test_applyingOverride_blankCountingTitle_regeneratesFromFields() {
        let stored = makeTask("c", type: .counting, title: "Run 5 km", action: "Run", unit: "km", maxCount: 5)
        let override = StagedTaskOverride(title: "", type: .counting, action: "Run", unit: "km", maxCount: 8, compound: nil)
        let merged = BoardPlayViewModel.applyingOverride(override, to: stored)
        XCTAssertEqual(merged.title, "Run 8 km")
        XCTAssertEqual(merged.maxCount, 8)
        // A typed title is carried verbatim.
        let custom = StagedTaskOverride(title: "Morning run", type: .counting, action: "Run", unit: "km", maxCount: 8, compound: nil)
        XCTAssertEqual(BoardPlayViewModel.applyingOverride(custom, to: stored).title, "Morning run")
        // A blank title on a Simple task stays blank here (the sheet never
        // submits one — Done is disabled); only Counting regenerates.
        let simple = StagedTaskOverride(title: "", type: .normal, action: nil, unit: nil, maxCount: nil, compound: nil)
        XCTAssertEqual(BoardPlayViewModel.applyingOverride(simple, to: makeTask("s")).title, "")
    }

    /// M11 — a Simple → Counting conversion with no staged kind writes
    /// Discrete explicitly, overwriting a stale kind left on the row (web
    /// `compoundStructureEdit`: `stagedKind ?? 'discrete'`). A stored counting
    /// row with no staged kind keeps its own.
    func test_applyingOverride_conversionIntoCounting_defaultsKindToDiscrete() {
        var simple = makeTask("s")
        simple.countKind = .continuous
        let override = StagedTaskOverride(title: "", type: .counting, action: "Run", unit: "km", maxCount: 5, compound: nil)
        XCTAssertEqual(BoardPlayViewModel.applyingOverride(override, to: simple, writesKind: true).countKind, .discrete)
        var counting = makeTask("c", type: .counting, title: "Run 5 km", action: "Run", unit: "km", maxCount: 5)
        counting.countKind = .continuous
        XCTAssertEqual(BoardPlayViewModel.applyingOverride(override, to: counting, writesKind: true).countKind, .continuous)
    }

    func test_countingGoalOnlyEdit_autoTitle_isRegeneratedAtTheNewGoal() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        let stored = makeTask("c", type: .counting, title: "Run 5 km", action: "Run", unit: "km", maxCount: 5)
        try db.saveTask(stored)
        try place(db, "c", col: 0)

        let vm = loadedVM(db)
        // The sheet opens an auto-titled counter BLANK and Done submits the
        // field as-is; only the goal changed.
        let seeded = SquareEditTaskSheet.seededTitle(for: stored)
        XCTAssertEqual(seeded, "")
        vm.handleEditTaskOverride(taskId: "c", patch: patch(seeded, .counting, action: "Run", unit: "km", maxCount: 8))
        XCTAssertEqual(save(vm), .saved)

        let c = try XCTUnwrap(dbTask(db, "c"))
        XCTAssertEqual(c.type, .counting)
        XCTAssertEqual(c.maxCount, 8)
        XCTAssertEqual(c.title, "Run 8 km", "the stale 'Run 5 km' must not survive a goal of 8")
        XCTAssertEqual(c.version, 2)
    }

    func test_countingGoalOnlyEdit_customTitle_isKept() throws {
        let db = try makeDb()
        try seedUser(db)
        try db.saveBoard(makeBoard(id: "b1"))
        let stored = makeTask("c", type: .counting, title: "Morning run", action: "Run", unit: "km", maxCount: 5)
        try db.saveTask(stored)
        try place(db, "c", col: 0)

        let vm = loadedVM(db)
        let seeded = SquareEditTaskSheet.seededTitle(for: stored)
        XCTAssertEqual(seeded, "Morning run")
        vm.handleEditTaskOverride(taskId: "c", patch: patch(seeded, .counting, action: "Run", unit: "km", maxCount: 8))
        XCTAssertEqual(save(vm), .saved)

        let c = try XCTUnwrap(dbTask(db, "c"))
        XCTAssertEqual(c.maxCount, 8)
        XCTAssertEqual(c.title, "Morning run")
    }

    func test_boardEditAllowsTypeSwitch_matrix() {
        typealias VM = BoardPlayViewModel
        XCTAssertTrue(VM.boardEditAllowsTypeSwitch(from: .normal, to: .compound))
        XCTAssertTrue(VM.boardEditAllowsTypeSwitch(from: .counting, to: .compound))
        XCTAssertFalse(VM.boardEditAllowsTypeSwitch(from: .compound, to: .normal))
        XCTAssertFalse(VM.boardEditAllowsTypeSwitch(from: .compound, to: .counting))
        XCTAssertFalse(VM.boardEditAllowsTypeSwitch(from: .normal, to: .achievement))
        XCTAssertFalse(VM.boardEditAllowsTypeSwitch(from: .achievement, to: .compound))
    }

    /// "Reads as {title}" — one format on both platforms (web `BoardEditTaskSheet`).
    func test_countingPreviewTitle_readsAsGeneratedOrTypedTitle() {
        typealias S = SquareEditTaskSheet
        XCTAssertEqual(S.countingPreviewTitle(title: "", action: "Run", goalText: "5", unit: "km", kind: .discrete), "Run 5 km")
        XCTAssertEqual(S.countingPreviewTitle(title: "Morning run", action: "Run", goalText: "5", unit: "km", kind: .discrete), "Morning run")
        XCTAssertNil(S.countingPreviewTitle(title: "", action: "Run", goalText: "", unit: "km", kind: .discrete))
        XCTAssertNil(S.countingPreviewTitle(title: "", action: "Run", goalText: "5", unit: "", kind: .discrete))
    }
}
