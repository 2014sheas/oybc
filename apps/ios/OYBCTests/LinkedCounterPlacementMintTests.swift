import XCTest
import GRDB
@testable import OYBC

/// Windowed linked counters — the placement choke points
/// (`addBoardTaskToBoard` / `updateBoardTaskAndCascade`) mint the board's own
/// window-stamped row for a hub-linked task, so Board Edit's add / replace
/// square is window-safe. The ViewModel tests drive the REAL Board Edit Save.
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

    func test_add_hubLinkedTask_placesDeterministicRow() throws {
        let db = try makeDb()
        try db.saveTask(K.task("hub", sharedCounterId: "root"))
        try K.addIncrement(db, taskId: "root", delta: 4, occurredAt: "2026-08-15T00:00:00.000Z")

        let bt = try db.addBoardTaskToBoard("b1", taskId: "hub", position: (row: 0, col: 0))
        XCTAssertEqual(bt.taskId, derived("b1"))
        let row = try XCTUnwrap(K.fetchTask(db, derived("b1")))
        XCTAssertTrue(BoardSources.isWindowStampedForBoard(row, board: try XCTUnwrap(db.fetchBoard(id: "b1"))))
        XCTAssertEqual(row.baseline, 4)
        XCTAssertEqual(row.maxCount, 10)
        XCTAssertEqual(try K.queue(db, type: "tasks", id: derived("b1")).first?.operationType, .create)
        XCTAssertEqual(try K.fetchTask(db, "hub")?.version, 1, "the library row is untouched")
    }

    func test_add_continuousHubLinkedTask_copyKeepsKindAndFractionalGoal() throws {
        let db = try makeDb()
        var hub = K.task("hub", maxCount: 2.5, sharedCounterId: "root")
        hub.countKind = .continuous
        try db.saveTask(hub)

        _ = try db.addBoardTaskToBoard("b1", taskId: "hub", position: (row: 0, col: 0))
        let row = try XCTUnwrap(K.fetchTask(db, derived("b1")))
        XCTAssertEqual(row.countKind, .continuous)
        XCTAssertEqual(row.maxCount, 2.5)
    }

    func test_add_taskAlreadyStampedForThisBoard_isPlacedAsIs() throws {
        let db = try makeDb()
        try db.saveTask(K.task("mine", sharedCounterId: "root", startDate: septStart, endDate: septEnd, createdInWizard: true))
        let bt = try db.addBoardTaskToBoard("b1", taskId: "mine", position: (row: 0, col: 0))
        XCTAssertEqual(bt.taskId, "mine")
        XCTAssertNil(try K.fetchTask(db, derived("b1")))
    }

    func test_add_taskStampedForAnotherWindow_getsFreshCopy() throws {
        let db = try makeDb()
        try db.saveTask(K.task("aug", sharedCounterId: "root", startDate: augStart, endDate: augEnd, createdInWizard: true))
        let bt = try db.addBoardTaskToBoard("b1", taskId: "aug", position: (row: 0, col: 0))
        XCTAssertEqual(bt.taskId, derived("b1"))
        XCTAssertEqual(try K.fetchTask(db, derived("b1"))?.startDate, septStart)
        XCTAssertEqual(try K.fetchTask(db, "aug")?.startDate, augStart, "the other window's row is untouched")
    }

    func test_add_tombstonedDeterministicRow_isRestored_andPlainTaskUntouched() throws {
        let db = try makeDb()
        try db.saveTask(K.task("hub", sharedCounterId: "root"))
        var dead = K.task(derived("b1"), sharedCounterId: "root"); dead.isDeleted = true; dead.version = 3
        try db.saveTask(dead)
        let bt = try db.addBoardTaskToBoard("b1", taskId: "hub", position: (row: 0, col: 0))
        XCTAssertEqual(bt.taskId, derived("b1"))
        let revived = try XCTUnwrap(K.fetchTask(db, derived("b1")))
        XCTAssertFalse(revived.isDeleted); XCTAssertEqual(revived.version, 4)

        try db.saveTask(K.task("plain", maxCount: 5))
        XCTAssertEqual(try db.addBoardTaskToBoard("b1", taskId: "plain", position: (row: 0, col: 1)).taskId, "plain")
    }

    func test_replace_hubLinkedTask_repointsToDeterministicRow() throws {
        let db = try makeDb()
        try db.saveTask(K.task("old", maxCount: 5))
        try db.saveTask(K.task("hub", sharedCounterId: "root"))
        try db.saveBoardTask(K.placement(id: "bt", boardId: "b1", taskId: "old", size: 3))
        try db.updateBoardTaskAndCascade(boardTaskId: "bt", newTaskId: "hub")
        XCTAssertEqual(try db.fetchBoardTasks(boardId: "b1").first?.taskId, derived("b1"))
        XCTAssertNotNil(try K.fetchTask(db, derived("b1")))
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

    func test_boardEditSave_addAndReplace_placeWindowStampedRows_andReloadShowsThem() throws {
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
        XCTAssertEqual(placed[0].taskId, derived("b1"), "the placed id differs from the staged id")
        XCTAssertTrue(waitUntil { vm.allTasks.contains { $0.id == self.derived("b1") } || vm.taskMap[self.derived("b1")] != nil })
        XCTAssertNotNil(vm.taskMap[derived("b1")], "reload resolves the placed (minted) row")

        // Exactly one minted row exists beside the library row.
        let rowCount = try db.read { try Task.filter(Column("sharedCounterId") == "root").fetchCount($0) }
        XCTAssertEqual(rowCount, 2, "hubA + exactly one minted row")
    }

    /// Board Edit's picker: a goal-less counter picked through the no-default
    /// Goal entry stages a pending LINKED row; Save places the board's own
    /// copy and never writes the pending row (no orphan member, no sync item).
    func test_boardEditSave_replacedLinkedPendingRow_isNeverPersistedOrEnqueued() throws {
        let db = try makeDb()
        var rootTask = try XCTUnwrap(K.fetchTask(db, "root"))
        rootTask.maxCount = nil
        rootTask.isCounter = true
        try db.saveTask(rootTask)
        try db.saveTask(K.task("old", maxCount: 5))
        try db.saveBoardTask(K.placement(id: "bt", boardId: "b1", taskId: "old", size: 3))
        let vm = loadedVM(db)
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))

        let pending = QuickAddCounterPlacement.pendingLinkedTask(
            root: rootTask, goal: 5, userId: K.userId, now: septStart
        )
        vm.handleEditAdd(cellKey: "0-1", taskId: pending.task.id, pending: pending)
        XCTAssertTrue(vm.handleEditSave())
        XCTAssertTrue(waitUntil { vm.editEvent?.outcome == .saved })

        let placed = try db.fetchBoardTasks(boardId: "b1").map(\.taskId).sorted()
        XCTAssertEqual(placed, ["old", derived("b1")].sorted())
        XCTAssertEqual(try K.fetchTask(db, derived("b1"))?.maxCount, 5)
        XCTAssertNil(try K.fetchTask(db, pending.task.id), "the replaced pending row is not written")
        XCTAssertTrue(try K.queue(db, type: "tasks", id: pending.task.id).isEmpty, "…and not enqueued")
        let linked = try db.read { try Task.filter(Column("sharedCounterId") == "root").fetchAll($0).map(\.id) }
        XCTAssertEqual(linked, [derived("b1")], "exactly one row links to the root — no ghost member")
    }

    // MARK: - Board Edit override remap (review Major)

    private let patch = SquareEditTaskSheet.Patch(
        title: "Renamed", type: .counting, action: "Cycle", unit: "km", maxCount: 12
    )

    private func saveAndWait(_ vm: BoardPlayViewModel) {
        XCTAssertTrue(vm.handleEditSave())
        XCTAssertTrue(waitUntil { vm.editEvent?.outcome == .saved })
    }

    func test_boardEditSave_replaceWithLinked_override_patchesCopy_notLibrarySource() throws {
        let db = try makeDb()
        try db.saveTask(K.task("old", maxCount: 5))
        try db.saveTask(K.task("hubA", sharedCounterId: "root"))
        try db.saveBoardTask(K.placement(id: "bt", boardId: "b1", taskId: "old", size: 3))
        let vm = loadedVM(db)
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))

        vm.handleEditReplace(cellKey: "0-0", taskId: "hubA")
        vm.handleEditTaskOverride(taskId: "hubA", patch: patch)
        saveAndWait(vm)

        let copy = try XCTUnwrap(K.fetchTask(db, derived("b1")))
        XCTAssertEqual(try db.fetchBoardTasks(boardId: "b1").first?.taskId, derived("b1"))
        XCTAssertEqual(copy.title, "Renamed")
        XCTAssertEqual(copy.maxCount, 12)
        XCTAssertEqual(copy.unit, "km")
        let source = try XCTUnwrap(K.fetchTask(db, "hubA"))
        XCTAssertEqual(source.title, "hubA", "the library source is not patched")
        XCTAssertEqual(source.version, 1)
        XCTAssertEqual(source.maxCount, 10)
    }

    func test_boardEditSave_addLinked_override_patchesCopy_notLibrarySource() throws {
        let db = try makeDb()
        try db.saveTask(K.task("old", maxCount: 5))
        try db.saveTask(K.task("hubB", sharedCounterId: "root"))
        try db.saveBoardTask(K.placement(id: "bt", boardId: "b1", taskId: "old", size: 3))
        let vm = loadedVM(db)
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))

        vm.handleEditAdd(cellKey: "1-1", taskId: "hubB")
        vm.handleEditTaskOverride(taskId: "hubB", patch: patch)
        saveAndWait(vm)

        let placed = try db.fetchBoardTasks(boardId: "b1").first { $0.row == 1 && $0.col == 1 }
        XCTAssertEqual(placed?.taskId, derived("b1"))
        let copy = try XCTUnwrap(K.fetchTask(db, derived("b1")))
        XCTAssertEqual(copy.title, "Renamed")
        XCTAssertEqual(copy.maxCount, 12)
        let source = try XCTUnwrap(K.fetchTask(db, "hubB"))
        XCTAssertEqual(source.title, "hubB")
        XCTAssertEqual(source.version, 1)
    }

    func test_boardEditSave_plainTaskOverride_stillPatchesTheTask() throws {
        let db = try makeDb()
        try db.saveTask(K.task("plain", maxCount: 5))
        try db.saveBoardTask(K.placement(id: "bt", boardId: "b1", taskId: "plain", size: 3))
        let vm = loadedVM(db)
        vm.seedEditDraft(from: try XCTUnwrap(vm.board))

        vm.handleEditTaskOverride(taskId: "plain", patch: patch)
        saveAndWait(vm)

        let t = try XCTUnwrap(K.fetchTask(db, "plain"))
        XCTAssertEqual(t.title, "Renamed")
        XCTAssertEqual(t.maxCount, 12)
        XCTAssertEqual(try db.fetchBoardTasks(boardId: "b1").first?.taskId, "plain")
    }
}
