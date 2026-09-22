import Foundation

/// Board Sources §Member rules (B3, docs/BOARD_SOURCES.md) — the wizard's
/// RULE-EDITING layer: the seven actions a person drives from the Sources
/// sheet, plus the two supporting loads (`refreshCompoundChildren`,
/// `prefillRemainingTargets`).
///
/// The rules themselves live ON the sources (`BoardSource.memberRules`), so
/// every action writes through the shared immutable setters
/// (`BoardSources.withMemberRule` / `withPartRule`) — which is what keeps
/// the "omit when empty" serialisation a rule-less source promises: patching
/// a rule back to its defaults leaves nothing behind, so the row encodes
/// without a `memberRules` key at all.
///
/// Two of the seven change the SUPPLY rather than just a number —
/// `setMemberSplit` (a compound becomes N parts instead of 1 square) and
/// `setPartExcluded` (one of those parts drops out) — so both re-clamp every
/// range and recompute the selection afterwards (RC14), exactly like
/// `setSourceFilter` does.
///
/// Action names are the cross-platform contract: these mirror web's
/// `useWizardMemberRules` verbatim.
extension BoardWizardViewModel {

    // MARK: - Supporting state loads

    /// The id→task slice ``BoardSources/applyMemberRules(_:childrenByCompoundId:tasksById:)``
    /// reads. It consults `type` and nothing else, to answer one question:
    /// "is this supplied member a compound with children?".
    /// `childrenByCompoundId` is loaded from COMPOUND members ONLY (see
    /// ``refreshCompoundChildren()``), so its key set already IS that answer
    /// — marking each key as `.compound` is equivalent to handing over the
    /// live rows, without the wizard keeping a second copy of the library in
    /// memory (and without a third stored property on the frozen
    /// `BoardWizardViewModel.swift`).
    var supplyTasksById: [String: Task] {
        var map: [String: Task] = [:]
        for id in childrenByCompoundId.keys {
            map[id] = Task(
                id: id,
                userId: "",
                title: "",
                type: .compound,
                totalCompletions: 0,
                totalInstances: 0,
                createdAt: "",
                updatedAt: "",
                version: 1,
                isDeleted: false
            )
        }
        return map
    }

    /// Reload the live `compound_children` links a Split-up expansion can
    /// name: every COMPOUND member any pulled source supplies, plus this
    /// session's pending (not-yet-persisted) compounds' own links — a
    /// wizard-created compound must be splittable too.
    ///
    /// ONE read transaction (`AppDatabase.fetchCompoundChildren(forCandidateTaskIds:)`
    /// — the type filter and the B2 batched children fetch share it) rather
    /// than a query per compound, and an early return when there is nothing
    /// to read at all (every plain "Create board" open). A read failure
    /// leaves the map empty, which makes every split rule stale-inert — the
    /// source still supplies its members un-split; nothing blocks.
    ///
    /// Web's `useWizardCompoundChildren` ends with a third layer,
    /// `overlayCompoundChildrenWithStagedEdits`. iOS omits it deliberately:
    /// `recomputeSelectionFromSources` purges a compound's staged edit the
    /// instant it leaves the selection, and splitting a compound is exactly
    /// what makes it leave — so a SPLIT compound can never carry a staged
    /// edit here. If a future surface keeps staged edits alive across a
    /// split, this is the line that has to change.
    func refreshCompoundChildren() {
        var supplied: [String] = []
        var seen = Set<String>()
        for source in sources {
            for id in supplyInfoBySourceId[source.sourceId]?.rawSupplyTaskIds ?? [] {
                if seen.insert(id).inserted { supplied.append(id) }
            }
        }
        guard !supplied.isEmpty || !pendingTasks.isEmpty else {
            childrenByCompoundId = [:]
            return
        }
        var links = (try? database.fetchCompoundChildren(forCandidateTaskIds: supplied)) ?? [:]
        for payload in pendingTasks.values where !payload.childLinks.isEmpty {
            // `childLinks` are assembled in `childIndex` order by the create
            // form — used as-is, matching web's `useWizardCompoundChildren`.
            links[payload.task.id] = payload.childLinks
        }
        childrenByCompoundId = links
    }

    /// §Member rules (B3, RC4) — the window a one-off prefill pro-rates a
    /// board-pulled counting target AGAINST. Only `nominalWindowDays` reads
    /// it, and that reads start/end for CUSTOM alone (as the `YYYY-MM-DD`
    /// prefix), so the raw custom-date inputs are interchangeable with the
    /// resolved ISO strings the persist path would produce. Web twin:
    /// `prefillTargetWindow` in `useBoardWizard.ts`.
    var prefillTargetWindow: BoardSources.BoardWindow {
        BoardSources.BoardWindow(
            timeframe: timeframe,
            startDate: customStartDate.isEmpty ? nil : customStartDate,
            endDate: customEndDate.isEmpty ? nil : customEndDate
        )
    }

    /// §Member rules (B3, RC4) — seed one BOARD source's counting members
    /// with their remaining target for a ONE-OFF board, PRO-RATED to that
    /// board's window: `prefilledOneOffTarget(goal:windowCount:sourceWindow:targetWindow:)`,
    /// where `windowCount` is the progress that member already has in the
    /// SOURCE board's window. Pull a 3-of-10-done weekly counter onto a fresh
    /// one-off weekly board and the rule is seeded at 7; pull an untouched
    /// "Run 30 miles a month" onto a one-off DAILY board and it is seeded at
    /// `ceil(30 × 1 / 30) = 1`, not 30 (owner ruling 2026-09-21 — the fix for
    /// "defaults for Counter tasks pulled in from boards do not adjust with
    /// timeframe"). Same-length windows are unaffected: `autoTarget` returns
    /// the remaining amount verbatim when the target window is at least as
    /// long as the source's.
    ///
    /// Writing an EXPLICIT target here is why opening the shared `fromBoard`
    /// gate alone was not enough: `resolveTarget` is `explicit ?? auto`, so a
    /// one-off board never reaches the auto branch for a member this pass has
    /// seeded — the seeded number has to be the pro-rated one.
    ///
    /// Only one-off boards seed — a recurring board leaves `target` absent so
    /// each spawned window auto-targets against its own window instead. Never
    /// overwrites an existing `target` (a rule the person authored, or one a
    /// resumed draft carries), and skips non-counting / goal-less members.
    ///
    /// Called from ``pullBoard(boardId:)`` alone: iOS resolves a board
    /// supply synchronously at pull time, so — unlike web, which has to fence
    /// off its async re-resolve with a seeded-ids set — a source HYDRATED
    /// from a resumed draft or an edited record simply never reaches here.
    ///
    /// - Parameters:
    ///   - sourceId: The board source just pulled.
    ///   - info: Its freshly-resolved supply (RC4 counts + RC5 window).
    func prefillRemainingTargets(sourceId: String, info: BoardSourceSupplyInfo) {
        guard editingTemplateId == nil, !isRecurring else { return }
        guard let index = sources.firstIndex(where: { $0.sourceId == sourceId }) else { return }
        let tasks = (try? database.fetchTasks(ids: info.supplyTaskIds)) ?? []
        let tasksById = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
        var source = sources[index]
        for id in info.supplyTaskIds {
            guard let task = tasksById[id], task.type == .counting else { continue }
            guard let goal = task.maxCount, goal >= 1 else { continue }
            guard BoardSources.memberRule(for: id, in: source).target == nil else { continue }
            source = BoardSources.withMemberRule(
                source,
                taskId: id,
                patch: BoardSources.MemberRulePatch(
                    target: .set(BoardSources.prefilledOneOffTarget(
                        goal: goal,
                        windowCount: info.windowCountByTaskId[id] ?? 0,
                        sourceWindow: info.sourceWindow,
                        targetWindow: prefillTargetWindow
                    ))
                )
            )
        }
        sources[index] = source
    }

    // MARK: - Member rules

    /// Set (or clear, with `nil`) a counting member's explicit target.
    ///
    /// - Parameters:
    ///   - sourceId: The row the member was pulled through.
    ///   - taskId: The member's task id.
    ///   - target: The explicit target, or nil to fall back to the auto/goal.
    func setMemberTarget(sourceId: String, taskId: String, target: Int?) {
        sources = BoardSources.withMemberRuleInSource(
            sources,
            sourceId: sourceId,
            taskId: taskId,
            patch: BoardSources.MemberRulePatch(target: target.map { .set($0) } ?? .clear)
        )
    }

    /// Set a counting member's (or a One-square compound's) dice level.
    ///
    /// - Parameters:
    ///   - sourceId: The row the member was pulled through.
    ///   - taskId: The member's task id.
    ///   - level: The new dice level (`.off` stores as an absence).
    func setMemberVary(sourceId: String, taskId: String, level: VaryLevel) {
        sources = BoardSources.withMemberRuleInSource(
            sources,
            sourceId: sourceId,
            taskId: taskId,
            patch: BoardSources.MemberRulePatch(vary: .set(level))
        )
    }

    /// Flip a compound member between One square and Split up. This changes
    /// the SUPPLY (a split member contributes its parts instead of itself),
    /// so ranges re-clamp and the selection recomputes — RC14.
    ///
    /// - Parameters:
    ///   - sourceId: The row the member was pulled through.
    ///   - taskId: The compound member's task id.
    ///   - split: True for Split up, false for One square.
    func setMemberSplit(sourceId: String, taskId: String, split: Bool) {
        sources = BoardSources.withMemberRuleInSource(
            sources,
            sourceId: sourceId,
            taskId: taskId,
            patch: BoardSources.MemberRulePatch(split: .set(split))
        )
        commitSupplyChange()
    }

    // MARK: - Part rules

    /// Include/exclude one part of a split compound. REFUSES to exclude the
    /// last included part (a split member always contributes at least one
    /// square) — returns false and changes nothing, rather than writing a
    /// rule the expansion's own last-part guard would then ignore.
    /// Supply-changing, so ranges re-clamp and the selection recomputes.
    ///
    /// - Parameters:
    ///   - sourceId: The row the parent member was pulled through.
    ///   - taskId: The parent compound member's task id.
    ///   - childId: The part's `compound_children.childTaskId`.
    ///   - excluded: The requested state.
    /// - Returns: False when the toggle was refused (nothing changed).
    @discardableResult
    func setPartExcluded(
        sourceId: String,
        taskId: String,
        childId: String,
        excluded: Bool
    ) -> Bool {
        guard let source = sources.first(where: { $0.sourceId == sourceId }) else { return false }
        let partIds = (childrenByCompoundId[taskId] ?? []).map { $0.childTaskId }
        guard BoardSources.canSetPartExcluded(
            rule: BoardSources.memberRule(for: taskId, in: source),
            partIds: partIds,
            childId: childId,
            excluded: excluded
        ) else { return false }
        sources = BoardSources.withPartRuleInSource(
            sources,
            sourceId: sourceId,
            taskId: taskId,
            childId: childId,
            patch: BoardSources.PartRulePatch(excluded: .set(excluded))
        )
        commitSupplyChange()
        return true
    }

    /// Set (or clear, with `nil`) a counting part's explicit target.
    ///
    /// - Parameters:
    ///   - sourceId: The row the parent member was pulled through.
    ///   - taskId: The parent compound member's task id.
    ///   - childId: The part's `compound_children.childTaskId`.
    ///   - target: The explicit target, or nil to fall back to the auto/goal.
    func setPartTarget(sourceId: String, taskId: String, childId: String, target: Int?) {
        sources = BoardSources.withPartRuleInSource(
            sources,
            sourceId: sourceId,
            taskId: taskId,
            childId: childId,
            patch: BoardSources.PartRulePatch(target: target.map { .set($0) } ?? .clear)
        )
    }

    /// Set a counting part's dice level.
    ///
    /// - Parameters:
    ///   - sourceId: The row the parent member was pulled through.
    ///   - taskId: The parent compound member's task id.
    ///   - childId: The part's `compound_children.childTaskId`.
    ///   - level: The new dice level (`.off` stores as an absence).
    func setPartVary(sourceId: String, taskId: String, childId: String, level: VaryLevel) {
        sources = BoardSources.withPartRuleInSource(
            sources,
            sourceId: sourceId,
            taskId: taskId,
            childId: childId,
            patch: BoardSources.PartRulePatch(vary: .set(level))
        )
    }

    // MARK: - Hand-added layer

    /// Set a HAND-ADDED counter's dice level (not a source member). A
    /// non-counting task is a no-op — the guard lives in the STATE layer, not
    /// only in the UI, because a level written for a normal / compound /
    /// achievement task would serialise onto the record and read as authored
    /// intent forever.
    ///
    /// The task is looked up in the library map first and in this session's
    /// `pendingTasks` second: a counter created inside the wizard's New Task
    /// sheet is hand-added and dice-able before it is ever written.
    ///
    /// - Parameters:
    ///   - taskId: The hand-added task.
    ///   - level: The new dice level (`.off` stores as an absence).
    func setManualVary(taskId: String, level: VaryLevel) {
        let task = pendingTasks[taskId]?.task
            ?? (try? database.fetchTasks(ids: [taskId]))?.first
        manualTaskVary = BoardSources.withManualVary(
            manualTaskVary, taskId: taskId, level: level, task: task
        )
    }

    // MARK: - Shared commit

    /// A rule edit that changed the SUPPLY (Split up, part exclusion):
    /// re-clamp every range against the new available counts and recompute
    /// the selection union, so ids that left purge their follow-on state —
    /// the same tail `setSourceFilter` / `refreshSourceSupplies` run (RC14).
    private func commitSupplyChange() {
        for i in sources.indices { clampSourceMin(at: i) }
        recomputeSelectionFromSources()
    }
}
