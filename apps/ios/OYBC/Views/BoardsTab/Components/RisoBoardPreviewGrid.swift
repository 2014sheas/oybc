import GRDB
import SwiftUI

/// Self-loading wrapper around `RisoMiniGrid`: given just a `Board`, fetches
/// its real placements/tasks/compound-children/events (+ workspace boards for
/// ACHIEVEMENT cross-board references) and builds the TRUE preview grid via
/// `BoardPreviewCells.build` — the same derivation `BoardPlayView`'s
/// `risoPlaySquare` uses for the live play grid.
///
/// Used by `RisoBoardCard` (when its own `previewCells` prop is `nil`) and by
/// `FromBoardPickerView`'s source-board rows, so both surfaces show the real
/// board instead of a count-based approximation. A one-shot GRDB fetch on
/// appear, mirroring `LinkedCounterCaptionView`'s pattern — this keeps
/// `RisoMiniGrid` itself a pure, DB-free, snapshot-safe leaf view.
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
            let allTasks = (try? database.fetchTasks(userId: board.userId)) ?? []
            let allCompoundChildren = (try? database.fetchAllCompoundChildren()) ?? []
            let allBoardsInWorkspace = (try? database.fetchBoards(userId: board.userId)) ?? []
            let events = (try? database.fetchNonDeletedTaskEvents(userId: board.userId)) ?? []

            var taskMap: [String: Task] = [:]
            for t in allTasks { taskMap[t.id] = t }

            var childrenByCompound: [String: [CompoundChild]] = [:]
            for c in allCompoundChildren where !c.isDeleted {
                childrenByCompound[c.compoundTaskId, default: []].append(c)
            }

            var eventsByTaskId: [String: [TaskEvent]] = [:]
            for e in events { eventsByTaskId[e.taskId, default: []].append(e) }

            let result = BoardPreviewCells.build(
                board: board,
                boardTasks: boardTasks,
                taskMap: taskMap,
                childrenByCompound: childrenByCompound,
                eventsByTaskId: eventsByTaskId,
                allBoardsInWorkspace: allBoardsInWorkspace
            )

            await MainActor.run {
                self.loaded = result
            }
        }
    }
}
