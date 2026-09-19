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
    /// §Member rules (B3, RC4) — board sources only: each event-owning
    /// COUNTING member's windowed count in the SOURCE board's window. Always
    /// empty for pools (a pool has no window of its own).
    var windowCountByTaskId: [String: Int] = [:]
    /// §Member rules (B3, RC5) — board sources only: the source board's own
    /// window, for pro-rating an auto target against the board being built.
    var sourceWindow: BoardSources.BoardWindow? = nil
}

/// Board Sources P2 — the sources-native wizard actions + derived reads.
/// Split out of the frozen `BoardWizardViewModel.swift` god-file (ROADMAP
/// B6 posture). Stored properties (`sources`, `supplyInfoBySourceId`,
/// `expandedSourceIds`) live on the class; everything here is behavior.
extension BoardWizardViewModel {

    // MARK: - Derived supply/capacity reads

    /// The algorithm-ready supplies: the platform-applied board `'todo'`
    /// filter, each source's `excludedTaskIds` subtracted, and — §Member
    /// rules (B3, RC7) — Split-up members expanded into their non-excluded
    /// parts via `applyMemberRules`. Order = row order.
    ///
    /// Excludes are applied BEFORE the expansion (the same order the persist
    /// path's mint uses): excluding a split compound must remove its parts,
    /// and a part is not named by the compound's own exclude entry.
    /// Downstream `resolveSourceAvailable` calls stay correct — it is
    /// idempotent.
    var expandedSupplies: [BoardSources.ExpandedSupply] {
        // Memoised on its three inputs (M5): `availableCount` goes through
        // this, `clampSourceMin` calls `availableCount` per source, and
        // `commitSupplyChange` loops every source and then recomputes the
        // selection — so one rule edit used to rebuild the whole expansion
        // O(n²) times. The cache key is the inputs themselves, compared by
        // value, so a stale hit is impossible by construction (no mutator has
        // to remember to invalidate).
        if let cache = expandedSuppliesCache,
           cache.sources == sources,
           cache.supplyInfo == supplyInfoBySourceId,
           cache.children == childrenByCompoundId {
            return cache.value
        }
        let expanded = computeExpandedSupplies()
        expandedSuppliesCache = (sources, supplyInfoBySourceId, childrenByCompoundId, expanded)
        return expanded
    }

    /// The uncached expansion — see ``expandedSupplies``.
    private func computeExpandedSupplies() -> [BoardSources.ExpandedSupply] {
        let raw = sources.map { source -> BoardSources.Supply in
            let info = supplyInfoBySourceId[source.sourceId]
            var ids = info?.rawSupplyTaskIds ?? []
            if source.kind == .board, source.filter == .todo, let done = info?.doneTaskIds {
                ids.removeAll { done.contains($0) }
            }
            return BoardSources.Supply(
                source: source,
                supplyTaskIds: BoardSources.resolveSourceAvailable(
                    BoardSources.Supply(source: source, supplyTaskIds: ids)
                )
            )
        }
        return BoardSources.applyMemberRules(
            raw,
            childrenByCompoundId: childrenByCompoundId,
            tasksById: supplyTasksById
        )
    }

    /// The expanded supplies as plain ``BoardSources/Supply`` values, for
    /// the selection/capacity helpers that take the base type (`partOf` is
    /// still reachable through ``expandedSupplies``).
    func algorithmSupplies() -> [BoardSources.Supply] {
        expandedSupplies.map { $0.asSupply }
    }

    /// One source's AVAILABLE count (post-exclude, post-filter, post-Split-up
    /// expansion) — the range slider's N, the "of N" label, and the min clamp
    /// bound. A split compound contributes its parts, so the count grows by
    /// `parts − 1 − excluded parts`.
    func availableCount(forSourceId sourceId: String) -> Int {
        guard let supply = algorithmSupplies().first(where: { $0.source.sourceId == sourceId })
        else { return 0 }
        return BoardSources.resolveSourceAvailable(supply).count
    }

    /// The header/gate capacity — since the counter-family rework
    /// (2026-09-08) the HONEST achievable pool size: a deterministic
    /// dry-run of the actual fill (source caps, cap overlap, one square
    /// per shared-counter family, the CHOSEN center pinned), computed
    /// before any preview/deal. Replaces `selectedTaskIds.count`
    /// everywhere the step gates/counts; gate-passed ⇒ the deal fills.
    var sourceCapacity: Int {
        BoardSources.computeSourceCapacity(
            algorithmSupplies(),
            manualTaskIds: Array(manualTaskIds),
            counterFamilyByTaskId: counterFamilyByTaskId,
            pinnedTaskId: centerType == .chosen ? centerTaskId : nil
        ).capacity
    }

    /// The full task id → shared-counter family map: the container-fed
    /// library half plus this session's pending tasks. Web twin:
    /// `useBoardWizard.counterFamilyByTaskId`.
    var counterFamilyByTaskId: [String: String] {
        var map = libraryCounterFamilies
        for payload in pendingTasks.values {
            if payload.task.type == .counting {
                map[payload.task.id] = payload.task.sharedCounterId ?? payload.task.id
            }
            for child in payload.childTasks where child.type == .counting {
                map[child.id] = child.sharedCounterId ?? child.id
            }
        }
        return map
    }

    /// Container hook: rebuild the library half of the family map after a
    /// library (re)load.
    func refreshCounterFamilies(libraryTasks: [Task]) {
        libraryCounterFamilies = BoardSources.buildCounterFamilyMap(libraryTasks)
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
        refreshCompoundChildren()
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
            doneTaskIds: info.doneTaskIds,
            windowCountByTaskId: info.windowCountByTaskId,
            sourceWindow: info.sourceWindow
        )
        sources.append(BoardSource(sourceId: boardId, kind: .board))
        // §Member rules (B3, RC4) — a board pulled in THIS session seeds its
        // counting members' REMAINING target on a one-off board. iOS resolves
        // the supply synchronously right here, so the seeding happens at pull
        // time; a source HYDRATED from a resumed draft / edited record never
        // passes through `pullBoard`, which is what keeps its saved rules
        // (the person's own state) from being silently rewritten.
        prefillRemainingTargets(sourceId: boardId, info: info)
        refreshCompoundChildren()
        recomputeSelectionFromSources()
    }

    /// Remove a source row entirely (the row's ✕). Its supply leaves the
    /// selection; the manual layer is never touched.
    func removeSource(sourceId: String) {
        sources.removeAll { $0.sourceId == sourceId }
        supplyInfoBySourceId.removeValue(forKey: sourceId)
        expandedSourceIds.remove(sourceId)
        refreshCompoundChildren()
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
        // §Member rules (B3, RC14) exclusivity — a member that has just been
        // excluded keeps NO per-part state: re-including it later starts from
        // a clean split, not from whichever parts a past session suppressed.
        sources = BoardSources.pruneRulesForExcludedMember(
            sources, sourceId: sourceId, taskId: taskId
        )
        clampSourceMin(at: i)
        recomputeSelectionFromSources()
    }

    /// Library-sheet deselect of a source-supplied task: suppress it in
    /// EVERY supplying source (the sheet has no per-source scope — the old
    /// flat-removal global-suppress semantics).
    ///
    /// Membership is tested against the EXPANDED supplies, and HOW the id is
    /// suppressed depends on how it got there (§Member rules B3): a plain
    /// member goes into the source's `excludedTaskIds`, while a Split-up PART
    /// gets an `excluded: true` PART RULE on its parent compound — the
    /// pre-expansion supply never contains a `childTaskId`, so the old
    /// raw-supply test wrote nothing at all for a part and the selection
    /// recompute put the square straight back (a self-reverting control).
    /// The last included part is refused here too; callers driving a user
    /// gesture ask `BoardSources.canDeselectFromSources` first.
    private func excludeFromEverySupplier(_ taskId: String) {
        for supply in expandedSupplies {
            guard supply.supplyTaskIds.contains(taskId),
                  let i = sources.firstIndex(where: { $0.sourceId == supply.source.sourceId })
            else { continue }
            if let parentId = supply.partOf[taskId] {
                let partIds = (childrenByCompoundId[parentId] ?? []).map { $0.childTaskId }
                guard BoardSources.canSetPartExcluded(
                    rule: BoardSources.memberRule(for: parentId, in: sources[i]),
                    partIds: partIds,
                    childId: taskId,
                    excluded: true
                ) else { continue }
                sources[i] = BoardSources.withPartRule(
                    sources[i],
                    taskId: parentId,
                    childId: taskId,
                    patch: BoardSources.PartRulePatch(excluded: .set(true))
                )
            } else if !sources[i].excludedTaskIds.contains(taskId) {
                sources[i].excludedTaskIds.append(taskId)
            }
            clampSourceMin(at: i)
        }
    }

    /// Internal (not private): the §Member rules actions in
    /// `BoardWizardViewModel+MemberRules.swift` re-clamp through it too.
    func clampSourceMin(at index: Int) {
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
    ///
    /// - Parameter taskId: The task to add to, or remove from, the
    ///   hand-added layer.
    /// - Returns: `false` when the toggle was REFUSED and nothing changed
    ///   (the last included part of a Split-up compound — see
    ///   ``BoardSources/canDeselectFromSources(supplies:childrenByCompoundId:taskId:)``);
    ///   `true` on every applied toggle. Mirrors `setPartExcluded`, and lets
    ///   the Tasks step skip its "Removed …" toast on a refusal.
    @discardableResult
    func toggleTaskSelection(_ taskId: String) -> Bool {
        if selectedTaskIds.contains(taskId) {
            // §Member rules (B3) — a deselect the expansion would REFUSE (the
            // last included part of a Split-up compound) must change nothing:
            // dropping the id and letting the selection recompute restore it
            // is a self-reverting control. Checked before any state write.
            //
            // Final review I1 — and it REPORTS the refusal, because the row
            // stays on the board: a "Removed …" toast would contradict the
            // screen, and its Undo calls `restoreToPool`, which writes the id
            // into `manualTaskIds` and re-provenances a source-supplied part
            // as hand-added.
            guard BoardSources.canDeselectFromSources(
                supplies: expandedSupplies,
                childrenByCompoundId: childrenByCompoundId,
                taskId: taskId
            ) else { return false }
            manualTaskIds.remove(taskId)
            pendingTasks.removeValue(forKey: taskId)
            stagedEdits.removeValue(forKey: taskId)
            poolOrder.removeAll { $0 == taskId }
            // §Member rules (B3) — the dice leave with the task, or the stale
            // entry rides into the draft blob / the repeating record forever.
            manualTaskVary = BoardSources.pruneManualVary(manualTaskVary, taskId: taskId)
            excludeFromEverySupplier(taskId)
            recomputeSelectionFromSources()
        } else {
            manualTaskIds.insert(taskId)
            if !poolOrder.contains(taskId) { poolOrder.append(taskId) }
            recomputeSelectionFromSources()
        }
        return true
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
                    ?? supplyInfoBySourceId[source.sourceId]?.displayName
                let fallbackName = (name?.isEmpty == false) ? name! : "Deleted pool"
                supplyInfoBySourceId[source.sourceId] = WizardSourceSupply(
                    displayName: fallbackName,
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
                        doneTaskIds: info.doneTaskIds,
                        windowCountByTaskId: info.windowCountByTaskId,
                        sourceWindow: info.sourceWindow
                    )
                } else {
                    let kept = supplyInfoBySourceId[source.sourceId]?.displayName
                    supplyInfoBySourceId[source.sourceId] = WizardSourceSupply(
                        displayName: (kept?.isEmpty == false) ? kept! : "Deleted board",
                        rawSupplyTaskIds: [],
                        doneTaskIds: []
                    )
                }
            }
        }
        // §Member rules (B3, RC7) — the Split-up expansion reads the live
        // links; reload them alongside the supplies they belong to. NOTE: a
        // refresh never prefills (RC4) — only a pull does.
        refreshCompoundChildren()
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
                    displayName: poolsById[source.sourceId]?.name ?? "Deleted pool",
                    rawSupplyTaskIds: BoardSources.poolSourceSupplyById(
                        source.sourceId, poolsById: poolsById, tasksById: tasksById
                    ),
                    doneTaskIds: []
                )
            case .board:
                if let info = (try? database.fetchBoardSourceSupply(boardId: source.sourceId)) ?? nil {
                    // §Member rules (B3) — the RC4/RC5 fields ride along HERE
                    // too, not just on `pullBoard`/`refreshSourceSupplies`: a
                    // resumed draft or an edited record takes ONLY this path
                    // on open, and a rule row rendered against a nil
                    // `sourceWindow` would show the bare goal and then
                    // silently change to the pro-rated number once the view's
                    // first refresh landed. (The RC4 PREFILL is still not run
                    // here — a hydrated source's saved rules are the person's
                    // own state; only `pullBoard` seeds.)
                    supplyInfo[source.sourceId] = WizardSourceSupply(
                        displayName: info.displayName,
                        rawSupplyTaskIds: info.supplyTaskIds,
                        doneTaskIds: info.doneTaskIds,
                        windowCountByTaskId: info.windowCountByTaskId,
                        sourceWindow: info.sourceWindow
                    )
                } else {
                    supplyInfo[source.sourceId] = WizardSourceSupply(
                        displayName: "Deleted board", rawSupplyTaskIds: [], doneTaskIds: []
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

