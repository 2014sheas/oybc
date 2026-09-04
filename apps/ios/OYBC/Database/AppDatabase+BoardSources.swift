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
            return try Self.resolveSupply(db: db, board: board)
        }
    }

    /// Rows for the "Add a pool or board" sheet's BOARDS section: ACTIVE,
    /// non-deleted boards, each with squares/done counts from the same
    /// predicate the member rows use. One read transaction, batched
    /// queries per board (never per-row) — call sites still dispatch this
    /// off the main thread (it walks every active board).
    func fetchSourceSheetBoardEntries(
        userId: String
    ) throws -> [(board: Board, info: BoardSourceSupplyInfo)] {
        try read { db in
            let boards = try Board
                .filter(
                    Column("userId") == userId
                        && Column("status") == BoardStatus.active.rawValue
                        && Column("isDeleted") == false
                )
                .order(Column("updatedAt").desc)
                .fetchAll(db)
            return try boards.map { board in
                (board, try Self.resolveSupply(db: db, board: board))
            }
        }
    }

    /// Shared batched resolution: three queries per board (placements,
    /// tasks, events) instead of per-row fetches (review finding 2).
    private static func resolveSupply(
        db: Database,
        board: Board
    ) throws -> BoardSourceSupplyInfo {
        let rows = try BoardTask
            .filter(Column("boardId") == board.id && Column("isDeleted") == false)
            .fetchAll(db)
            .sorted { ($0.row, $0.col) < ($1.row, $1.col) }
        let placedIds = rows.map { $0.taskId }
        guard !placedIds.isEmpty else {
            return BoardSourceSupplyInfo(
                displayName: board.name, supplyTaskIds: [], doneTaskIds: []
            )
        }

        let tasks = try Task
            .filter(placedIds.contains(Column("id")) && Column("isDeleted") == false)
            .fetchAll(db)
        let taskById = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })

        let eventOwningIds = tasks.filter { isEventOwningTask($0) }.map { $0.id }
        var eventsByTaskId: [String: [TaskEvent]] = [:]
        if !eventOwningIds.isEmpty {
            let events = try TaskEvent
                .filter(eventOwningIds.contains(Column("taskId")) && Column("isDeleted") == false)
                .fetchAll(db)
            for e in events { eventsByTaskId[e.taskId, default: []].append(e) }
        }

        var seen = Set<String>()
        var supply: [String] = []
        var done = Set<String>()
        for id in placedIds {
            guard let task = taskById[id], !seen.contains(id) else { continue }
            seen.insert(id)
            supply.append(id)
            let isDone: Bool
            if isEventOwningTask(task) {
                isDone = resolveTaskWindowState(
                    task: task,
                    events: eventsByTaskId[id] ?? [],
                    windowStart: board.startDate
                ).isCompleted
            } else {
                isDone = task.isCompleted
            }
            if isDone { done.insert(id) }
        }
        return BoardSourceSupplyInfo(
            displayName: board.name,
            supplyTaskIds: supply,
            doneTaskIds: done
        )
    }
}
