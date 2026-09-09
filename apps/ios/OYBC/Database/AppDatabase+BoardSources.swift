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
    /// Series binding (loose-ends sweep 2026-09-09 — docs/BOARD_SOURCES.md
    /// §Boards as sources, now implemented as designed): resolve a STORED
    /// board-source id to the board that should supply squares right now.
    ///
    /// - A one-off board (no `spawnedFromTemplateId`) resolves to itself
    ///   while it is live, else nil.
    /// - A board that belongs to a recurring series binds to the SERIES:
    ///   the pull hops to the series' live instance — the one whose window
    ///   contains `reference` when it exists, else the newest live
    ///   instance whose window has started, else the newest live instance.
    ///   Old archived windows never kill the pull; only a series with NO
    ///   live instance (or a gone one-off) resolves nil — which the spawn
    ///   maps to the `source_board_missing` ask.
    ///
    /// Web twin: `resolveSourceBoard` (`db/operations/boardSources.ts`).
    static func resolveSourceBoard(
        db: Database,
        storedBoardId: String,
        reference: String
    ) throws -> Board? {
        func isLive(_ board: Board) -> Bool {
            !board.isDeleted && board.status != .archived
        }
        guard let stored = try Board.fetchOne(db, key: storedBoardId) else { return nil }
        guard let seriesId = stored.spawnedFromTemplateId else {
            return isLive(stored) ? stored : nil
        }
        let instances = try Board
            .filter(Column("spawnedFromTemplateId") == seriesId)
            .fetchAll(db)
            .filter(isLive)
        guard !instances.isEmpty else { return nil }
        let containing = instances.filter { b in
            b.startDate <= reference && (b.endDate == nil || reference <= b.endDate!)
        }
        if let hit = containing.max(by: { $0.startDate < $1.startDate }) { return hit }
        let started = instances.filter { $0.startDate <= reference }
        let pool = started.isEmpty ? instances : started
        return pool.max(by: { $0.startDate < $1.startDate })
    }

    /// Resolve one board's source supply. Series-binding aware: the stored
    /// id hops to the series' live instance (see `resolveSourceBoard`).
    /// Returns nil when nothing live resolves (an unresolvable source
    /// supplies nothing — the caller renders/contributes an empty supply,
    /// never blocks).
    func fetchBoardSourceSupply(
        boardId: String,
        reference: String = AppDatabase.currentTimestamp()
    ) throws -> BoardSourceSupplyInfo? {
        try read { db in
            guard let board = try Self.resolveSourceBoard(
                db: db, storedBoardId: boardId, reference: reference
            ) else {
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
    /// Internal (not private) — the spawn path resolves board-kind source
    /// supplies through this same predicate inside its own transaction.
    static func resolveSupply(
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

extension AppDatabase {
    /// Computes the spawn-provenance note text for a freshly-spawned
    /// board (loose-ends sweep 2026-09-09) — sources-native: board-kind
    /// supplies resolve through the series-binding-aware reader with the
    /// record's 'todo' filter, and "of M" is the honest achievable pool
    /// size. Runs DB reads — call off-main.
    func spawnProvenanceNote(
        template: RecurringBoardTemplate,
        poolsById: [String: Pool],
        tasksById: [String: Task],
        dealtTaskIds: [String]
    ) -> String {
        let sources = BoardSources.sourcesForRecord(
            sources: template.sources,
            poolIds: template.poolIds,
            removedTaskIds: template.removedTaskIds
        )
        var supplies: [BoardSources.Supply] = []
        for source in sources {
            switch source.kind {
            case .pool:
                supplies.append(BoardSources.Supply(
                    source: source,
                    supplyTaskIds: BoardSources.poolSourceSupplyById(
                        source.sourceId, poolsById: poolsById, tasksById: tasksById
                    )
                ))
            case .board:
                let info = (try? fetchBoardSourceSupply(boardId: source.sourceId)) ?? nil
                var raw = info?.supplyTaskIds ?? []
                if source.filter == .todo, let done = info?.doneTaskIds {
                    raw.removeAll { done.contains($0) }
                }
                supplies.append(BoardSources.Supply(source: source, supplyTaskIds: raw))
            }
        }
        let summary = PoolMix.summarizeSpawnProvenance(
            supplies: supplies,
            manualTaskIds: template.manualTaskIds ?? [],
            counterFamilyByTaskId: BoardSources.buildCounterFamilyMap(tasksById.values),
            dealtTaskIds: dealtTaskIds
        )
        return PoolMix.formatSpawnProvenanceNote(summary)
    }
}
