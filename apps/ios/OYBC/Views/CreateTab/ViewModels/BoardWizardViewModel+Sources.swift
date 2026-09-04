import Foundation

/// Per-source display/supply cache entry (Board Sources P2,
/// docs/BOARD_SOURCES.md). Holds the RAW supply — before excludes and
/// before the board `'todo'` filter — plus the done-set so the expanded
/// panel can render filtered-out members dimmed with a ✓ instead of
/// hiding them. `doneTaskIds` is always empty for pools.
struct WizardSourceSupply: Equatable {
    var displayName: String
    var rawSupplyTaskIds: [String]
    var doneTaskIds: Set<String>
}

/// Board Sources P2 — the sources-native wizard actions + derived reads.
/// Split out of the frozen `BoardWizardViewModel.swift` god-file (ROADMAP
/// B6 posture). Stored properties (`sources`, `supplyInfoBySourceId`,
/// `expandedSourceIds`) live on the class; everything here is behavior.
extension BoardWizardViewModel {

    // MARK: - Derived supply/capacity reads

    /// The algorithm-ready supplies: raw supply − nothing (excludes are
    /// the algorithm's job) with the board `'todo'` filter applied by the
    /// platform (the P1 `BoardSources.Supply` contract). Order = row order.
    func algorithmSupplies() -> [BoardSources.Supply] {
        sources.map { source in
            let info = supplyInfoBySourceId[source.sourceId]
            var raw = info?.rawSupplyTaskIds ?? []
            if source.kind == .board, source.filter == .todo, let done = info?.doneTaskIds {
                raw.removeAll { done.contains($0) }
            }
            return BoardSources.Supply(source: source, supplyTaskIds: raw)
        }
    }

    /// One source's AVAILABLE count (post-exclude, post-filter) — the
    /// range slider's N, the "of N" label, and the min clamp bound.
    func availableCount(forSourceId sourceId: String) -> Int {
        guard let supply = algorithmSupplies().first(where: { $0.source.sourceId == sourceId })
        else { return 0 }
        return BoardSources.resolveSourceAvailable(supply).count
    }

    /// The header/gate capacity (docs/BOARD_SOURCES.md §Selection step 3):
    /// sum of source maxes + hand-added, deduped. Replaces
    /// `selectedTaskIds.count` everywhere the step gates/counts.
    var sourceCapacity: Int {
        BoardSources.computeSourceCapacity(
            algorithmSupplies(),
            manualTaskIds: Array(manualTaskIds)
        ).capacity
    }

    // MARK: - Pull / remove

    /// Pull a pool in as a `[0, all]` source row. No-op when soft-deleted
    /// or already pulled. The saved `Pool` is never modified.
    func pullPool(_ pool: Pool, tasksById: [String: Task]) {
        guard !pool.isDeleted, !sources.contains(where: { $0.sourceId == pool.id }) else { return }
        supplyInfoBySourceId[pool.id] = WizardSourceSupply(
            displayName: pool.name,
            rawSupplyTaskIds: BoardSources.poolSourceSupplyById(
                pool.id, poolsById: [pool.id: pool], tasksById: tasksById
            ),
            doneTaskIds: []
        )
        sources.append(BoardSource(sourceId: pool.id, kind: .pool))
        recomputeSelectionFromSources()
    }

    /// Pull a board in as a `[0, all]` source row (filter `.all`). No-op
    /// when the board is missing/soft-deleted or already pulled. The
    /// source board is never modified.
    func pullBoard(boardId: String) {
        guard !sources.contains(where: { $0.sourceId == boardId }) else { return }
        guard let info = try? database.fetchBoardSourceSupply(boardId: boardId) else {
            return
        }
        supplyInfoBySourceId[boardId] = WizardSourceSupply(
            displayName: info.displayName,
            rawSupplyTaskIds: info.supplyTaskIds,
            doneTaskIds: info.doneTaskIds
        )
        sources.append(BoardSource(sourceId: boardId, kind: .board))
        recomputeSelectionFromSources()
    }

    /// Remove a source row entirely (the row's ✕). Its supply leaves the
    /// selection; the manual layer is never touched.
    func removeSource(sourceId: String) {
        sources.removeAll { $0.sourceId == sourceId }
        supplyInfoBySourceId.removeValue(forKey: sourceId)
        expandedSourceIds.remove(sourceId)
        recomputeSelectionFromSources()
    }

    // MARK: - Range / filter / excludes

    /// Set a source's membership range. `max == nil` is the "all" latch.
    /// Clamps: `0 ≤ min ≤ min(available, tasksRequired)`; a numeric max
    /// never drops below min.
    func setSourceRange(sourceId: String, min newMin: Int, max newMax: Int?) {
        guard let i = sources.firstIndex(where: { $0.sourceId == sourceId }) else { return }
        let cap = Swift.min(availableCount(forSourceId: sourceId), tasksRequired)
        let clampedMin = Swift.max(0, Swift.min(newMin, cap))
        sources[i].min = clampedMin
        sources[i].max = newMax.map { Swift.max($0, clampedMin) }
    }

    /// "Use all" — reset the range to the default `[0, all]`.
    func resetSourceRange(sourceId: String) {
        setSourceRange(sourceId: sourceId, min: 0, max: nil)
    }

    /// Flip a board source's member filter (All squares / Not done yet).
    /// Re-clamps min (available shrinks under `.todo`) and recomputes the
    /// selection union. Pools ignore the filter by contract.
    func setSourceFilter(sourceId: String, filter: BoardSource.Filter) {
        guard let i = sources.firstIndex(where: { $0.sourceId == sourceId }) else { return }
        sources[i].filter = filter
        clampSourceMin(at: i)
        recomputeSelectionFromSources()
    }

    /// Toggle one member's per-board exclusion inside one source (the
    /// expanded panel's ✕ / UNDO). The saved pool/board is untouched.
    /// A `max` at the "all" latch follows the shrink/restore automatically
    /// (effective max tracks availability); min re-clamps.
    func toggleSourceExclude(sourceId: String, taskId: String) {
        guard let i = sources.firstIndex(where: { $0.sourceId == sourceId }) else { return }
        if let j = sources[i].excludedTaskIds.firstIndex(of: taskId) {
            sources[i].excludedTaskIds.remove(at: j)
        } else {
            sources[i].excludedTaskIds.append(taskId)
        }
        clampSourceMin(at: i)
        recomputeSelectionFromSources()
    }

    private func clampSourceMin(at index: Int) {
        let cap = Swift.min(
            availableCount(forSourceId: sources[index].sourceId),
            tasksRequired
        )
        if sources[index].min > cap { sources[index].min = cap }
        if let max = sources[index].max, max < sources[index].min {
            sources[index].max = sources[index].min
        }
    }

    // MARK: - Manual layer

    /// Toggles a task's hand-added selection; clears the center mark when
    /// deselecting the current center; purges pending (Bug #85) + staged
    /// edits on removal.
    ///
    /// Board Sources P2: deselecting a task a source supplies excludes it
    /// from EVERY supplying source (the old flat-removal global-suppress
    /// semantics — the library sheet has no per-source scope); the manual
    /// layer always wins on re-select (excludes stay, matching
    /// `resolveMix`'s manual-wins rule).
    func toggleTaskSelection(_ taskId: String) {
        if selectedTaskIds.contains(taskId) {
            manualTaskIds.remove(taskId)
            pendingTasks.removeValue(forKey: taskId)
            stagedEdits.removeValue(forKey: taskId)
            poolOrder.removeAll { $0 == taskId }
            for i in sources.indices {
                let raw = supplyInfoBySourceId[sources[i].sourceId]?.rawSupplyTaskIds ?? []
                if raw.contains(taskId), !sources[i].excludedTaskIds.contains(taskId) {
                    sources[i].excludedTaskIds.append(taskId)
                    clampSourceMin(at: i)
                }
            }
            recomputeSelectionFromSources()
        } else {
            manualTaskIds.insert(taskId)
            if !poolOrder.contains(taskId) { poolOrder.append(taskId) }
            recomputeSelectionFromSources()
        }
    }

    // MARK: - Selection recompute + supply refresh

    /// Rebuild `selectedTaskIds` = dedupe(every source's available ∪
    /// manual) and purge center/pending/staged references to ids that
    /// dropped out. `poolOrder` holds ONLY manual-row order in the
    /// sources model (source members render inside their row's panel).
    func recomputeSelectionFromSources() {
        var union = Set<String>()
        for supply in algorithmSupplies() {
            for id in BoardSources.resolveSourceAvailable(supply) { union.insert(id) }
        }
        let newSelection = union.union(manualTaskIds)
        for dropped in selectedTaskIds.subtracting(newSelection) {
            if centerTaskId == dropped { centerTaskId = nil }
            pendingTasks.removeValue(forKey: dropped)
            stagedEdits.removeValue(forKey: dropped)
            poolOrder.removeAll { $0 == dropped }
        }
        selectedTaskIds = newSelection
    }

    /// Re-resolve every cached supply against fresh lookups (pool edits,
    /// task deletions, board changes since pull). Sources whose entity
    /// vanished keep an empty supply — they contribute nothing, never
    /// block (the design's empty-source rule).
    func refreshSourceSupplies(poolsById: [String: Pool], tasksById: [String: Task]) {
        for source in sources {
            switch source.kind {
            case .pool:
                let name = poolsById[source.sourceId]?.name
                    ?? supplyInfoBySourceId[source.sourceId]?.displayName ?? ""
                supplyInfoBySourceId[source.sourceId] = WizardSourceSupply(
                    displayName: name,
                    rawSupplyTaskIds: BoardSources.poolSourceSupplyById(
                        source.sourceId, poolsById: poolsById, tasksById: tasksById
                    ),
                    doneTaskIds: []
                )
            case .board:
                if let info = (try? database.fetchBoardSourceSupply(boardId: source.sourceId)) ?? nil {
                    supplyInfoBySourceId[source.sourceId] = WizardSourceSupply(
                        displayName: info.displayName,
                        rawSupplyTaskIds: info.supplyTaskIds,
                        doneTaskIds: info.doneTaskIds
                    )
                } else {
                    supplyInfoBySourceId[source.sourceId] = WizardSourceSupply(
                        displayName: supplyInfoBySourceId[source.sourceId]?.displayName ?? "",
                        rawSupplyTaskIds: [],
                        doneTaskIds: []
                    )
                }
            }
        }
        for i in sources.indices { clampSourceMin(at: i) }
        recomputeSelectionFromSources()
    }
}

// MARK: - Init-time hydration (static — safe before self is fully built)

extension BoardWizardViewModel {
    /// Resolve a persisted `sources` array (+ manual layer) into the full
    /// wizard sources state: supply caches, the selection union
    /// (post-exclude, post-filter, ∪ manual), and the manual-row order.
    /// Static so `init`'s hydration branches can call it before every
    /// stored property is initialized. Fetch failures degrade to empty
    /// supplies — the wizard still opens; nothing blocks.
    static func hydrateSourcesState(
        sources rawSources: [BoardSource],
        manualTaskIds: [String],
        database: AppDatabase
    ) -> (
        sources: [BoardSource],
        supplyInfo: [String: WizardSourceSupply],
        selectedTaskIds: Set<String>,
        poolOrder: [String]
    ) {
        var supplyInfo: [String: WizardSourceSupply] = [:]
        let poolIds = rawSources.filter { $0.kind == .pool }.map { $0.sourceId }
        let pools = (try? database.fetchPools(ids: poolIds)) ?? []
        let poolsById = Dictionary(uniqueKeysWithValues: pools.map { ($0.id, $0) })
        var referencedIds = Set<String>()
        for pool in pools { referencedIds.formUnion(pool.taskIds) }
        referencedIds.formUnion(manualTaskIds)
        let tasks = (try? database.fetchTasks(ids: Array(referencedIds))) ?? []
        let tasksById = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })

        for source in rawSources {
            switch source.kind {
            case .pool:
                supplyInfo[source.sourceId] = WizardSourceSupply(
                    displayName: poolsById[source.sourceId]?.name ?? "",
                    rawSupplyTaskIds: BoardSources.poolSourceSupplyById(
                        source.sourceId, poolsById: poolsById, tasksById: tasksById
                    ),
                    doneTaskIds: []
                )
            case .board:
                if let info = (try? database.fetchBoardSourceSupply(boardId: source.sourceId)) ?? nil {
                    supplyInfo[source.sourceId] = WizardSourceSupply(
                        displayName: info.displayName,
                        rawSupplyTaskIds: info.supplyTaskIds,
                        doneTaskIds: info.doneTaskIds
                    )
                } else {
                    supplyInfo[source.sourceId] = WizardSourceSupply(
                        displayName: "", rawSupplyTaskIds: [], doneTaskIds: []
                    )
                }
            }
        }

        var union = Set<String>()
        for source in rawSources {
            let info = supplyInfo[source.sourceId]
            var raw = info?.rawSupplyTaskIds ?? []
            if source.kind == .board, source.filter == .todo, let done = info?.doneTaskIds {
                raw.removeAll { done.contains($0) }
            }
            let excluded = Set(source.excludedTaskIds)
            for id in raw where !excluded.contains(id) { union.insert(id) }
        }
        // The manual layer passes through verbatim (caller-curated —
        // `resolveMix`'s old contract; a hard-gone id is dropped later by
        // the placement/persist lookups, exactly as before).
        union.formUnion(manualTaskIds)
        return (rawSources, supplyInfo, union, manualTaskIds)
    }
}

// MARK: - Source-picker sheet data

extension BoardWizardViewModel {
    /// Rows for the "Add a pool or board" sheet's BOARDS section: ACTIVE,
    /// non-deleted boards (drafts and sealed/expired records are not
    /// pull-able sources — the sheet lists active boards only, per the
    /// design), each with its squares/done counts from the same
    /// `fetchBoardSourceSupply` predicate the member rows use. Silent on
    /// DB error (empty section), matching the wizard's I/O posture.
    func sourceSheetBoardEntries(userId: String) -> [RisoSourcePickerSheetView.BoardEntry] {
        guard let boards = try? database.fetchBoards(userId: userId) else { return [] }
        return boards
            .filter { $0.status == .active && !$0.isDeleted }
            .compactMap { board in
                guard let info = try? database.fetchBoardSourceSupply(boardId: board.id) else {
                    return nil
                }
                return RisoSourcePickerSheetView.BoardEntry(
                    board: board,
                    squares: info.supplyTaskIds.count,
                    done: info.doneTaskIds.count
                )
            }
    }
}
