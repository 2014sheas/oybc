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
    /// `reference` MUST be in the LOCAL-wall-clock ISO format board
    /// dates use (`wizardLocalISOString` — no Z suffix): the window
    /// comparisons are lexicographic, and a UTC `currentTimestamp()`
    /// instant mis-sorts against local boundaries near local midnight in
    /// any non-UTC zone (review-caught Critical, 2026-09-09).
    func fetchBoardSourceSupply(
        boardId: String,
        reference: String = wizardLocalISOString(Date())
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

    /// Rows for the "Add from a pool or board" sheet's BOARDS section: ACTIVE,
    /// non-deleted boards, each with squares/done counts from the same
    /// predicate the member rows use. One read transaction, batched
    /// queries per board (never per-row) — call sites still dispatch this
    /// off the main thread (it walks every active board).
    func fetchSourceSheetBoardEntries(
        userId: String
    ) throws -> [(board: Board, info: BoardSourceSupplyInfo)] {
        let now = Date()
        return try read { db in
            // Eligibility is the `isEligibleSourceBoard` rule, shared with
            // the TS twin. This sheet previously filtered on
            // `status == .active` alone: a board whose window
            // closes unfinished stays `.active` forever, so every stale
            // core board stayed on offer. Names are healed because a legacy
            // daily core board is stored as the literal "Today" — the rows
            // here and the SEARCH that filters them both read `board.name`.
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
                    windowStart: board.startDate
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
                // Series binding — `fetchBoardSourceSupply` hops a stored
                // series instance to the live window; nil means nothing live
                // resolves (the spawn's ask, statically).
                let info = (try? fetchBoardSourceSupply(boardId: source.sourceId)) ?? nil
                guard let info else {
                    deadBoardSourceIds.append(source.sourceId)
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
            dealtTaskIds: dealtTaskIds
        )
        return PoolMix.formatSpawnProvenanceNote(summary)
    }
}
