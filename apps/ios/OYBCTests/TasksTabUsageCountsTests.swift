import XCTest
@testable import OYBC

/// The Tasks tab's "N active" hint / "On active boards" filter count boards
/// still in play (`activeBoardIds`, `isBoardActiveForList`), not every board
/// whose stored status is `.active`. Web twin: `activeBoardPlacementCounts`
/// in `useTasksFilters`.
@MainActor
final class TasksTabUsageCountsTests: XCTestCase {

    private func placement(_ task: String, _ board: String) -> BoardTask {
        BoardTask(
            id: "\(task)-\(board)", boardId: board, taskId: task, row: 0, col: 0,
            isCenter: false, createdAt: "", updatedAt: "", lastSyncedAt: nil, version: 1
        )
    }

    func testActivePlacementCounts_countOnlyInPlayBoards() throws {
        let vm = TasksTabViewModel(database: try AppDatabase.makeTestInstance())
        // Every board is stored `.active`; only two are still in play.
        vm.boardStatusById = ["a1": .active, "a2": .active, "ended": .active, "closed": .active]
        vm.activeBoardIds = ["a1", "a2"]
        let counts = vm.activePlacementCounts(boardTasks: [
            placement("t", "a1"), placement("t", "a1"), placement("t", "a2"),
            placement("t", "ended"), placement("t", "closed"),
            placement("u", "ended"),
        ])
        XCTAssertEqual(counts, ["t": 2])
        XCTAssertEqual(vm.placementCounts(boardTasks: [placement("u", "ended")]), ["u": 1])
    }
}
