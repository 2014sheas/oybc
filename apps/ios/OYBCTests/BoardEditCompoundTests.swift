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
        _ id: String, type: TaskType = .normal, action: String? = nil, unit: String? = nil, maxCount: Int? = nil
    ) -> Task {
        let now = AppDatabase.currentTimestamp()
        return Task(
            id: id, userId: "u1", title: "Task \(id)", description: nil, type: type,
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
        action: String = "", unit: String = "", maxCount: Int? = nil
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
        structure.children = [newSub("n1", "Only one")]
        vm.handleEditTaskOverride(taskId: "tn", patch: patch("Solo", .compound, compound: structure))
        vm.handleEditTaskOverride(taskId: "other", patch: patch("Renamed other", .normal))

        XCTAssertFalse(vm.handleEditSave(), "an invalid compound never dispatches")
        guard case .saveFailed(let message) = try XCTUnwrap(vm.editEvent?.outcome) else {
            return XCTFail("expected .saveFailed")
        }
        XCTAssertTrue(message.contains("at least two"), message)
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

    func test_boardEditAllowsTypeSwitch_matrix() {
        typealias VM = BoardPlayViewModel
        XCTAssertTrue(VM.boardEditAllowsTypeSwitch(from: .normal, to: .compound))
        XCTAssertTrue(VM.boardEditAllowsTypeSwitch(from: .counting, to: .compound))
        XCTAssertFalse(VM.boardEditAllowsTypeSwitch(from: .compound, to: .normal))
        XCTAssertFalse(VM.boardEditAllowsTypeSwitch(from: .compound, to: .counting))
        XCTAssertFalse(VM.boardEditAllowsTypeSwitch(from: .normal, to: .achievement))
        XCTAssertFalse(VM.boardEditAllowsTypeSwitch(from: .achievement, to: .compound))
    }
}
