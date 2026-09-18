import Foundation
import GRDB

/// Board Sources "member rules" B2, iOS half (docs/BOARD_SOURCES.md §Member
/// rules → *Resolution pipeline* steps 1/3/5, *Baseline*). Swift twin of
/// `apps/web/src/db/operations/derivedCounters.ts` — same function names, same
/// write rulings (RB2/RB3), same non-authored refresh semantics.
///
/// Two jobs, both of them writes that the pure `BoardSourceMemberRules.swift`
/// algorithms only describe:
///
///  1. **Mint** — at board persist and at recurring spawn, turn the planned
///     window-stamped derived counters / derived compounds into real `tasks` +
///     `compound_children` rows, BEFORE the `board_tasks` rows that point at
///     them, and hand the caller back the placement ids to use. Only a board
///     being persisted ACTIVE mints: a derived id is `uuidv5(boardId, root)`
///     and does NOT encode the window, while a DRAFT's window is still
///     editable — minting for a draft and then hitting RB3's "live row → skip"
///     on the activating save would freeze the board into a window it no
///     longer has.
///  2. **Refresh** — keep a live derived counter's `baseline` honest as the
///     root's event log changes underneath it (local counter writes and the
///     sync pull path), as a NON-AUTHORED write: no `version` bump, no sync
///     enqueue. The baseline is a cache derived from events, exactly like the
///     lifetime caches `recomputeTaskCachesFromPull` restamps; authoring it
///     would make two devices fight over a value both can recompute.
///
/// (Retirement — the deletion cascades — is B2 Task 6, not this file.)
///
/// Every function here takes an open `Database` and MUST run inside the
/// caller's transaction: the mint has to commit or roll back together with the
/// board rows it feeds, and the refresh has to be atomic with the event write
/// that made it necessary.
extension AppDatabase {

    // MARK: - Candidate roots

    /// The shared-counter roots a plan over `selectedIds` could touch: every
    /// counting member's root (`sharedCounterId ?? id`), plus the roots of
    /// every counting child of a selected compound (a One-square compound
    /// re-targets its parts, so their roots matter even though the child
    /// itself isn't selected).
    ///
    /// Callers use this to scope the `task_events` read that feeds the
    /// baselines — reading the whole event log to mint one board would be
    /// quadratic on a device with a real history.
    ///
    /// - Parameters:
    ///   - selectedIds: The ids picked for the board.
    ///   - tasksById: Id → task, for every id `selectedIds` and the links name.
    ///   - childrenByCompoundId: Compound id → its live `compound_children` rows.
    /// - Returns: The deduped candidate root ids, in first-seen order (the TS
    ///   twin's `Set` insertion order).
    static func candidateRootIds(
        selectedIds: [String],
        tasksById: [String: Task],
        childrenByCompoundId: [String: [CompoundChild]]
    ) -> [String] {
        var seen = Set<String>()
        var roots: [String] = []
        func addRoot(_ task: Task?) {
            guard let task, task.type == .counting else { return }
            let root = task.sharedCounterId ?? task.id
            if seen.insert(root).inserted { roots.append(root) }
        }
        for id in selectedIds {
            guard let task = tasksById[id] else { continue }
            addRoot(task)
            guard task.type == .compound else { continue }
            for link in childrenByCompoundId[id] ?? [] { addRoot(tasksById[link.childTaskId]) }
        }
        return roots
    }

    // MARK: - RB3 idempotent writes

    /// RB3 — write one planned `Task` idempotently.
    ///
    /// Three cases, because the row's id is a pure function of `(boardId,
    /// root)` and so re-deriving the same window hits the same primary key:
    ///   - **absent** → insert + enqueue a CREATE (the ordinary mint);
    ///   - **live** → skip entirely. No write, no enqueue, no `updatedAt`
    ///     churn: a second spawn/save of the same window must be a true no-op,
    ///     or every re-entry would push a redundant row to Firestore and
    ///     clobber a concurrently-edited target;
    ///   - **tombstoned** → a versioned revive (`version + 1`, `isDeleted`
    ///     false, `deletedAt` gone) + an UPDATE enqueue, so the revive
    ///     OUTRANKS the tombstone under LWW instead of losing to it and
    ///     self-reverting (the defect docs/BOARD_INTEGRITY.md PR-1 fixed for
    ///     `BoardTask`). `createdAt` is preserved — the row's birth hasn't moved.
    ///
    /// - Parameters:
    ///   - db: The caller's open transaction.
    ///   - row: The freshly built row, carrying this window's field values.
    ///   - now: The mint instant, stamped on a revive.
    /// - Returns: True when a row was written (insert or revive).
    @discardableResult
    private static func writeMintedTask(db: Database, row: Task, now: String) throws -> Bool {
        guard let existing = try Task.fetchOne(db, key: row.id) else {
            try row.insert(db)
            try SyncQueueBuilder.makeItem(
                entityType: "tasks",
                entityId: row.id,
                operationType: .create,
                payload: row,
                now: now
            ).enqueue(db)
            return true
        }
        guard existing.isDeleted else { return false }
        var revived = row
        revived.createdAt = existing.createdAt
        revived.updatedAt = now
        revived.version = existing.version + 1
        revived.isDeleted = false
        revived.deletedAt = nil
        try revived.save(db)
        try SyncQueueBuilder.makeItem(
            entityType: "tasks",
            entityId: row.id,
            operationType: .update,
            payload: revived,
            now: now
        ).enqueue(db)
        return true
    }

    /// RB3 for a derived compound's `compound_children` link — same three
    /// cases as ``writeMintedTask(db:row:now:)``, same rationale.
    ///
    /// - Parameters:
    ///   - db: The caller's open transaction.
    ///   - row: The freshly built link row.
    ///   - now: The mint instant, stamped on a revive.
    /// - Returns: True when a row was written (insert or revive).
    @discardableResult
    private static func writeMintedLink(db: Database, row: CompoundChild, now: String) throws -> Bool {
        guard let existing = try CompoundChild.fetchOne(db, key: row.id) else {
            try row.insert(db)
            try SyncQueueBuilder.makeItem(
                entityType: "compoundChildren",
                entityId: row.id,
                operationType: .create,
                payload: row,
                now: now
            ).enqueue(db)
            return true
        }
        guard existing.isDeleted else { return false }
        var revived = row
        revived.createdAt = existing.createdAt
        revived.updatedAt = now
        revived.version = existing.version + 1
        revived.isDeleted = false
        revived.deletedAt = nil
        try revived.save(db)
        try SyncQueueBuilder.makeItem(
            entityType: "compoundChildren",
            entityId: row.id,
            operationType: .update,
            payload: revived,
            now: now
        ).enqueue(db)
        return true
    }

    // MARK: - Mint

    /// Plan the member rules for one board and materialise what they produce
    /// (docs/BOARD_SOURCES.md §Member rules — *Resolution pipeline* steps 3 + 5).
    ///
    /// Runs INSIDE the caller's open transaction. The caller places
    /// `placementIds` instead of its own `selectedIds`, positionally — the two
    /// arrays are the same length and a replaced id keeps its cell.
    ///
    /// Baselines are computed at RB2's boundary: the board's `startDate` when
    /// it has one, else the mint `now` (an INDEFINITE board's window opens the
    /// moment it is created). `startDate` is passed through verbatim — board
    /// dates are LOCAL ISO with a time component and `computeWindowBaseline`
    /// compares instants, so re-stamping it as UTC would move the boundary by
    /// the local offset.
    ///
    /// - Parameters:
    ///   - db: The caller's open transaction.
    ///   - boardId: The board being assembled — half of every derived row's id.
    ///   - userId: Owner of the rows minted.
    ///   - now: ISO8601 mint instant — `createdAt`/`updatedAt` on every row.
    ///   - selectedIds: The task ids picked for the board, in placement order.
    ///   - supplies: Per-source supplies, exclude-filtered and Split-up expanded.
    ///   - manualTaskIds: Hand-added ids — they win over any source copy.
    ///   - manualTaskVary: Hand-added members' vary levels.
    ///   - window: The window being assembled.
    ///   - mode: Auto targets apply to `.recurring` only.
    ///   - tasksById: Every id `selectedIds` / the supplies / the links name.
    ///   - childrenByCompoundId: Compound id → its live `compound_children` rows.
    ///   - sourceWindowByTaskId: Board-source members' (and their compound
    ///     children's) source windows.
    ///   - events: Candidate roots' `task_events` rows (see ``candidateRootIds(selectedIds:tasksById:childrenByCompoundId:)``).
    ///   - rng: RB6 — unseeded in production; injected in tests.
    /// - Returns: The placement ids to write, and the rows the plan produced.
    static func planAndMintDerivedRows(
        db: Database,
        boardId: String,
        userId: String,
        now: String,
        selectedIds: [String],
        supplies: [BoardSources.ExpandedSupply],
        manualTaskIds: [String],
        manualTaskVary: [String: VaryLevel],
        window: BoardSources.BoardWindow,
        mode: BoardSources.PlanMode,
        tasksById: [String: Task],
        childrenByCompoundId: [String: [CompoundChild]],
        sourceWindowByTaskId: [String: BoardSources.BoardWindow],
        events: [TaskEvent],
        rng: () -> Double = { Double.random(in: 0..<1) }
    ) throws -> (placementIds: [String], minted: BoardSources.DerivedRows) {
        // RB2 — the window boundary. `startDate` is a full local-ISO timestamp
        // on every board that has one; a date-less board opens now.
        let boundary = window.startDate ?? now
        var baselineByRootId: [String: Int] = [:]
        for root in candidateRootIds(
            selectedIds: selectedIds,
            tasksById: tasksById,
            childrenByCompoundId: childrenByCompoundId
        ) {
            baselineByRootId[root] = BoardSources.computeWindowBaseline(
                rootTaskId: root,
                events: events,
                boundary: boundary
            )
        }

        let drafts = BoardSources.planDerivedTasks(
            selectedIds: selectedIds,
            supplies: supplies,
            manualTaskIds: manualTaskIds,
            manualTaskVary: manualTaskVary,
            boardId: boardId,
            window: window,
            mode: mode,
            tasksById: tasksById,
            childrenByCompoundId: childrenByCompoundId,
            sourceWindowByTaskId: sourceWindowByTaskId,
            baselineByRootId: baselineByRootId,
            rng: rng
        )

        guard !drafts.derivedTasks.isEmpty || !drafts.derivedCompounds.isEmpty else {
            return (drafts.placementIds, BoardSources.DerivedRows(tasks: [], links: []))
        }

        // `buildDerivedRows` degrades quietly rather than throwing when a root
        // or a source compound is missing from its maps, so fill them for
        // EVERY id the drafts reference — `tasksById` covers the selected
        // members, but a member that is itself a derived counter points at a
        // root that may not be on this board at all.
        var rootsById: [String: Task] = [:]
        for draft in drafts.derivedTasks {
            if let local = try tasksById[draft.rootTaskId] ?? Task.fetchOne(db, key: draft.rootTaskId) {
                rootsById[draft.rootTaskId] = local
            }
        }
        var compoundsById: [String: Task] = [:]
        for compound in drafts.derivedCompounds {
            if let local = try tasksById[compound.sourceCompoundId]
                ?? Task.fetchOne(db, key: compound.sourceCompoundId) {
                compoundsById[compound.sourceCompoundId] = local
            }
        }

        let minted = BoardSources.buildDerivedRows(
            drafts: drafts,
            userId: userId,
            now: now,
            rootsById: rootsById,
            compoundsById: compoundsById
        )

        for row in minted.tasks { try writeMintedTask(db: db, row: row, now: now) }
        for link in minted.links { try writeMintedLink(db: db, row: link, now: now) }

        return (drafts.placementIds, minted)
    }

    /// Board Sources §Member rules (B2) — the one-off wizard's mint entry
    /// point: resolve this board's per-member rules and materialise what they
    /// call for, inside `saveWizardBoard`'s transaction and BEFORE the
    /// `board_tasks` rows that will point at the results.
    ///
    /// Rebuilds the supplies the same way the spawn path does — pool members
    /// via `poolSourceSupplyById`, board members via `resolveSourceBoard`
    /// (series binding) + `resolveSupply` (the done-filter) — then
    /// exclude-filters and Split-up-expands them through `applyMemberRules`.
    /// An unresolvable board source contributes an empty supply rather than
    /// failing the save: the placement it fed was already decided upstairs,
    /// and a board save must never be blocked by a source that has since been
    /// archived.
    ///
    /// - Parameters:
    ///   - db: `saveWizardBoard`'s open transaction.
    ///   - boardId: The board being written (half of every derived id).
    ///   - userId: Owner of the rows minted.
    ///   - now: ISO8601 mint instant.
    ///   - selectedIds: The placed task ids, in placement order.
    ///   - sources: The wizard's pulled sources.
    ///   - manualTaskIds: The hand-added layer.
    ///   - window: The board's own window.
    /// - Returns: The ids to place, positionally 1:1 with `selectedIds`.
    static func mintWizardDerivedRows(
        db: Database,
        boardId: String,
        userId: String,
        now: String,
        selectedIds: [String],
        sources: [BoardSource],
        manualTaskIds: [String],
        window: BoardSources.BoardWindow
    ) throws -> [String] {
        // The planner gets LIVE rows only — a soft-deleted root reachable
        // through a member's `sharedCounterId` must not be mirrored into a new
        // derived row.
        var tasksById: [String: Task] = [:]
        for task in try Task.filter(Column("isDeleted") == false).fetchAll(db) {
            tasksById[task.id] = task
        }

        let poolSourceIds = sources.filter { $0.kind == .pool }.map { $0.sourceId }
        let pools = poolSourceIds.isEmpty
            ? []
            : try Pool.filter(poolSourceIds.contains(Column("id"))).fetchAll(db)
        let poolsById = Dictionary(uniqueKeysWithValues: pools.map { ($0.id, $0) })

        var rawSupplies: [BoardSources.Supply] = []
        var sourceBoardWindow: [String: BoardSources.BoardWindow] = [:]
        for source in sources {
            switch source.kind {
            case .pool:
                rawSupplies.append(BoardSources.Supply(
                    source: source,
                    supplyTaskIds: BoardSources.poolSourceSupplyById(
                        source.sourceId, poolsById: poolsById, tasksById: tasksById
                    )
                ))
            case .board:
                guard let board = try Self.resolveSourceBoard(
                    db: db, storedBoardId: source.sourceId, reference: window.startDate ?? now
                ) else {
                    rawSupplies.append(BoardSources.Supply(source: source, supplyTaskIds: []))
                    continue
                }
                sourceBoardWindow[source.sourceId] = BoardSources.BoardWindow(
                    timeframe: board.timeframe,
                    startDate: board.startDate,
                    endDate: board.endDate
                )
                let info = try Self.resolveSupply(db: db, board: board)
                var raw = info.supplyTaskIds
                if source.filter == .todo {
                    raw.removeAll { info.doneTaskIds.contains($0) }
                }
                rawSupplies.append(BoardSources.Supply(source: source, supplyTaskIds: raw))
            }
        }

        // Compound children for every compound the plan can name — the placed
        // ones (a One-square compound re-targets its parts) and the supplied
        // ones (a Split-up member expands into its children). ONE batched read.
        var compoundIds = Set<String>()
        func noteCompound(_ id: String) {
            if tasksById[id]?.type == .compound { compoundIds.insert(id) }
        }
        for id in selectedIds { noteCompound(id) }
        for supply in rawSupplies { for id in supply.supplyTaskIds { noteCompound(id) } }
        let childrenByCompoundId = try Self.fetchCompoundChildren(
            db: db, compoundTaskIds: Array(compoundIds)
        )

        let supplies = BoardSources.applyMemberRules(
            rawSupplies.map {
                BoardSources.Supply(
                    source: $0.source,
                    supplyTaskIds: BoardSources.resolveSourceAvailable($0)
                )
            },
            childrenByCompoundId: childrenByCompoundId,
            tasksById: tasksById
        )

        // Auto targets pro-rate by the SOURCE window, looked up per supplied
        // id and per child of a compound member (never by the compound's own
        // id) — a caller that keys only the member ids silently gets no
        // pro-rating.
        var sourceWindowByTaskId: [String: BoardSources.BoardWindow] = [:]
        for supply in supplies {
            guard let sourceWindow = sourceBoardWindow[supply.source.sourceId] else { continue }
            for id in supply.supplyTaskIds {
                sourceWindowByTaskId[id] = sourceWindow
                for link in childrenByCompoundId[id] ?? [] {
                    sourceWindowByTaskId[link.childTaskId] = sourceWindow
                }
            }
        }

        let roots = candidateRootIds(
            selectedIds: selectedIds,
            tasksById: tasksById,
            childrenByCompoundId: childrenByCompoundId
        )
        let events = roots.isEmpty
            ? []
            : try TaskEvent.filter(roots.contains(Column("taskId"))).fetchAll(db)

        return try planAndMintDerivedRows(
            db: db,
            boardId: boardId,
            userId: userId,
            now: now,
            selectedIds: selectedIds,
            supplies: supplies,
            manualTaskIds: manualTaskIds,
            // RB9 — the one-off wizard has no UI for hand-added members' dice
            // levels yet, so nothing varies on that layer.
            manualTaskVary: [:],
            window: window,
            // A repeating board never reaches here (its "Create Board"
            // persists a record and spawns), so this path is always one-off —
            // which is what suppresses auto targets.
            mode: .oneOff,
            tasksById: tasksById,
            childrenByCompoundId: childrenByCompoundId,
            sourceWindowByTaskId: sourceWindowByTaskId,
            events: events
        ).placementIds
    }

    // MARK: - Refresh (non-authored)

    /// The live window-stamped derived counters that derive from `rootTaskId`.
    ///
    /// All three marks (`BoardSources.isWindowStampedDerived`) are required —
    /// a hand-made linked counter shares the `sharedCounterId` index with them
    /// and must never have its `baseline` rewritten by this pipeline.
    ///
    /// - Parameters:
    ///   - db: The caller's open transaction.
    ///   - rootTaskId: The shared-counter root.
    /// - Returns: The matching live rows.
    static func fetchWindowStampedDerived(db: Database, rootTaskId: String) throws -> [Task] {
        try Task
            .filter(Column("sharedCounterId") == rootTaskId && Column("isDeleted") == false)
            .fetchAll(db)
            .filter { BoardSources.isWindowStampedDerived($0) }
    }

    /// Recompute every window-stamped derived counter's `baseline` from the
    /// root's current event log (docs/BOARD_SOURCES.md §Member rules —
    /// *Baseline*).
    ///
    /// A NON-AUTHORED write, exactly like `recomputeTaskCachesFromPull`: a raw
    /// `UPDATE tasks SET baseline = ?` and nothing else — no `updatedAt`, no
    /// `version` bump, no sync enqueue. The baseline is a pure function of
    /// `(root events, window start)`, so every device recomputes the same
    /// value from rows it already has; authoring it would put two devices into
    /// an LWW fight over a derived number.
    ///
    /// Each row's boundary is its own `startDate` — always present, because
    /// `isWindowStampedDerived` is what selects the rows and it requires one.
    /// The consequence worth stating: a derived counter minted for a board
    /// with NO `startDate` (where RB2 used the mint instant) carries no window
    /// stamp, fails that predicate, and is therefore never refreshed on any
    /// path. That is the spec's own window-stamped scoping, not a gap.
    ///
    /// A row whose baseline is already correct is not touched at all, so
    /// calling this after every counter write is cheap and idempotent.
    ///
    /// - Parameters:
    ///   - db: The caller's open transaction.
    ///   - rootTaskId: The shared-counter root whose derived members to refresh.
    ///   - events: The root's events, when the caller already has them in hand
    ///     (`nil` → read here, inside the caller's transaction).
    /// - Returns: How many rows were actually rewritten.
    @discardableResult
    static func refreshDerivedBaselines(
        db: Database,
        rootTaskId: String,
        events: [TaskEvent]? = nil
    ) throws -> Int {
        let rows = try fetchWindowStampedDerived(db: db, rootTaskId: rootTaskId)
        guard !rows.isEmpty else { return 0 }
        let rootEvents: [TaskEvent]
        if let events {
            rootEvents = events
        } else {
            rootEvents = try TaskEvent.filter(Column("taskId") == rootTaskId).fetchAll(db)
        }
        var touched = 0
        for row in rows {
            // `row.startDate` is non-nil by construction — see the note above.
            guard let boundary = row.startDate else { continue }
            let baseline = BoardSources.computeWindowBaseline(
                rootTaskId: rootTaskId,
                events: rootEvents,
                boundary: boundary
            )
            if (row.baseline ?? 0) == baseline { continue }
            try db.execute(sql: "UPDATE tasks SET baseline = ? WHERE id = ?",
                           arguments: [baseline, row.id])
            touched += 1
        }
        return touched
    }

    /// The sync pull path's per-task sub-step: restamp an event-owning task's
    /// lifetime caches from the just-pulled events, then refresh every
    /// window-stamped derived counter hanging off it (B2 — the root's event
    /// log just moved, so the baselines it feeds may be stale).
    ///
    /// Extracted from `SyncService` so both pull entry points
    /// (`applyTaskEventsBatch` and `healMissingCompletionEvents`) share ONE
    /// loop body and the god-file-guardrailed service keeps a one-line call.
    /// Both writes are non-authored: no version bump, no enqueue.
    ///
    /// - Parameters:
    ///   - db: The pull's open transaction.
    ///   - taskIds: The tasks whose events were touched by this pull.
    /// - Returns: The subset that actually exists locally AND owns events —
    ///   what the caller then cascades over.
    @discardableResult
    static func recomputeTaskCachesAndRefreshDerived(
        db: Database,
        taskIds: Set<String>
    ) throws -> Set<String> {
        var touched = Set<String>()
        for taskId in taskIds {
            // A task whose row isn't local yet is skipped-and-deferred (the
            // safety-net retry picks it up); a non-event-owning one never had
            // caches to restamp and can't be a shared-counter root either.
            guard let task = try Task.fetchOne(db, key: taskId), isEventOwningTask(task) else { continue }
            try recomputeTaskCachesFromPull(db: db, taskId: taskId)
            try refreshDerivedBaselines(db: db, rootTaskId: taskId)
            touched.insert(taskId)
        }
        return touched
    }
}
