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
/// the source board's window (`board.startDate`); window-stamped derived
/// counters resolve from their ROOT's events in their own window
/// (`resolveDerivedCounterWindowState`, the kernel rule); compound /
/// achievement / hub-linked derived counting read the lifetime
/// `Task.isCompleted` cache (the same documented carve-out the Board-Edit
/// preview surfaces use — these wizard surfaces have no
/// compound/achievement evaluation context of their own).
struct BoardSourceSupplyInfo: Equatable {
    /// The source board's display name (for the row title).
    let displayName: String
    /// Deduped, placement-ordered, non-deleted placed task ids — the RAW
    /// supply (before excludes/filter).
    let supplyTaskIds: [String]
    /// The subset of `supplyTaskIds` complete in the board's window.
    let doneTaskIds: Set<String>
    /// §Member rules (B3, RC4) — each event-owning COUNTING member's
    /// windowed count (Σ live increment deltas inside THIS board's window),
    /// the same number the source board's own squares display. Keyed by task
    /// id; a member with no entry has made no measurable progress here (or
    /// isn't an event-owning counter at all — compounds, achievements and
    /// derived counters get no entry; a window-stamped derived row's window
    /// count is deliberately NOT fed into this prefill map).
    ///
    /// Feeds the one-off wizard's "remaining" target prefill: pull a
    /// 3-of-10-done counter onto a fresh one-off board and its member rule is
    /// seeded with `remainingTarget(goal: 10, windowCount: 3) == 7`.
    let windowCountByTaskId: [String: Int]
    /// §Member rules (B3, RC5) — the source board's OWN window, so a caller
    /// can pro-rate an auto target (`effectiveMemberTarget`) without a second
    /// board read.
    let sourceWindow: BoardSources.BoardWindow
}

extension AppDatabase {
    /// How a STORED board-source id resolves now. Web twin:
    /// `SourceBoardResolution` (`db/operations/boardSources.ts`).
    enum SourceBoardResolution {
        /// `board` supplies squares.
        case live(Board)
        /// The source still exists but has no board open now (a series with
        /// no open instance, or a one-off board that has ended or been
        /// sealed). Supplies nothing; the UI
        /// shows "No board for this window yet". Carries the stored board's
        /// display name for the row title.
        case noWindow(displayName: String)
        /// The stored row is gone (missing, deleted, archived), or the series
        /// has no existing instance at all. Supplies nothing and maps to the
        /// spawn's `sourceBoardMissing` ask.
        case dead
    }

    /// One board source's supply for a window, keeping the `noWindow` /
    /// `dead` distinction the wizard row and the spawn note need. Web twin:
    /// `BoardSourceSupplyResolution`.
    enum BoardSourceSupplyResolution: Equatable {
        case live(BoardSourceSupplyInfo)
        case noWindow(displayName: String)
        case dead

        /// The supply when live, else nil.
        var info: BoardSourceSupplyInfo? {
            if case .live(let info) = self { return info }
            return nil
        }
    }

    /// The clock "has this source board ended" reads when a caller passes no
    /// explicit `now` (owner ruling 2026-09-24: ended boards are never
    /// sources). The wall clock in production; a TEST SEAM only — suites
    /// whose fixtures live on fixed calendar dates pin it in `setUp` and
    /// restore it in `tearDown` (the XCTest twin of web's
    /// `vi.setSystemTime`). Never assign it from app code.
    static var sourceClock: () -> Date = { Date() }

    /// True when a stored board row still EXISTS as a source — not deleted,
    /// not archived. Existence only: whether it can SUPPLY a window is the
    /// separate open-window rule (`BoardSources.isEligibleSourceBoard`), so
    /// an ended-but-existing source reads as `noWindow`, never `dead`.
    private static func isExistingSourceBoard(_ board: Board) -> Bool {
        !board.isDeleted && board.status != .archived
    }

    /// Series binding (docs/BOARD_SOURCES.md §Boards as sources) under the
    /// owner ruling of 2026-09-24 (amended) — SOURCES ARE OPEN BOARDS: resolve
    /// a STORED board-source id to the board that supplies squares now —
    /// exactly what the "Add from a pool or board" sheet would show.
    ///
    /// - A one-off board (no `spawnedFromTemplateId`) resolves to itself
    ///   while it is OPEN (`isEligibleSourceBoard` at `now`: not sealed,
    ///   window not ended); an ended/sealed one-off is `.noWindow`, a
    ///   deleted/archived one `.dead`.
    /// - A board in a recurring series binds to the SERIES: its instance OPEN
    ///   NOW (`pickOpenSeriesInstance` — started, not ended, not sealed;
    ///   latest start, then lowest id). None → `.noWindow` (never a fallback
    ///   to an ended or future instance); no existing instance → `.dead`. No
    ///   containment check against the new board's window: a monthly built
    ///   mid-month from a weekly series pulls the CURRENT week.
    ///
    /// The wizard's live supply, Preview, drafts-list capacity, persist and
    /// the recurring spawn all resolve through here with the same clock.
    /// Web twin: `resolveOpenSourceBoard` (`db/operations/boardSources.ts`).
    ///
    /// - Parameters:
    ///   - db: An open GRDB connection.
    ///   - storedBoardId: The id the source row stored at pull time.
    ///   - now: The instant "open" is judged against.
    /// - Returns: The resolution.
    /// - Throws: A GRDB read error.
    static func resolveOpenSourceBoard(
        db: Database,
        storedBoardId: String,
        now: Date = AppDatabase.sourceClock()
    ) throws -> SourceBoardResolution {
        guard let stored = try Board.fetchOne(db, key: storedBoardId) else { return .dead }
        guard let seriesId = stored.spawnedFromTemplateId else {
            guard isExistingSourceBoard(stored) else { return .dead }
            return BoardSources.isEligibleSourceBoard(stored, now: now)
                ? .live(stored)
                : .noWindow(displayName: stored.displayName)
        }
        let instances = try Board
            .filter(Column("spawnedFromTemplateId") == seriesId)
            .fetchAll(db)
            .filter(isExistingSourceBoard)
        guard !instances.isEmpty else { return .dead }
        if let hit = BoardSources.pickOpenSeriesInstance(instances, now: now) {
            return .live(hit)
        }
        return .noWindow(displayName: stored.displayName)
    }

    /// The board that supplies a stored source now, or nil when it resolves
    /// `.noWindow` or `.dead` — see
    /// ``resolveOpenSourceBoard(db:storedBoardId:now:)``, which callers that
    /// must tell the two apart use instead. Web twin: `resolveSourceBoard`.
    ///
    /// - Parameters:
    ///   - db: An open GRDB connection.
    ///   - storedBoardId: The id the source row stored at pull time.
    ///   - now: The instant "open" is judged against.
    /// - Returns: The live source board, or nil.
    /// - Throws: A GRDB read error.
    static func resolveSourceBoard(
        db: Database,
        storedBoardId: String,
        now: Date = AppDatabase.sourceClock()
    ) throws -> Board? {
        if case .live(let board) = try resolveOpenSourceBoard(
            db: db, storedBoardId: storedBoardId, now: now
        ) {
            return board
        }
        return nil
    }

    /// Resolve one board source's supply now, keeping the `.noWindow` /
    /// `.dead` distinction. Web twin: `fetchOpenBoardSourceSupply`.
    ///
    /// - Parameters:
    ///   - boardId: The stored source id.
    ///   - now: The instant "open" is judged against.
    /// - Returns: The supply, or why there is none.
    /// - Throws: A GRDB read error.
    func fetchOpenBoardSourceSupply(
        boardId: String,
        now: Date = AppDatabase.sourceClock()
    ) throws -> BoardSourceSupplyResolution {
        try read { db in
            switch try Self.resolveOpenSourceBoard(db: db, storedBoardId: boardId, now: now) {
            case .live(let board): return .live(try Self.resolveSupply(db: db, board: board))
            case .noWindow(let name): return .noWindow(displayName: name)
            case .dead: return .dead
            }
        }
    }

    /// Resolve one board's source supply now. Returns nil when nothing open
    /// resolves (an unresolvable source supplies nothing — the caller
    /// renders/contributes an empty supply, never blocks).
    ///
    /// - Parameters:
    ///   - boardId: The stored source id.
    ///   - now: The instant "open" is judged against.
    /// - Returns: The supply, or nil.
    /// - Throws: A GRDB read error.
    func fetchBoardSourceSupply(
        boardId: String,
        now: Date = AppDatabase.sourceClock()
    ) throws -> BoardSourceSupplyInfo? {
        try fetchOpenBoardSourceSupply(boardId: boardId, now: now).info
    }

    /// Rows for the "Add from a pool or board" sheet's BOARDS section: the
    /// user's boards that pass `BoardSources.isEligibleSourceBoard` (open
    /// window, unsealed, not a draft/archived/deleted — owner ruling
    /// 2026-09-24: ended boards are never sources), each with squares/done
    /// counts from the same predicate the member rows use. One read
    /// transaction, batched queries per board (never per-row) — call sites
    /// still dispatch this off the main thread. Web twin:
    /// `fetchSourceSheetBoardEntries`.
    ///
    /// - Parameters:
    ///   - userId: The owner whose boards to list.
    ///   - now: The instant "has this board ended" is judged against.
    /// - Returns: The rows, most recently updated first.
    /// - Throws: A GRDB read error.
    func fetchSourceSheetBoardEntries(
        userId: String,
        now: Date = AppDatabase.sourceClock()
    ) throws -> [(board: Board, info: BoardSourceSupplyInfo)] {
        try read { db in
            // Eligibility is the `isEligibleSourceBoard` rule, shared with
            // the TS twin: only open-window, unsealed boards. Names are
            // healed because a legacy daily core board is stored as the
            // literal "Today" — the rows here and the SEARCH that filters
            // them both read `board.name`.
            let boards = try Board
                .filter(Column("userId") == userId && Column("isDeleted") == false)
                .order(Column("updatedAt").desc)
                .fetchAll(db)
                .filter { BoardSources.isEligibleSourceBoard($0, now: now) }
                .healingDisplayNames()
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
                displayName: board.displayName, supplyTaskIds: [], doneTaskIds: [],
                windowCountByTaskId: [:], sourceWindow: Self.boardWindow(board)
            )
        }

        let tasks = try Task
            .filter(placedIds.contains(Column("id")) && Column("isDeleted") == false)
            .fetchAll(db)
        let taskById = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })

        // Event-owning ids + the ROOT of each window-stamped derived row (its
        // done-state reads the root's events; a root is never placed).
        let eventTaskIds = Set(tasks.filter { isEventOwningTask($0) }.map { $0.id })
            .union(tasks.compactMap { BoardSources.isWindowStampedDerived($0) ? $0.sharedCounterId : nil })
        var eventsByTaskId: [String: [TaskEvent]] = [:]
        if !eventTaskIds.isEmpty {
            let events = try TaskEvent
                .filter(eventTaskIds.contains(Column("taskId")) && Column("isDeleted") == false)
                .fetchAll(db)
            for e in events { eventsByTaskId[e.taskId, default: []].append(e) }
        }

        var seen = Set<String>()
        var supply: [String] = []
        var done = Set<String>()
        var windowCountByTaskId: [String: Int] = [:]
        for id in placedIds {
            // `isSourceSupplyTask`: achievements never enter source supply —
            // hand-placed watchers on the pulled board stay on that board only.
            guard let task = taskById[id],
                  BoardSources.isSourceSupplyTask(task),
                  !seen.contains(id) else { continue }
            seen.insert(id)
            supply.append(id)
            let isDone: Bool
            // A window-stamped derived counter is done by its ROOT's
            // increments inside its own window — the kernel's rule (docs
            // §Derived-task carve-out, amended 2026-09-23) — never the one-way
            // latch a later window's logs can set. Its count is deliberately
            // NOT fed to the prefill (`windowCountByTaskId` stays event-owning).
            if let derived = resolveDerivedCounterWindowState(task: task, eventsByTaskId: eventsByTaskId) {
                isDone = derived.isCompleted
            } else if isEventOwningTask(task) {
                let state = resolveTaskWindowState(
                    task: task,
                    events: eventsByTaskId[id] ?? [],
                    windowStart: board.startDate,
                    windowEnd: boardWindowEnd(board)
                )
                isDone = state.isCompleted
                // §Member rules (B3, RC4) — the same windowed resolution that
                // decides "done" also yields the count the remaining-target
                // prefill needs; a counter's progress in THIS window is read
                // once, never re-derived.
                if task.type == .counting { windowCountByTaskId[id] = state.count }
            } else {
                isDone = task.isCompleted
            }
            if isDone { done.insert(id) }
        }
        return BoardSourceSupplyInfo(
            displayName: board.displayName,
            supplyTaskIds: supply,
            doneTaskIds: done,
            windowCountByTaskId: windowCountByTaskId,
            sourceWindow: Self.boardWindow(board)
        )
    }

    /// The window a source board covers — `Board`'s own timeframe + dates in
    /// the shape `effectiveMemberTarget` pro-rates against.
    ///
    /// - Parameter board: The resolved source board.
    /// - Returns: Its window.
    static func boardWindow(_ board: Board) -> BoardSources.BoardWindow {
        BoardSources.BoardWindow(
            timeframe: board.timeframe,
            startDate: board.startDate,
            endDate: board.endDate
        )
    }
}

extension AppDatabase {
    /// Per-template sources resolution — the spawn's static twin, consumed
    /// by the roster health (`RecurringBoardTemplatesViewModel.computeRosterHealth`)
    /// and, through it, the pool-health warning. Web twin:
    /// `TemplateSupplyResolution` (`db/operations/boardSources.ts`).
    struct TemplateSupplyResolution {
        /// The record's resolved supplies (pool + board kinds, 'todo' applied).
        let supplies: [BoardSources.Supply]
        /// Board-kind source ids with nothing live to resolve to — the spawn
        /// would skip this template with `sourceBoardMissing`.
        let deadBoardSourceIds: [String]
        /// The record's effective hand-added layer (the un-migrated M2 rule:
        /// a record with no generalized fields treats `seedTaskIds` as manual).
        let manualTaskIds: [String]
        /// B2 (§Member rules — *Resolution pipeline* step 1): live
        /// `compound_children` rows for every COMPOUND member of `supplies`,
        /// so a reader can run `applyMemberRules` (the Split-up expansion)
        /// before counting. Empty when the supplies carry no compound.
        var childrenByCompoundId: [String: [CompoundChild]] = [:]
    }

    /// Batched, sources-native supply resolution for a roster of templates
    /// (loose-ends sweep 2026-09-09; extracted from
    /// `RecurringBoardTemplatesViewModel.reload` in the 2026-09 audit T2 so
    /// the pool-health surfaces resolve through the same reader). One pools
    /// fetch for the whole roster; each board-kind source resolves through
    /// the series-binding-aware `fetchBoardSourceSupply` the spawn uses,
    /// with the record's 'todo' filter applied. Web twin:
    /// `fetchTemplateSupplyResolution`.
    ///
    /// - Parameters:
    ///   - templates: The roster.
    ///   - tasksById: Every live task of the user (pool members, board
    ///     members, compound children) — the pool-supply filter and the
    ///     compound lookup read it.
    /// - Returns: template id → its resolution.
    /// - Throws: A GRDB error from the pools / compound-children reads.
    func fetchTemplateSupplyResolution(
        templates: [RecurringBoardTemplate],
        tasksById: [String: Task]
    ) throws -> [String: TemplateSupplyResolution] {
        let perTemplateSources = templates.map { t in
            (template: t, sources: BoardSources.sourcesForRecord(
                sources: t.sources, poolIds: t.poolIds, removedTaskIds: t.removedTaskIds
            ))
        }
        let allPoolIds = Set(perTemplateSources.flatMap { entry in
            entry.sources.filter { $0.kind == .pool }.map { $0.sourceId }
        })
        let pools = try fetchPools(ids: Array(allPoolIds))
        let poolsById = Dictionary(uniqueKeysWithValues: pools.map { ($0.id, $0) })

        var resolutionByTemplateId: [String: TemplateSupplyResolution] = [:]
        for entry in perTemplateSources {
            var supplies: [BoardSources.Supply] = []
            var deadBoardSourceIds: [String] = []
            for source in entry.sources {
                if source.kind == .pool {
                    supplies.append(BoardSources.Supply(
                        source: source,
                        supplyTaskIds: BoardSources.poolSourceSupplyById(
                            source.sourceId, poolsById: poolsById, tasksById: tasksById
                        )
                    ))
                    continue
                }
                // Series binding — the instance open now. Only a `.dead`
                // source is "missing" (the spawn's
                // ask, statically); a `.noWindow` one — no open board for this
                // window yet, owner ruling 2026-09-24 — supplies nothing but
                // is not dead.
                let resolution = (try? fetchOpenBoardSourceSupply(boardId: source.sourceId))
                    ?? .dead
                guard case .live(let info) = resolution else {
                    if resolution == .dead { deadBoardSourceIds.append(source.sourceId) }
                    supplies.append(BoardSources.Supply(source: source, supplyTaskIds: []))
                    continue
                }
                let raw = BoardSources.availableSupplyIds(
                    source: source,
                    supplyTaskIds: info.supplyTaskIds,
                    doneTaskIds: info.doneTaskIds
                )
                supplies.append(BoardSources.Supply(source: source, supplyTaskIds: raw))
            }
            let t = entry.template
            let isUnmigrated = t.sources == nil && t.poolIds == nil
                && t.manualTaskIds == nil && t.removedTaskIds == nil
            resolutionByTemplateId[t.id] = TemplateSupplyResolution(
                supplies: supplies,
                deadBoardSourceIds: deadBoardSourceIds,
                manualTaskIds: isUnmigrated ? t.seedTaskIds : (t.manualTaskIds ?? []),
                childrenByCompoundId: [:]
            )
        }

        // B2 (§Member rules step 1) — the Split-up expansion needs each
        // COMPOUND member's children. One batched links read for the whole
        // roster, after `tasksById` exists: which member ids are compounds is
        // not knowable before it. (Unlike web, the parts themselves need no
        // extra tasks fetch — `tasksById` already holds every live task of
        // this user, children included.)
        var compoundIds = Set<String>()
        for resolution in resolutionByTemplateId.values {
            for supply in resolution.supplies {
                for id in supply.supplyTaskIds where tasksById[id]?.type == .compound {
                    compoundIds.insert(id)
                }
            }
        }
        if !compoundIds.isEmpty {
            let childrenByCompoundId = try read { db in
                try AppDatabase.fetchCompoundChildren(
                    db: db, compoundTaskIds: Array(compoundIds)
                )
            }
            for (templateId, resolution) in resolutionByTemplateId {
                for supply in resolution.supplies {
                    for id in supply.supplyTaskIds {
                        guard let links = childrenByCompoundId[id] else { continue }
                        resolutionByTemplateId[templateId]?.childrenByCompoundId[id] = links
                    }
                }
            }
        }
        return resolutionByTemplateId
    }
}

extension AppDatabase {
    /// Computes the spawn-provenance note text for a freshly-spawned
    /// board (loose-ends sweep 2026-09-09) — sources-native: board-kind
    /// supplies resolve through the series-binding-aware reader with the
    /// record's 'todo' filter, and "of M" is the honest achievable pool
    /// size. Board sources resolve to their board open NOW (owner ruling
    /// 2026-09-24, the spawn's own rule); a source with no open board appends
    /// "· No board for this window yet". Runs DB reads — call off-main.
    ///
    /// Web twin: `useSpawnNoteSupplies` + `formatSpawnProvenanceNote`.
    ///
    /// - Parameters:
    ///   - template: The record the board spawned from.
    ///   - poolsById: Live pools.
    ///   - tasksById: Live tasks.
    ///   - dealtTaskIds: Task ids placed on the spawned board.
    /// - Returns: The note copy.
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
        var noBoardForWindowCount = 0
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
                let resolution = (try? fetchOpenBoardSourceSupply(boardId: source.sourceId)) ?? .dead
                if case .noWindow = resolution { noBoardForWindowCount += 1 }
                let info = resolution.info
                let raw = BoardSources.availableSupplyIds(
                    source: source,
                    supplyTaskIds: info?.supplyTaskIds ?? [],
                    doneTaskIds: info?.doneTaskIds ?? []
                )
                supplies.append(BoardSources.Supply(source: source, supplyTaskIds: raw))
            }
        }
        let summary = PoolMix.summarizeSpawnProvenance(
            supplies: supplies,
            manualTaskIds: template.manualTaskIds ?? [],
            counterFamilyByTaskId: BoardSources.buildCounterFamilyMap(tasksById.values),
            dealtTaskIds: dealtTaskIds,
            noBoardForWindowCount: noBoardForWindowCount
        )
        return PoolMix.formatSpawnProvenanceNote(summary)
    }
}
