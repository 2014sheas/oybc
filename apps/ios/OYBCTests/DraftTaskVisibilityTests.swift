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

    func testWizardOrphanTaskNoLivePlacement_isVisible() {
        // Its only placement points at a board absent from the status map
        // (deleted) → treated as no live placement → visible (orphan).
        let tasks = [task("a", createdInWizard: true)]
        let placements = [placement("a", on: "deletedBoard")]
        let statuses: [String: BoardStatus] = [:] // deletedBoard not present

        let result = TaskLibraryViewModel.computeBrowsableTasks(
            tasks: tasks, boardTasks: placements, boardStatusById: statuses
        )
        XCTAssertEqual(ids(result), ["a"])
    }

    func testWizardTaskWithNoPlacements_isVisible() {
        let tasks = [task("a", createdInWizard: true)]
        let result = TaskLibraryViewModel.computeBrowsableTasks(
            tasks: tasks, boardTasks: [], boardStatusById: [:]
        )
        XCTAssertEqual(ids(result), ["a"])
    }

    func testMixedSet_onlyDraftOnlyWizardTasksHidden() {
        let tasks = [
            task("standalone", createdInWizard: false),   // visible
            task("wizDraft", createdInWizard: true),       // hidden (only on draft)
            task("wizActive", createdInWizard: true),      // visible (on active)
            task("wizOrphan", createdInWizard: true),      // visible (no placement)
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
        XCTAssertEqual(ids(result), ["standalone", "wizActive", "wizOrphan"])
    }
}
