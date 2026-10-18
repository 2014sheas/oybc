import XCTest
import GRDB
@testable import OYBC

/// Linked counters and the placement choke points (`addBoardTaskToBoard` /
/// `updateBoardTaskAndCascade`): since TASK_WINDOW_REWORK slice 3a they place the
/// task AS-IS — no per-board row is minted. The ViewModel tests drive the REAL
/// Board Edit Save and its parameter / task-edit split.
@MainActor
final class LinkedCounterPlacementMintTests: XCTestCase {
    private typealias K = LinkedWindowKit
    private let septStart = "2026-09-01T00:00:00.000Z", septEnd = "2026-09-30T00:00:00.000Z"
    private let augStart = "2026-08-01T00:00:00.000Z", augEnd = "2026-08-31T00:00:00.000Z"

    private func derived(_ board: String) -> String { BoardSources.derivedTaskId(boardId: board, rootTaskId: "root") }

    private func makeDb(size: Int = 3) throws -> AppDatabase {
        let db = try AppDatabase.makeTestInstance()
        try K.seedUser(db)
        try db.saveTask(K.task("root", maxCount: 100, currentCount: 4))
        try db.saveBoard(K.board(id: "b1", startDate: septStart, endDate: septEnd, size: size))
        return db
    }

    func test_add_hubLinkedTask_isPlacedAsIs_noRowMinted() throws {
        let db = try makeDb()
        try db.saveTask(K.task("hub", sharedCounterId: "root"))
        try K.addIncrement(db, taskId: "root", delta: 4, occurredAt: "2026-08-15T00:00:00.000Z")

        let bt = try db.addBoardTaskToBoard("b1", taskId: "hub", position: (row: 0, col: 0))
        XCTAssertEqual(bt.taskId, "hub", "slice 3a: writers stop minting")
        XCTAssertNil(bt.targetOverride)
        XCTAssertNil(try K.fetchTask(db, derived("b1")))
        XCTAssertTrue(try K.queue(db, type: "tasks", id: derived("b1")).isEmpty)
        XCTAssertEqual(try K.fetchTask(db, "hub")?.version, 1, "the library row is untouched")
    }

    func test_add_continuousHubLinkedTask_isPlacedAsIs() throws {
        let db = try makeDb()
        var hub = K.task("hub", maxCount: 2.5, sharedCounterId: "root")
        hub.countKind = .continuous
        try db.saveTask(hub)

        let bt = try db.addBoardTaskToBoard("b1", taskId: "hub", position: (row: 0, col: 0))
        XCTAssertEqual(bt.taskId, "hub")
        XCTAssertNil(try K.fetchTask(db, derived("b1")))
    }

    func test_add_taskStampedForAnotherWindow_isPlacedAsIs() throws {
        let db = try makeDb()
        try db.saveTask(K.task("aug", sharedCounterId: "root", startDate: augStart, endDate: augEnd, createdInWizard: true))
        let bt = try db.addBoardTaskToBoard("b1", taskId: "aug", position: (row: 0, col: 0))
        XCTAssertEqual(bt.taskId, "aug")
        XCTAssertNil(try K.fetchTask(db, derived("b1")))
        XCTAssertEqual(try K.fetchTask(db, "aug")?.startDate, augStart, "the other window's row is untouched")
    }

    func test_add_taskAlreadyStampedForThisBoard_isPlacedAsIs() throws {
        let db = try makeDb()
        try db.saveTask(K.task("mine", sharedCounterId: "root", startDate: septStart, endDate: septEnd, createdInWizard: true))
        let bt = try db.addBoardTaskToBoard("b1", taskId: "mine", position: (row: 0, col: 0))
        XCTAssertEqual(bt.taskId, "mine")
        XCTAssertNil(try K.fetchTask(db, derived("b1")))
    }

    func test_add_plainTaskUntouched() throws {
        let db = try makeDb()
        try db.saveTask(K.task("plain", maxCount: 5))
        XCTAssertEqual(try db.addBoardTaskToBoard("b1", taskId: "plain", position: (row: 0, col: 1)).taskId, "plain")
    }

    func test_replace_hubLinkedTask_repointsToTheTaskItself() throws {
        let db = try makeDb()
        try db.saveTask(K.task("old", maxCount: 5))
        try db.saveTask(K.task("hub", sharedCounterId: "root"))
        try db.saveBoardTask(K.placement(id: "bt", boardId: "b1", taskId: "old", size: 3))
        try db.updateBoardTaskAndCascade(boardTaskId: "bt", newTaskId: "hub")
        XCTAssertEqual(try db.fetchBoardTasks(boardId: "b1").first?.taskId, "hub")
        XCTAssertNil(try K.fetchTask(db, derived("b1")))
    }

    // MARK: - Real ViewModel path (Board Edit Save)

    @discardableResult
    private func waitUntil(timeout: TimeInterval = 30, _ p: () -> Bool) -> Bool {
        let deadline = Date().addingTimeInterval(timeout)
        while !p() && Date() < deadline { RunLoop.current.run(until: Date().addingTimeInterval(0.01)) }
        return p()
    }

    private func loadedVM(_ db: AppDatabase) -> BoardPlayViewModel {
        let vm = BoardPlayViewModel(boardId: "b1", userId: K.userId, database: db)
        vm.reload()
        _ = waitUntil { vm.board?.id == "b1" && !vm.allTasks.isEmpty }
        return vm
    }

    func test_boardEditSave_addAndReplace_placeTheStagedTask_andReloadShowsIt() throws {
        let db = try makeDb()
        try db.saveTask(K.task("old", maxCount: 5))
        try db.saveTask(K.task("hubA", sharedCounterId: "root"))
        try db.saveBoardTask(K.placement(id: "bt", boardId: "b1", taskId: "old", size: 3))
        let vm = loadedVM(db)
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))

        vm.handleEditReplace(cellKey: "0-0", taskId: "hubA")
        XCTAssertTrue(vm.handleEditSave())
        XCTAssertTrue(waitUntil { vm.editEvent?.outcome == .saved })

        let placed = try db.fetchBoardTasks(boardId: "b1")
        XCTAssertEqual(placed.count, 1)
        XCTAssertEqual(placed[0].taskId, "hubA", "the placed id IS the staged id (no mint)")
        XCTAssertTrue(waitUntil { vm.taskMap["hubA"] != nil })
        let rowCount = try db.read { try Task.filter(Column("sharedCounterId") == "root").fetchCount($0) }
        XCTAssertEqual(rowCount, 1, "only the library row — nothing minted")
    }

    /// Board Edit stages a pending LINKED row; Save persists it as-is (slice 3a).
    func test_boardEditSave_pendingLinkedRow_isPersistedAndPlacedAsIs() throws {
        let db = try makeDb()
        var rootTask = try XCTUnwrap(K.fetchTask(db, "root"))
        rootTask.maxCount = nil
        rootTask.isCounter = true
        try db.saveTask(rootTask)
        try db.saveTask(K.task("old", maxCount: 5))
        try db.saveBoardTask(K.placement(id: "bt", boardId: "b1", taskId: "old", size: 3))
        let vm = loadedVM(db)
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))

        let pending = PendingTaskPayload(
            task: K.task("pending-linked", maxCount: 5, sharedCounterId: "root", createdInWizard: true),
            childTasks: [], childLinks: []
        )
        vm.handleEditAdd(cellKey: "0-1", taskId: pending.task.id, pending: pending)
        XCTAssertTrue(vm.handleEditSave())
        XCTAssertTrue(waitUntil { vm.editEvent?.outcome == .saved })

        let placed = try db.fetchBoardTasks(boardId: "b1").map(\.taskId).sorted()
        XCTAssertEqual(placed, ["old", pending.task.id].sorted())
        XCTAssertEqual(try K.fetchTask(db, pending.task.id)?.maxCount, 5)
        XCTAssertEqual(try K.queue(db, type: "tasks", id: pending.task.id).first?.operationType, .create)
        XCTAssertNil(try K.fetchTask(db, derived("b1")), "no copy minted")
    }

    // MARK: - Picker parameters (slice 3b)

    /// A counter root added through the picker carries the picked goal.
    func test_boardEditSave_add_withPickerParams_writesTheOverride() throws {
        let db = try makeDb()
        try db.saveTask(K.task("old", maxCount: 5))
        try db.saveBoardTask(K.placement(id: "bt", boardId: "b1", taskId: "old", size: 3))
        let vm = loadedVM(db)
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))

        vm.handleEditAdd(
            cellKey: "1-1", taskId: "root",
            placement: PlacementParamsDraft(targetOverride: 6, targetKind: .discrete)
        )
        XCTAssertEqual(vm.editSquaresDraft["1-1"]?.placement?.targetOverride, 6, "staged in the draft")
        XCTAssertEqual(vm.editDraftTaskMap["root"]?.maxCount, 6, "the staged grid reads the placement goal")
        saveAndWait(vm)

        let placed = try XCTUnwrap(try db.fetchBoardTasks(boardId: "b1").first { $0.row == 1 && $0.col == 1 })
        XCTAssertEqual(placed.taskId, "root")
        XCTAssertEqual(placed.targetOverride, 6)
        XCTAssertEqual(try K.fetchTask(db, "root")?.maxCount, 100, "the library root keeps its goal")
    }

    func test_boardEditSave_replace_withPickerParams_setsTheOverride() throws {
        let db = try makeDb()
        try db.saveTask(K.task("old", maxCount: 5))
        try db.saveBoardTask(K.placement(id: "bt", boardId: "b1", taskId: "old", size: 3))
        let vm = loadedVM(db)
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))

        vm.handleEditReplace(
            cellKey: "0-0", taskId: "root",
            placement: PlacementParamsDraft(targetOverride: 8, targetKind: .discrete)
        )
        saveAndWait(vm)

        let placed = try XCTUnwrap(try db.fetchBoardTasks(boardId: "b1").first)
        XCTAssertEqual(placed.taskId, "root")
        XCTAssertEqual(placed.targetOverride, 8)
        XCTAssertEqual(placed.targetKind, .discrete)
    }

    // MARK: - Board Edit override remap (review Major)

    private let patch = SquareEditTaskSheet.Patch(
        title: "Renamed", type: .counting, action: "Cycle", unit: "km", maxCount: 12
    )

    private func saveAndWait(_ vm: BoardPlayViewModel) {
        XCTAssertTrue(vm.handleEditSave())
        XCTAssertTrue(waitUntil { vm.editEvent?.outcome == .saved })
    }

    /// A goal and a title are PLACEMENT parameters; an action / unit edit is a task edit.
    func test_boardEditSave_replaceWithLinked_override_splitsParametersFromTaskEdit() throws {
        let db = try makeDb()
        try db.saveTask(K.task("old", maxCount: 5))
        try db.saveTask(K.task("hubA", sharedCounterId: "root"))
        try db.saveBoardTask(K.placement(id: "bt", boardId: "b1", taskId: "old", size: 3))
        let vm = loadedVM(db)
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))

        vm.handleEditReplace(cellKey: "0-0", taskId: "hubA")
        vm.handleEditTaskOverride(taskId: "hubA", patch: patch)
        saveAndWait(vm)

        let placement = try XCTUnwrap(try db.fetchBoardTasks(boardId: "b1").first)
        XCTAssertEqual(placement.taskId, "hubA")
        XCTAssertEqual(placement.targetOverride, 12)
        XCTAssertEqual(placement.targetKind, .discrete)
        XCTAssertEqual(placement.titleOverride, "Renamed")
        let source = try XCTUnwrap(K.fetchTask(db, "hubA"))
        XCTAssertEqual(source.title, "hubA", "the library title stays")
        XCTAssertEqual(source.maxCount, 10, "the library goal stays")
        XCTAssertEqual(source.action, "Cycle", "an action edit is a task edit")
        XCTAssertEqual(source.unit, "km")
    }

    func test_boardEditSave_addLinked_goalOnly_writesOnlyThePlacement() throws {
        let db = try makeDb()
        try db.saveTask(K.task("old", maxCount: 5))
        try db.saveTask(K.task("hubB", sharedCounterId: "root"))
        try db.saveBoardTask(K.placement(id: "bt", boardId: "b1", taskId: "old", size: 3))
        let vm = loadedVM(db)
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))

        vm.handleEditAdd(cellKey: "1-1", taskId: "hubB")
        vm.handleEditTaskOverride(
            taskId: "hubB", patch: .init(title: "", type: .counting, action: "Run", unit: "miles", maxCount: 12)
        )
        saveAndWait(vm)

        let placed = try XCTUnwrap(try db.fetchBoardTasks(boardId: "b1").first { $0.row == 1 && $0.col == 1 })
        XCTAssertEqual(placed.taskId, "hubB")
        XCTAssertEqual(placed.targetOverride, 12)
        XCTAssertNil(placed.titleOverride, "an auto title is not frozen")
        let source = try XCTUnwrap(K.fetchTask(db, "hubB"))
        XCTAssertEqual(source.maxCount, 10)
        XCTAssertEqual(source.version, 1, "no task write at all")
    }

    func test_boardEditSave_plainTaskOverride_splitsToo() throws {
        let db = try makeDb()
        try db.saveTask(K.task("plain", maxCount: 5))
        try db.saveBoardTask(K.placement(id: "bt", boardId: "b1", taskId: "plain", size: 3))
        let vm = loadedVM(db)
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))

        vm.handleEditTaskOverride(taskId: "plain", patch: patch)
        saveAndWait(vm)

        let t = try XCTUnwrap(K.fetchTask(db, "plain"))
        XCTAssertEqual(t.title, "plain")
        XCTAssertEqual(t.maxCount, 5)
        XCTAssertEqual(t.action, "Cycle")
        XCTAssertEqual(t.unit, "km")
        let placement = try XCTUnwrap(try db.fetchBoardTasks(boardId: "b1").first)
        XCTAssertEqual(placement.taskId, "plain")
        XCTAssertEqual(placement.targetOverride, 12)
        XCTAssertEqual(placement.titleOverride, "Renamed")
    }
}
