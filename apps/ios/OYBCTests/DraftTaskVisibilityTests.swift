import XCTest
@testable import OYBC

/// Unit tests for `TaskLibraryViewModel.computeBrowsableTasks` — the
/// draft-board task-visibility predicate (bugfix/draft-board-task-leakage).
///
/// Rule under test: a task is hidden from library-browse surfaces iff it is
/// wizard-born (`createdInWizard == true`) AND it has at least one placement
/// on a live (non-deleted) board but NONE of those placements are on a
/// non-draft board — i.e. it lives only on drafts. Everything else is visible:
/// standalone/copied tasks, orphan wizard tasks (no live placement), and any
/// task with at least one active/completed placement.
final class DraftTaskVisibilityTests: XCTestCase {

    // MARK: - Fixtures

    private func task(_ id: String, createdInWizard: Bool) -> Task {
        Task(
            id: id,
            userId: "u1",
            title: "Task \(id)",
            type: .normal,
            totalCompletions: 0,
            totalInstances: 0,
            createdAt: "2026-06-22T12:00:00.000",
            updatedAt: "2026-06-22T12:00:00.000",
            version: 1,
            isDeleted: false,
            createdInWizard: createdInWizard
        )
    }

    private func placement(_ taskId: String, on boardId: String) -> BoardTask {
        BoardTask(
            id: "bt-\(taskId)-\(boardId)",
            boardId: boardId,
            taskId: taskId,
            row: 0,
            col: 0,
            isCenter: false,
            createdAt: "2026-06-22T12:00:00.000",
            updatedAt: "2026-06-22T12:00:00.000",
            version: 1
        )
    }

    private func ids(_ tasks: [Task]) -> Set<String> { Set(tasks.map { $0.id }) }

    // MARK: - Tests

    func testStandaloneTaskAlwaysVisible_evenOnlyOnDraft() {
        let tasks = [task("a", createdInWizard: false)]
        let placements = [placement("a", on: "draftBoard")]
        let statuses: [String: BoardStatus] = ["draftBoard": .draft]

        let result = TaskLibraryViewModel.computeBrowsableTasks(
            tasks: tasks, boardTasks: placements, boardStatusById: statuses
        )
        // createdInWizard == false → never hidden, even though its only
        // placement is a draft board.
        XCTAssertEqual(ids(result), ["a"])
    }

    func testWizardTaskOnlyOnDraft_isHidden() {
        let tasks = [task("a", createdInWizard: true)]
        let placements = [placement("a", on: "draftBoard")]
        let statuses: [String: BoardStatus] = ["draftBoard": .draft]

        let result = TaskLibraryViewModel.computeBrowsableTasks(
            tasks: tasks, boardTasks: placements, boardStatusById: statuses
        )
        XCTAssertTrue(result.isEmpty, "Wizard task placed only on a draft board should be hidden")
    }

    func testWizardTaskOnActiveBoard_isVisible() {
        let tasks = [task("a", createdInWizard: true)]
        let placements = [placement("a", on: "activeBoard")]
        let statuses: [String: BoardStatus] = ["activeBoard": .active]

        let result = TaskLibraryViewModel.computeBrowsableTasks(
            tasks: tasks, boardTasks: placements, boardStatusById: statuses
        )
        XCTAssertEqual(ids(result), ["a"])
    }

    func testWizardTaskOnDraftAndActive_isVisible() {
        let tasks = [task("a", createdInWizard: true)]
        let placements = [placement("a", on: "draftBoard"), placement("a", on: "activeBoard")]
        let statuses: [String: BoardStatus] = ["draftBoard": .draft, "activeBoard": .active]

        let result = TaskLibraryViewModel.computeBrowsableTasks(
            tasks: tasks, boardTasks: placements, boardStatusById: statuses
        )
        // ≥1 non-draft placement → visible.
        XCTAssertEqual(ids(result), ["a"])
    }

    func testWizardTaskOnCompletedBoard_isVisible() {
        let tasks = [task("a", createdInWizard: true)]
        let placements = [placement("a", on: "doneBoard")]
        let statuses: [String: BoardStatus] = ["doneBoard": .completed]

        let result = TaskLibraryViewModel.computeBrowsableTasks(
            tasks: tasks, boardTasks: placements, boardStatusById: statuses
        )
        XCTAssertEqual(ids(result), ["a"])
    }

    func testWizardOrphanTaskNoLivePlacement_isHidden() {
        // Its only placement points at a board absent from the status map
        // (deleted) → no live placement → an orphan. A wizard-born task with
        // no live placement is deleted/abandoned, so it's HIDDEN (was the leak
        // that showed deleted-in-wizard tasks in the library).
        let tasks = [task("a", createdInWizard: true)]
        let placements = [placement("a", on: "deletedBoard")]
        let statuses: [String: BoardStatus] = [:] // deletedBoard not present

        let result = TaskLibraryViewModel.computeBrowsableTasks(
            tasks: tasks, boardTasks: placements, boardStatusById: statuses
        )
        XCTAssertTrue(result.isEmpty, "Wizard-born orphan (no live placement) should be hidden")
    }

    func testWizardTaskWithNoPlacements_isHidden() {
        // A wizard-born task with zero placements = created in the wizard then
        // removed from the pool (its Task row lingers) → hidden.
        let tasks = [task("a", createdInWizard: true)]
        let result = TaskLibraryViewModel.computeBrowsableTasks(
            tasks: tasks, boardTasks: [], boardStatusById: [:]
        )
        XCTAssertTrue(result.isEmpty, "Wizard-born task with no placements should be hidden")
    }

    func testMixedSet_onlyDraftOnlyWizardTasksHidden() {
        let tasks = [
            task("standalone", createdInWizard: false),   // visible
            task("wizDraft", createdInWizard: true),       // hidden (only on draft)
            task("wizActive", createdInWizard: true),      // visible (on active)
            task("wizOrphan", createdInWizard: true),      // hidden (no placement — deleted/abandoned)
        ]
        let placements = [
            placement("standalone", on: "draftBoard"),
            placement("wizDraft", on: "draftBoard"),
            placement("wizActive", on: "activeBoard"),
        ]
        let statuses: [String: BoardStatus] = ["draftBoard": .draft, "activeBoard": .active]

        let result = TaskLibraryViewModel.computeBrowsableTasks(
            tasks: tasks, boardTasks: placements, boardStatusById: statuses
        )
        XCTAssertEqual(ids(result), ["standalone", "wizActive"])
    }

    // MARK: - pendingPayloadsToPersist (bugfix/ios-wizard-draft-leakage)
    //
    // A task removed from the wizard pool lingers in `pendingTasks` (removal
    // only updates the selection). Persisting it anyway created an orphan
    // `createdInWizard` Task row that leaked into the library and reappeared
    // on resume. persistWizardBoard now writes only placed pending tasks.

    private func payload(_ id: String) -> PendingTaskPayload {
        PendingTaskPayload(task: task(id, createdInWizard: true), childTasks: [], childLinks: [])
    }

    func testPendingPayloads_excludeUnplaced() {
        let pending = ["a": payload("a"), "b": payload("b")]
        // "b" was removed from the pool but still sits in pendingTasks.
        let result = pendingPayloadsToPersist(pending: pending, placedTaskIds: ["a"])
        XCTAssertEqual(Set(result.map { $0.task.id }), ["a"],
                       "A pending task not placed on the board must not be persisted (orphan-leak guard)")
    }

    func testPendingPayloads_keepAllPlaced() {
        let pending = ["a": payload("a"), "b": payload("b")]
        let result = pendingPayloadsToPersist(pending: pending, placedTaskIds: ["a", "b"])
        XCTAssertEqual(Set(result.map { $0.task.id }), ["a", "b"])
    }

    // MARK: - placementCounts board-count parity (bugfix/ios-wizard-draft-leakage)
    //
    // The pool over-counted vs the task-detail page: it counted every raw
    // board_task row (including rows on soft-deleted boards, and duplicate
    // rows on one board). It must count DISTINCT non-deleted boards to match
    // the detail page.

    func testPlacementCounts_distinctNonDeletedBoards() {
        let vm = TasksTabViewModel()
        // "deleted1" is absent from the status map → soft-deleted.
        vm.boardStatusById = ["active1": .active, "draft1": .draft]
        let bts = [
            placement("t", on: "active1"),
            placement("t", on: "active1"),   // duplicate row on the same board
            placement("t", on: "draft1"),
            placement("t", on: "deleted1"),  // soft-deleted board → excluded
        ]
        let counts = vm.placementCounts(boardTasks: bts)
        XCTAssertEqual(counts["t"], 2,
                       "Distinct non-deleted boards {active1, draft1}: deleted board excluded, duplicate row collapsed")
    }

    func testActivePlacementCounts_distinctActiveBoards() {
        let vm = TasksTabViewModel()
        vm.boardStatusById = ["active1": .active, "active2": .active, "draft1": .draft]
        let bts = [
            placement("t", on: "active1"),
            placement("t", on: "active1"),  // duplicate row on the same active board
            placement("t", on: "active2"),
            placement("t", on: "draft1"),   // draft → not counted as active
        ]
        let counts = vm.activePlacementCounts(boardTasks: bts)
        XCTAssertEqual(counts["t"], 2,
                       "Distinct ACTIVE boards {active1, active2}: duplicate row collapsed, draft excluded — matches the task-detail 'N active'")
    }
}
