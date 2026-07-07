import XCTest
@testable import OYBC

/// Unit tests for `BrowsableTasks.computeBrowsableTasks` — the draft-board
/// library-visibility rule, called directly against the extracted helper
/// (issue #246 part 2).
///
/// Parity target: `packages/shared/tests/algorithms/browsableTasks.test.ts`.
/// `DraftTaskVisibilityTests` already exercises the same rule through the
/// `TaskLibraryViewModel.computeBrowsableTasks` forwarding wrapper (kept
/// green as the pre-existing regression gate); this file mirrors the TS
/// suite's case list directly against the new named helper.
final class BrowsableTasksTests: XCTestCase {

    // MARK: - Fixtures

    private func task(_ id: String, createdInWizard: Bool) -> Task {
        Task(
            id: id,
            userId: "u1",
            title: "Task \(id)",
            type: .normal,
            totalCompletions: 0,
            totalInstances: 0,
            createdAt: "2026-07-01T12:00:00.000Z",
            updatedAt: "2026-07-01T12:00:00.000Z",
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
            createdAt: "2026-07-01T12:00:00.000Z",
            updatedAt: "2026-07-01T12:00:00.000Z",
            version: 1
        )
    }

    private func ids(_ tasks: [Task]) -> Set<String> { Set(tasks.map { $0.id }) }

    // MARK: - Tests (mirrors browsableTasks.test.ts case-for-case)

    func test_standaloneTask_alwaysVisible_evenOnlyOnDraft() {
        let result = BrowsableTasks.computeBrowsableTasks(
            tasks: [task("a", createdInWizard: false)],
            boardTasks: [placement("a", on: "draftBoard")],
            boardStatusById: ["draftBoard": .draft]
        )
        XCTAssertEqual(ids(result), ["a"])
    }

    func test_wizardTaskOnlyOnDraftBoard_isHidden() {
        let result = BrowsableTasks.computeBrowsableTasks(
            tasks: [task("a", createdInWizard: true)],
            boardTasks: [placement("a", on: "draftBoard")],
            boardStatusById: ["draftBoard": .draft]
        )
        XCTAssertTrue(result.isEmpty)
    }

    func test_wizardTaskOnActiveBoard_isVisible() {
        let result = BrowsableTasks.computeBrowsableTasks(
            tasks: [task("a", createdInWizard: true)],
            boardTasks: [placement("a", on: "activeBoard")],
            boardStatusById: ["activeBoard": .active]
        )
        XCTAssertEqual(ids(result), ["a"])
    }

    func test_wizardTaskOnBothDraftAndActive_isVisible() {
        let result = BrowsableTasks.computeBrowsableTasks(
            tasks: [task("a", createdInWizard: true)],
            boardTasks: [placement("a", on: "draftBoard"), placement("a", on: "activeBoard")],
            boardStatusById: ["draftBoard": .draft, "activeBoard": .active]
        )
        XCTAssertEqual(ids(result), ["a"])
    }

    func test_wizardTaskOnCompletedBoard_isVisible() {
        let result = BrowsableTasks.computeBrowsableTasks(
            tasks: [task("a", createdInWizard: true)],
            boardTasks: [placement("a", on: "doneBoard")],
            boardStatusById: ["doneBoard": .completed]
        )
        XCTAssertEqual(ids(result), ["a"])
    }

    func test_wizardOrphan_onlyBoardDeleted_isHidden() {
        let result = BrowsableTasks.computeBrowsableTasks(
            tasks: [task("a", createdInWizard: true)],
            boardTasks: [placement("a", on: "deletedBoard")],
            boardStatusById: [:]
        )
        XCTAssertTrue(result.isEmpty)
    }

    func test_wizardTaskWithNoPlacementsAtAll_isHidden() {
        let result = BrowsableTasks.computeBrowsableTasks(
            tasks: [task("a", createdInWizard: true)],
            boardTasks: [],
            boardStatusById: [:]
        )
        XCTAssertTrue(result.isEmpty)
    }

    func test_mixedSet_onlyDraftOnlyAndOrphanWizardTasksHide() {
        let tasks = [
            task("standalone", createdInWizard: false),
            task("wizDraft", createdInWizard: true),
            task("wizActive", createdInWizard: true),
            task("wizOrphan", createdInWizard: true),
        ]
        let placements = [
            placement("standalone", on: "draftBoard"),
            placement("wizDraft", on: "draftBoard"),
            placement("wizActive", on: "activeBoard"),
        ]
        let result = BrowsableTasks.computeBrowsableTasks(
            tasks: tasks,
            boardTasks: placements,
            boardStatusById: ["draftBoard": .draft, "activeBoard": .active]
        )
        XCTAssertEqual(ids(result), ["standalone", "wizActive"])
    }

    func test_wizardCompoundChild_inheritsActiveParent_isVisible() {
        let tasks = [task("parent", createdInWizard: true), task("child", createdInWizard: true)]
        let result = BrowsableTasks.computeBrowsableTasks(
            tasks: tasks,
            boardTasks: [placement("parent", on: "activeBoard")],
            boardStatusById: ["activeBoard": .active],
            childToParents: ["child": ["parent"]]
        )
        XCTAssertEqual(ids(result), ["parent", "child"])
    }

    func test_wizardCompoundChild_draftOnlyParent_isHidden() {
        let tasks = [task("parent", createdInWizard: true), task("child", createdInWizard: true)]
        let result = BrowsableTasks.computeBrowsableTasks(
            tasks: tasks,
            boardTasks: [placement("parent", on: "draftBoard")],
            boardStatusById: ["draftBoard": .draft],
            childToParents: ["child": ["parent"]]
        )
        XCTAssertTrue(result.isEmpty)
    }

    func test_wizardCompoundChild_noParentPlacement_isHidden() {
        let tasks = [task("parent", createdInWizard: true), task("child", createdInWizard: true)]
        let result = BrowsableTasks.computeBrowsableTasks(
            tasks: tasks,
            boardTasks: [],
            boardStatusById: [:],
            childToParents: ["child": ["parent"]]
        )
        XCTAssertTrue(result.isEmpty)
    }
}
