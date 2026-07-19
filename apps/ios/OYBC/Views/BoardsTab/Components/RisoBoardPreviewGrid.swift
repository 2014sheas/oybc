import GRDB
import SwiftUI

/// Self-loading wrapper around `RisoMiniGrid`: given just a `Board`, fetches
/// its real placements + `BoardPreviewCells.WorkspaceData` (tasks/compound-
/// children/events/workspace boards) and builds the TRUE preview grid via
/// `BoardPreviewCells.build` — the same derivation `BoardPlayView`'s
/// `risoPlaySquare` uses for the live play grid.
///
/// **Single-card use only.** This mounts its own workspace-scoped reads
/// (all tasks, all compound children, all events) on `.onAppear` — correct
/// for one card at a time, but mounting it per-row in a list means N cards
/// re-run those full reads N times (the exact perf bug this type's `build`
/// helper was introduced to fix data-*correctness* for, then regressed on
/// perf when first wired up naively). Its only remaining caller is
/// `CoreBoardWindowCellView` (one board per pager screen). Any list surface
/// — `BoardListView`, `FromBoardPickerView` — MUST hoist: fetch
/// `BoardPreviewCells.fetchWorkspaceData(userId:)` ONCE at the list-owning
/// view/view-model, batch-build via `BoardPreviewCells.buildMany(...)`, and
/// pass the per-board result down (`RisoBoardCard.previewCells` /
/// `RisoMiniGrid.cells` directly) instead of using this wrapper.
///
/// A one-shot GRDB fetch on appear, mirroring `LinkedCounterCaptionView`'s
/// pattern — this keeps `RisoMiniGrid` itself a pure, DB-free, snapshot-safe
/// leaf view.
///
/// While the fetch is in flight (milliseconds, local-only) this renders an
/// all-empty `gridSize × gridSize` grid rather than blocking.
struct RisoBoardPreviewGrid: View {

    let board: Board
    var size: CGFloat = 46

    @State private var loaded: BoardPreviewCellsResult?

    private var resolved: BoardPreviewCellsResult {
        loaded ?? BoardPreviewCellsResult(
            size: board.boardSize,
            cells: Array(repeating: .empty, count: board.boardSize * board.boardSize)
        )
    }

    var body: some View {
        RisoMiniGrid(gridSize: resolved.size, cells: resolved.cells, size: size)
            .onAppear { load() }
    }

    private func load() {
        let board = self.board
        _Concurrency.Task.detached(priority: .userInitiated) {
            let database = AppDatabase.shared
            let boardTasks = (try? database.fetchBoardTasks(boardId: board.id)) ?? []
            let workspace = BoardPreviewCells.fetchWorkspaceData(userId: board.userId, database: database)

            let result = BoardPreviewCells.build(
                board: board,
                boardTasks: boardTasks,
                taskMap: workspace.taskMap,
                childrenByCompound: workspace.childrenByCompound,
                eventsByTaskId: workspace.eventsByTaskId,
                allBoardsInWorkspace: workspace.allBoardsInWorkspace
            )

            await MainActor.run {
                self.loaded = result
            }
        }
    }
}
