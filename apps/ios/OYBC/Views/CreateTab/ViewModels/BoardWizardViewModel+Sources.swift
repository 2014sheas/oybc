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
    /// Board sources only — the source still exists but resolved to NO
    /// board for the window being built (owner ruling 2026-09-24: a series
    /// with no instance open now, or an ended/sealed one-off). It supplies nothing (capacity 0 from it) and its row
    /// subtitle reads "No board for this window yet". Distinct from a dead
    /// source ("Deleted board"), which leaves this false. Web twin:
    /// `WizardSourceSupply.noBoardForWindow`.
    var noBoardForWindow: Bool = false
}

extension WizardSourceSupply {
    /// Map a window-aware board-supply resolution into the wizard's cache
    /// entry: `.live` → the resolved supply; `.dead` → "Deleted board" (or
    /// the last-known name when the caller has one); `.noWindow` → the
    /// stored board's name, an empty supply and `noBoardForWindow`. Web twin:
    /// `boardSupplyEntryForResolution`.
    ///
    /// - Parameters:
    ///   - resolution: From `AppDatabase.fetchOpenBoardSourceSupply`.
    ///   - keptName: A previously shown name to keep for a dead source.
    init(resolution: AppDatabase.BoardSourceSupplyResolution, keptName: String? = nil) {
        switch resolution {
        case .live(let info):
            self.init(
                displayName: info.displayName,
                rawSupplyTaskIds: info.supplyTaskIds,
                doneTaskIds: info.doneTaskIds,
                windowCountByTaskId: info.windowCountByTaskId,
                sourceWindow: info.sourceWindow
            )
        case .noWindow(let name):
            self.init(
                displayName: name, rawSupplyTaskIds: [], doneTaskIds: [], noBoardForWindow: true
            )
        case .dead:
            self.init(
                displayName: (keptName?.isEmpty == false) ? keptName! : "Deleted board",
                rawSupplyTaskIds: [],
                doneTaskIds: []
            )
        }
    }
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
        Self.expandedSupplies(
            sources: sources,
            supplyInfo: supplyInfoBySourceId,
            childrenByCompoundId: childrenByCompoundId,
            tasksById: supplyTasksById
        )
    }

    /// The expansion over any sources state — the one code path both the
    /// live wizard (``expandedSupplies``) and a saved draft's
    /// ``resolveDraftCapacity(board:database:)`` go through, so the drafts
    /// list and the reopened wizard can't disagree on a draft's pool size.
    static func expandedSupplies(
        sources: [BoardSource],
        supplyInfo: [String: WizardSourceSupply],
        childrenByCompoundId: [String: [CompoundChild]],
        tasksById: [String: Task]
    ) -> [BoardSources.ExpandedSupply] {
        let raw = sources.map { source -> BoardSources.Supply in
            let info = supplyInfo[source.sourceId]
            let ids = BoardSources.availableSupplyIds(
                source: source,
                supplyTaskIds: info?.rawSupplyTaskIds ?? [],
                doneTaskIds: info?.doneTaskIds ?? []
            )
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
            tasksById: tasksById
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

    /// The done-filter a NEWLY minted source row starts on — owner
    /// directive 2026-09-19: "Not done yet" is the default, so pulling a
    /// board supplies what is still outstanding rather than re-dealing
    /// squares the person has already finished. Web twin:
    /// `newSourceFilter(kind:)` in `wizardSourcesLogic.ts`.
    ///
    /// KIND-SCOPED, deliberately. The done-filter is a **boards-only**
    /// field by contract (docs/BOARD_SOURCES.md §The model:
    /// `filter: 'all' | 'todo'  // boards only; pools always 'all'`), so
    /// only `.board` takes the `.todo` default; a pool mints `.all`,
    /// exactly like the legacy-trio decode
    /// `BoardSources.sourcesFromMixFields` and `BoardSource.init`'s own
    /// default. Minting a pool row on `.todo` reads as inert today (every
    /// filter read on both platforms is kind-scoped) but it persists data
    /// that contradicts the contract, and the first kind-blind read anyone
    /// adds would silently done-filter pool supply.
    ///
    /// Deliberately scoped to CREATION: sources already stored on a board
    /// or a `RecurringBoardTemplate` keep whatever filter they were saved
    /// with, and nothing coerces a decoded row.
    ///
    /// ONE definition per platform: every iOS mint path (`pullPool`,
    /// `pullBoard`, the core-defaults prefill in `BoardWizardViewModel`)
    /// asks this function rather than writing a literal.
    ///
    /// - Parameter kind: Which kind of source is being minted.
    /// - Returns: `.todo` for a board, `.all` for a pool.
    static func newSourceFilter(for kind: BoardSource.Kind) -> BoardSource.Filter {
        kind == .board ? .todo : .all
    }

    /// Pull a pool in as a `[0, all]` source row. No-op when soft-deleted
    /// or already pulled. The saved `Pool` is never modified.
    ///
    /// Takes the `newSourceFilter(for:)` default like every freshly minted
    /// row, which for a pool is `.all` — pools are always `.all` by
    /// contract.
    func pullPool(_ pool: Pool, tasksById: [String: Task]) {
        guard !pool.isDeleted, !sources.contains(where: { $0.sourceId == pool.id }) else { return }
        supplyInfoBySourceId[pool.id] = WizardSourceSupply(
            displayName: pool.name,
            rawSupplyTaskIds: BoardSources.poolSourceSupplyById(
                pool.id, poolsById: [pool.id: pool], tasksById: tasksById
            ),
            doneTaskIds: []
        )
        sources.append(BoardSource(sourceId: pool.id, kind: .pool, filter: Self.newSourceFilter(for: .pool)))
        refreshCompoundChildren()
        recomputeSelectionFromSources()
    }

    /// Pull a board in as a `[0, all]` source row on the
    /// `newSourceFilter(for:)` default, which for a board is `.todo`
    /// ("Not done yet"). No-op when the board is
    /// missing/soft-deleted or already pulled. The source board is never
    /// modified.
    ///
    /// No range clamp is needed even though `.todo` shrinks the available
    /// count: `[0, all]` is the one range valid against ANY supply
    /// (`clampSourceMin` leaves `min == 0` alone, and a nil max is the
    /// live-availability latch), so a row can't be minted wider than its
    /// filtered supply. Every later filter/exclude/range change still
    /// re-clamps as before.
    func pullBoard(boardId: String) {
        guard !sources.contains(where: { $0.sourceId == boardId }) else { return }
        // Owner ruling 2026-09-24 — sources are open boards. A `.noWindow`
        // source (no board open right now) is still pulled — its row reads
        // "No board for this window yet"; only a dead one isn't.
        guard let resolution = try? database.fetchOpenBoardSourceSupply(boardId: boardId),
              resolution != .dead else {
            return
        }
        supplyInfoBySourceId[boardId] = WizardSourceSupply(resolution: resolution)
        sources.append(BoardSource(sourceId: boardId, kind: .board, filter: Self.newSourceFilter(for: .board)))
        // §Member rules (B3, RC4) — a board pulled in THIS session seeds its
        // counting members' REMAINING target on a one-off board. iOS resolves
        // the supply synchronously right here, so the seeding happens at pull
        // time; a source HYDRATED from a resumed draft / edited record never
        // passes through `pullBoard`, which is what keeps its saved rules
        // (the person's own state) from being silently rewritten.
        if let info = resolution.info {
            prefillRemainingTargets(sourceId: boardId, info: info)
        } else {
            // No board open yet — the prefill is owed until it resolves live
            // (`refreshSourceSupplies`).
            pendingPrefillSourceIds.insert(boardId)
        }
        refreshCompoundChildren()
        recomputeSelectionFromSources()
    }

    /// Remove a source row entirely (the row's ✕). Its supply leaves the
    /// selection; the manual layer is never touched.
    func removeSource(sourceId: String) {
        sources.removeAll { $0.sourceId == sourceId }
        supplyInfoBySourceId.removeValue(forKey: sourceId)
        expandedSourceIds.remove(sourceId)
        pendingPrefillSourceIds.remove(sourceId)
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
                let resolution = (try? database.fetchOpenBoardSourceSupply(
                    boardId: source.sourceId
                )) ?? .dead
                supplyInfoBySourceId[source.sourceId] = WizardSourceSupply(
                    resolution: resolution,
                    keptName: supplyInfoBySourceId[source.sourceId]?.displayName
                )
                // A source pulled while it had no board open still owes its
                // RC4 prefill — run it the first time it resolves live.
                if let info = resolution.info,
                   pendingPrefillSourceIds.remove(source.sourceId) != nil {
                    prefillRemainingTargets(sourceId: source.sourceId, info: info)
                }
            }
        }
        // §Member rules (B3, RC7) — the Split-up expansion reads the live
        // links; reload them alongside the supplies they belong to. NOTE: a
        // refresh never prefills (RC4) — only a pull does, or a pull that is
        // still owed its prefill (`pendingPrefillSourceIds`, above).
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
        database: AppDatabase,
        now: Date = AppDatabase.sourceClock()
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
                // §Member rules (B3) — the RC4/RC5 fields ride along HERE
                // too, not just on `pullBoard`/`refreshSourceSupplies`: a
                // resumed draft or an edited record takes ONLY this path on
                // open, and a rule row rendered against a nil `sourceWindow`
                // would show the bare goal and then silently change to the
                // pro-rated number once the view's first refresh landed. (The
                // RC4 PREFILL is still not run here — a hydrated source's
                // saved rules are the person's own state; only `pullBoard`
                // seeds.) The board open now (owner ruling 2026-09-24).
                let resolution = (try? database.fetchOpenBoardSourceSupply(
                    boardId: source.sourceId, now: now
                )) ?? .dead
                supplyInfo[source.sourceId] = WizardSourceSupply(resolution: resolution)
            }
        }

        var union = Set<String>()
        for source in rawSources {
            let info = supplyInfo[source.sourceId]
            let raw = BoardSources.availableSupplyIds(
                source: source,
                supplyTaskIds: info?.rawSupplyTaskIds ?? [],
                doneTaskIds: info?.doneTaskIds ?? []
            )
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

// MARK: - Saved-draft pool size (drafts list + resume step)

extension BoardWizardViewModel {
    /// A saved draft's honest pool size — the SAME number the wizard's
    /// header and Step-2 gate (``sourceCapacity``) show once the draft is
    /// reopened (2026-09 audit T2, docs/BOARD_SOURCES.md §Selection step 3).
    ///
    /// Reads the blob's canonical `sources` (+ `manualTaskIds`) through
    /// ``hydrateSourcesState(sources:manualTaskIds:database:now:)`` — the exact
    /// hydration the wizard runs on open — never the retired pool-mix
    /// mirror (`poolIds`/`removedTaskIds`), which drops board-kind sources
    /// and every min/max range. A v1 blob with no `sources` is already
    /// mapped forward by `RecurringDraftMixPayload.decoded(from:)`
    /// (`sourcesFromMixFields`, the `[0, all]` rule), so no legacy branch is
    /// needed here.
    ///
    /// The count is `BoardSources.computeSourceCapacity` (the
    /// `computeAchievablePoolSize` dry-run) over ``expandedSupplies(sources:supplyInfo:childrenByCompoundId:tasksById:)``:
    /// excludes, the `'todo'` filter, Split-up expansion, counter-family
    /// exclusivity and the chosen center pinned. Fetch failures degrade to
    /// empty supplies (0), matching the hydration's posture.
    ///
    /// Web twin: `resolveDraftCapacity` (`pages/createHub/resolveDraftCapacity.ts`).
    ///
    /// - Parameters:
    ///   - board: The draft board; only its blob and center fields are read.
    ///   - database: The database to resolve supplies against.
    ///   - now: The instant a source board's "is it open" is judged against.
    /// - Returns: The achievable pool size.
    static func resolveDraftCapacity(board: Board, database: AppDatabase, now: Date = AppDatabase.sourceClock()) -> Int {
        let mix = RecurringDraftMixPayload.decoded(from: board.recurringDraftMix)
        // Owner ruling 2026-09-24 — a source supplies from its board open
        // NOW (the reopened wizard, its Preview and persist use the same
        // clock), so an ended source supplies nothing here too.
        let hydrated = hydrateSourcesState(
            sources: mix.sources ?? [],
            manualTaskIds: mix.manualTaskIds,
            database: database,
            now: now
        )
        var supplied: [String] = []
        var seen = Set<String>()
        for source in hydrated.sources {
            for id in hydrated.supplyInfo[source.sourceId]?.rawSupplyTaskIds ?? []
            where seen.insert(id).inserted {
                supplied.append(id)
            }
        }
        // §Member rules (B3, RC7) — a Split-up member counts as its parts.
        let childrenByCompoundId =
            (try? database.fetchCompoundChildren(forCandidateTaskIds: supplied)) ?? [:]
        var referenced = seen.union(mix.manualTaskIds)
        for links in childrenByCompoundId.values {
            for link in links { referenced.insert(link.childTaskId) }
        }
        let tasks = (try? database.fetchTasks(ids: Array(referenced))) ?? []
        let tasksById = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        let supplies = expandedSupplies(
            sources: hydrated.sources,
            supplyInfo: hydrated.supplyInfo,
            childrenByCompoundId: childrenByCompoundId,
            tasksById: tasksById
        ).map { $0.asSupply }
        return BoardSources.computeSourceCapacity(
            supplies,
            manualTaskIds: mix.manualTaskIds,
            counterFamilyByTaskId: BoardSources.buildCounterFamilyMap(tasks),
            pinnedTaskId: board.centerSquareType == .chosen ? board.centerTaskId : nil
        ).capacity
    }
}

/// What the Tasks step's pool/board pickers read: the user's pools, their
/// recurring templates, and the "Add from a pool or board" sheet's BOARDS
/// rows (see ``BoardWizardViewModel/loadSourceCatalog(userId:)``).
struct WizardSourceCatalog {
    var pools: [Pool]
    var templates: [RecurringBoardTemplate]
    var boardEntries: [RisoSourcePickerSheetView.BoardEntry]
}

extension BoardWizardViewModel {

    // MARK: - Sources-sheet catalog load

    /// Load the Sources sheet's catalog off the main thread, through this
    /// view-model's injected `database`.
    ///
    /// Run it from a structured context (the view's `.task`) so leaving the
    /// wizard cancels it: each read is checked for cancellation, and a
    /// cancelled load throws `CancellationError` instead of returning stale
    /// data for a screen that is gone.
    ///
    /// - Parameter userId: The owner whose pools/templates/boards to read.
    /// - Returns: The catalog.
    /// - Throws: `CancellationError` when cancelled, or any GRDB read error.
    func loadSourceCatalog(userId: String) async throws -> WizardSourceCatalog {
        let db = database
        try _Concurrency.Task.checkCancellation()
        let pools = try await _Concurrency.Task.detached(priority: .userInitiated) {
            try db.fetchPools(userId: userId)
        }.value
        try _Concurrency.Task.checkCancellation()
        let templates = try await _Concurrency.Task.detached(priority: .userInitiated) {
            try db.fetchRecurringBoardTemplates(userId: userId)
        }.value
        try _Concurrency.Task.checkCancellation()
        // Board Sources P2 — the BOARDS rows walk every active board
        // (batched reads), so they load here, off-main, alongside pools.
        let entries = try await _Concurrency.Task.detached(priority: .userInitiated) {
            try db.fetchSourceSheetBoardEntries(userId: userId).map {
                RisoSourcePickerSheetView.BoardEntry(
                    board: $0.board,
                    squares: $0.info.supplyTaskIds.count,
                    done: $0.info.doneTaskIds.count
                )
            }
        }.value
        try _Concurrency.Task.checkCancellation()
        return WizardSourceCatalog(pools: pools, templates: templates, boardEntries: entries)
    }
}
