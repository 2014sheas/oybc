import Foundation
import GRDB

/// Board Sources P2 (docs/BOARD_SOURCES.md §Boards as sources) — the
/// platform half of board-kind source resolution: fetch a pulled board's
/// raw supply (its live placed task ids) plus each member's done-state in
/// THAT board's window, so the wizard can render member rows ("done" ✓),
/// subtitles ("6 squares · 4 done"), and build the algorithm's
/// `BoardSources.Supply` with the `'todo'` filter applied.
///
/// Done-state predicate mirrors `BoardPlayViewModel.windowedIsCompleted`:
/// event-owning primitives resolve via `resolveTaskWindowState` against
/// the source board's window (`board.startDate`); compound / achievement /
/// derived counting read the lifetime `Task.isCompleted` cache (the same
/// documented carve-out the Board-Edit preview surfaces use — these
/// wizard surfaces have no compound/achievement evaluation context of
/// their own).
struct BoardSourceSupplyInfo: Equatable {
    /// The source board's display name (for the row title).
    let displayName: String
    /// Deduped, placement-ordered, non-deleted placed task ids — the RAW
    /// supply (before excludes/filter).
    let supplyTaskIds: [String]
    /// The subset of `supplyTaskIds` complete in the board's window.
    let doneTaskIds: Set<String>
}

extension AppDatabase {
    /// Resolve one board's source supply. Returns nil when the board is
    /// missing or soft-deleted (an unresolvable source supplies nothing —
    /// the caller renders/contributes an empty supply, never blocks).
    func fetchBoardSourceSupply(boardId: String) throws -> BoardSourceSupplyInfo? {
        try read { db in
            guard let board = try Board.fetchOne(db, key: boardId), !board.isDeleted else {
                return nil
            }
            let rows = try BoardTask
                .filter(Column("boardId") == boardId && Column("isDeleted") == false)
                .fetchAll(db)
                .sorted { ($0.row, $0.col) < ($1.row, $1.col) }

            var seen = Set<String>()
            var supply: [String] = []
            var done = Set<String>()
            for bt in rows {
                guard let task = try Task.fetchOne(db, key: bt.taskId), !task.isDeleted else {
                    continue
                }
                if seen.contains(task.id) { continue }
                seen.insert(task.id)
                supply.append(task.id)

                let isDone: Bool
                if isEventOwningTask(task) {
                    let events = try TaskEvent
                        .filter(Column("taskId") == task.id && Column("isDeleted") == false)
                        .fetchAll(db)
                    isDone = resolveTaskWindowState(
                        task: task, events: events, windowStart: board.startDate
                    ).isCompleted
                } else {
                    isDone = task.isCompleted
                }
                if isDone { done.insert(task.id) }
            }
            return BoardSourceSupplyInfo(
                displayName: board.name,
                supplyTaskIds: supply,
                doneTaskIds: done
            )
        }
    }
}
