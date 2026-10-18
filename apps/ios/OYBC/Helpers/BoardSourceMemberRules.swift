import Foundation

// MARK: - Board Sources §Member rules (B1)
//
// Swift twin of `packages/shared/src/algorithms/memberRules.ts`, ported
// function-for-function (same names, same branch order, same clamps, same
// rng consumption). Pinned by the byte-identical vector fixture
// (`OYBCTests/Fixtures/memberRuleVectors.json` ↔
// `packages/shared/tests/fixtures/memberRuleVectors.json`) — a change in
// either implementation is a change in two places.
//
// Pure arithmetic + planning: the nominal window length of a timeframe, the
// pro-rated auto target when a counting member crosses windows, the vary
// (dice) range and its seeded roll, Split-up supply expansion, and the plan
// that decides — per selected id — whether it is placed as-is or replaced by
// a window-stamped derived counter / derived compound.
//
// Nothing here is wired into a write path yet: B1 ships the vocabulary and
// the arithmetic, B2 persists the drafts these produce. No persistence, no
// side effects — the only non-determinism is the injected `rng`.
//
// Split into its own file (rather than appended to `BoardSources.swift`) to
// keep both files under the 1000-line god-file guardrail; the call surface
// is still `BoardSources.planDerivedTasks(...)` either way.
extension BoardSources {

    // MARK: - Window arithmetic

    /// UTC-anchored `Calendar` — the day arithmetic below must never use
    /// local time, or a DST boundary inside a CUSTOM span could shave or
    /// add a day relative to the TS twin's `Date.UTC` math.
    private static let utcCalendar: Calendar = {
        var calendar = Calendar(identifier: .gregorian)
        calendar.timeZone = TimeZone(identifier: "UTC")!
        return calendar
    }()

    /// UTC day index of an ISO date's `YYYY-MM-DD` prefix.
    ///
    /// - Parameter iso: An ISO8601 date or date-time string.
    /// - Returns: Whole days since the epoch, or `nil` if the prefix doesn't parse.
    private static func dayNumber(_ iso: String) -> Int? {
        let characters = Array(iso.prefix(10))
        // Mirrors the TS twin's `/^(\d{4})-(\d{2})-(\d{2})/` — a lenient
        // DateFormatter would accept "2026-9-1", which TS rejects.
        guard characters.count == 10, characters[4] == "-", characters[7] == "-" else { return nil }
        for (index, character) in characters.enumerated() where index != 4 && index != 7 {
            guard character.isASCII, character.isNumber else { return nil }
        }
        guard let year = Int(String(characters[0..<4])),
              let month = Int(String(characters[5..<7])),
              let day = Int(String(characters[8..<10]))
        else { return nil }
        var components = DateComponents()
        components.year = year
        components.month = month
        components.day = day
        guard let date = utcCalendar.date(from: components) else { return nil }
        return Int((date.timeIntervalSince1970 / 86_400).rounded(.down))
    }

    /// Nominal length of a timeframe window in days. `.custom` = inclusive
    /// calendar span of the `YYYY-MM-DD` prefixes (UTC arithmetic — never
    /// local-time subtraction); `.indefinite`, or `.custom` with a
    /// missing/unparseable bound, = `nil`.
    ///
    /// - Parameters:
    ///   - timeframe: The window's timeframe.
    ///   - startDate: `.custom` only — the window's inclusive first day.
    ///   - endDate: `.custom` only — the window's inclusive last day.
    /// - Returns: The nominal day count, or `nil` when it is not knowable.
    static func nominalWindowDays(
        _ timeframe: Timeframe,
        startDate: String? = nil,
        endDate: String? = nil
    ) -> Int? {
        switch timeframe {
        case .daily: return 1
        case .weekly: return 7
        case .monthly: return 30
        case .yearly: return 365
        case .custom:
            // Empty strings are falsy in the TS twin — treat them as absent.
            guard let startDate, !startDate.isEmpty,
                  let endDate, !endDate.isEmpty,
                  let first = dayNumber(startDate),
                  let last = dayNumber(endDate)
            else { return nil }
            return Swift.max(1, last - first + 1)
        case .indefinite:
            return nil
        }
    }

    /// Auto target for a counting member pulled from a board source onto a
    /// board with a different window: the member's goal pro-rated by the
    /// window ratio, rounded up, never above the goal itself
    /// (docs/BOARD_SOURCES.md §Target math).
    ///
    /// Four explicit branches in order: unknown source window, unknown
    /// target window, a target window at least as long as the source's (no
    /// shrink), else the pro-rated ceiling — to the kind's step (0.1 for
    /// continuous).
    ///
    /// - Parameters:
    ///   - goal: The member's own `maxCount` (≥ 1 whole, > 0 continuous).
    ///   - sourceDays: Nominal days of the source board's window, or `nil`.
    ///   - targetDays: Nominal days of the board being assembled, or `nil`.
    ///   - kind: The member's count kind.
    /// - Returns: The auto target (one step ≥, ≤ `goal`).
    static func autoTarget(goal: CountValue, sourceDays: Int?, targetDays: Int?, kind: CountKind = .discrete) -> CountValue {
        guard let sourceDays else { return goal }
        guard let targetDays else { return goal }
        if targetDays >= sourceDays { return goal }
        // Double math throughout, as in the TS twin. Bit-identical in range.
        let prorated = ceilToCountStep(goal * Double(targetDays) / Double(sourceDays), kind: kind)
        return Swift.min(goal, prorated)
    }

    /// Vary level → the fraction of `t` the roll may move in either direction.
    private static func varyFraction(_ level: VaryLevel) -> Double {
        switch level {
        case .off: return 0
        case .little: return 0.2
        case .lot: return 0.5
        }
    }

    /// Inclusive `lo...hi` a rolled target may land in: symmetric ± `p`
    /// around the target (docs/BOARD_SOURCES.md §Member rules — "a little"
    /// = ±20 %, "a lot" = ±50 %). `t` is clamped to `1…goal` first (the
    /// stepper is goal-capped) and `lo` never drops below 1, but `hi` has NO
    /// ceiling — a roll may land above the target by up to `+p`, so a
    /// goal-10 member on "a little" rolls inside `8...12`. Overshooting the
    /// goal is a feature: `currentCount > maxCount` is valid in this product.
    /// (Fixed 2026-10-06 — the first implementation capped `hi` at the goal
    /// and only ever lowered.) "1" is the kind's step: continuous clamps and
    /// rounds in tenths (6.1 on "a little" → `4.9...7.3`). Only COMPUTED
    /// bounds are stepped (R17): continuous dice off, or a collapsed range,
    /// keeps `t` as-is (an off-step goal like 26.25 is never rewritten).
    ///
    /// Rounding is HALF-UP (`.rounded()` = `.toNearestOrAwayFromZero`),
    /// matching JS `Math.round` on the positive values this ever sees. Do
    /// NOT substitute `.toNearestOrEven` — the fixture pins ties.
    ///
    /// - Parameters:
    ///   - t: The pre-vary target.
    ///   - level: Vary level (`.off` = no spread).
    ///   - goal: The member's own `maxCount`; clamps `t`, never `hi`.
    ///   - kind: The member's count kind.
    /// - Returns: The inclusive range.
    static func varyRange(
        t: CountValue, level: VaryLevel, goal: CountValue, kind: CountKind = .discrete
    ) -> ClosedRange<CountValue> {
        let step = countTargetStep(kind)
        let clamped = Swift.min(Swift.max(step, t), goal)
        let fraction = varyFraction(level)
        let lo = Swift.max(step, roundToCountStep(clamped * (1 - fraction), kind: kind))
        let hi = roundToCountStep(clamped * (1 + fraction), kind: kind)
        // `lo <= hi` holds for every `goal >= step` (the only reachable input —
        // `goalOf` filters the rest); the outer `max` only stops a malformed
        // `goal < step` from trapping on an inverted ClosedRange, where the TS
        // twin would merely return a nonsense tuple.
        let upper = Swift.max(lo, hi)
        if !isWholeCountKind(kind), fraction == 0 || lo == upper {
            let q = quantizeCount(clamped)
            return q...q
        }
        return lo...upper
    }

    /// Uniform roll over the kind's steps inside ``varyRange(t:level:goal:kind:)``.
    /// `.off` never touches `rng`, and neither does a degenerate range
    /// (`lo == hi`); otherwise exactly ONE sample — which is what keeps a
    /// seeded sequence reproducible across platforms.
    ///
    /// - Parameters:
    ///   - t: The pre-vary target.
    ///   - level: Vary level (`.off` = no spread).
    ///   - goal: The member's own `maxCount`; clamps `t` (see ``varyRange(t:level:goal:kind:)``).
    ///   - rng: Uniform `[0, 1)` source; consumed at most once.
    ///   - kind: The member's count kind.
    /// - Returns: The rolled target (a step multiple inside the range).
    static func rollTarget(
        t: CountValue, level: VaryLevel, goal: CountValue, rng: () -> Double, kind: CountKind = .discrete
    ) -> CountValue {
        let range = varyRange(t: t, level: level, goal: goal, kind: kind)
        if level == .off || range.lowerBound == range.upperBound { return range.lowerBound }
        let step = countTargetStep(kind)
        // Same `n` / index arithmetic as the TS twin → the identical double.
        let n = ((range.upperBound - range.lowerBound) / step).rounded(.toNearestOrAwayFromZero)
        let index = (rng() * (n + 1)).rounded(.down)
        return quantizeCount(range.lowerBound + index * step)
    }

    // MARK: - Supply expansion

    /// A ``Supply`` after Split-up expansion.
    struct ExpandedSupply {
        let source: BoardSource
        let supplyTaskIds: [String]
        /// childTaskId → compound member id, for every id that entered via Split up.
        let partOf: [String: String]
        /// The input supply's effective goals (slice 3a), preserved untouched.
        var goalByTaskId: [String: CountValue]? = nil

        /// The un-expanded view, for the selection helpers that take a ``Supply``.
        var asSupply: Supply {
            Supply(source: source, supplyTaskIds: supplyTaskIds, goalByTaskId: goalByTaskId)
        }
    }

    /// Supply expansion (spec step 1): a member with `split == true`
    /// contributes its non-excluded children instead of itself, in
    /// `childIndex` order.
    ///
    /// Stale-inert throughout — a rule for an id the supply doesn't carry, a
    /// part rule for a child the compound no longer has, or `split` on a
    /// non-compound / childless member all do nothing. The last-part guard
    /// means excluding every part is treated as excluding none (a split
    /// member always contributes).
    ///
    /// - Parameters:
    ///   - supplies: Per-source supplies, already exclude-filtered by the caller.
    ///   - childrenByCompoundId: Compound id → its `compound_children` rows.
    ///   - tasksById: Id → task (only `id` and `type` are read).
    /// - Returns: One ``ExpandedSupply`` per input supply, order preserved.
    static func applyMemberRules(
        _ supplies: [Supply],
        childrenByCompoundId: [String: [CompoundChild]],
        tasksById: [String: Task]
    ) -> [ExpandedSupply] {
        supplies.map { supply in
            let rules = supply.source.memberRules ?? [:]
            var out: [String] = []
            var partOf: [String: String] = [:]
            for id in supply.supplyTaskIds {
                let rule = rules[id]
                let kids = childrenByCompoundId[id] ?? []
                guard rule?.split == true, tasksById[id]?.type == .compound, !kids.isEmpty else {
                    out.append(id)
                    continue
                }
                // Total comparator — `childIndex`, then `childTaskId`.
                // Duplicate indexes exist in stored rows and `sorted` is NOT
                // stable, so a tie left to insertion order would expand in a
                // different order than the (stable-sorting) TS twin.
                let ordered = kids
                    .sorted { ($0.childIndex, $0.childTaskId) < ($1.childIndex, $1.childTaskId) }
                    .map(\.childTaskId)
                let kept = ordered.filter { rule?.parts?[$0]?.excluded != true }
                for child in (kept.isEmpty ? ordered : kept) {
                    out.append(child)
                    partOf[child] = id
                }
            }
            return ExpandedSupply(
                source: supply.source, supplyTaskIds: out, partOf: partOf, goalByTaskId: supply.goalByTaskId
            )
        }
    }

    // MARK: - Plan

    /// Which kind of board is being assembled. Auto targets apply to BOTH
    /// kinds (owner ruling 2026-09-21) — the mode only decides *when* a
    /// board-pulled counting target is written, never how it is computed.
    enum PlanMode {
        case oneOff
        case recurring
    }

    /// The window a board (or a pulled source board) covers.
    struct BoardWindow: Equatable {
        let timeframe: Timeframe
        let startDate: String?
        let endDate: String?

        init(timeframe: Timeframe, startDate: String? = nil, endDate: String? = nil) {
            self.timeframe = timeframe
            self.startDate = startDate
            self.endDate = endDate
        }
    }

    /// One planned placement (TASK_WINDOW_REWORK slice 3b): the task a
    /// `board_tasks` row points at and the parameters the square carries.
    /// The planner emits ONE per selected id, in order — never a row to mint.
    /// Twin of the TS `PlannedPlacement`.
    struct PlannedPlacement: Equatable {
        /// The member itself.
        var taskId: String
        /// The planned per-window target, in `targetKind`; only when it differs from the task's own goal.
        var targetOverride: CountValue?
        var targetKind: CountKind?
        /// A re-targeted compound's per-child targets (direct children only).
        var childTargets: [PlacementChildTarget]?
        /// A per-board title. The planner NEVER sets it; only an explicit wizard
        /// draft (`PlacementParamsDraft.overlaying`) carries one, so persist can
        /// write it with the planned parameters in one pass.
        var titleOverride: String?

        init(
            taskId: String,
            targetOverride: CountValue? = nil,
            targetKind: CountKind? = nil,
            childTargets: [PlacementChildTarget]? = nil,
            titleOverride: String? = nil
        ) {
            self.taskId = taskId
            self.targetOverride = targetOverride
            self.targetKind = targetKind
            self.childTargets = childTargets
            self.titleOverride = titleOverride
        }
    }

    /// Output of ``planDerivedTasks(selectedIds:supplies:manualTaskIds:manualTaskVary:window:mode:tasksById:childrenByCompoundId:sourceWindowByTaskId:rootsById:rng:)``.
    struct PlanDerivedTasksResult: Equatable {
        /// One per `selectedIds` entry, in `selectedIds` order.
        let placements: [PlannedPlacement]
    }

    /// A member is LINKED to a shared counter — a legacy window-stamped
    /// derived counter OR a hub-linked copy (`sharedCounterId` alone). Judged
    /// on `sharedCounterId` alone (twin of the TS `isLinkedMember`).
    private static func isLinkedMember(_ task: Task) -> Bool {
        !(task.sharedCounterId ?? "").isEmpty
    }

    /// A counting task's own goal, or `nil` when it is goal-less (an
    /// accumulator, which has no target to pro-rate or vary). Whole kinds
    /// need `≥ 1` and floor (TS twin); continuous keeps any positive goal.
    private static func goalOf(_ task: Task) -> CountValue? {
        guard let maxCount = task.maxCount else { return nil }
        if isWholeCountKind(resolveCountKind(task.countKind)) {
            return maxCount >= 1 ? maxCount.rounded(.down) : nil
        }
        return maxCount > 0 ? quantizeCount(maxCount) : nil
    }

    /// Spec step 3 — decide, per selected id, what its `board_tasks` row
    /// points at and which placement parameters it carries (slice 3b: the
    /// planner emits parameters, never rows).
    ///
    /// Semantics (rng sampling order, precedence, the override-only-when-
    /// different rule, legacy derived rows resolving to their root): see the
    /// TS twin `planDerivedTasks` in `packages/shared/src/algorithms/memberRules.ts`
    /// — mirrored exactly and pinned by `memberRuleVectors.json`.
    ///
    /// - Parameters:
    ///   - selectedIds: The task ids picked for the board, in placement order.
    ///   - supplies: Per-source supplies, already Split-up expanded.
    ///   - manualTaskIds: Hand-added ids — they win over any source copy.
    ///   - manualTaskVary: Hand-added id → its dice.
    ///   - window: The board's window.
    ///   - mode: One-off or recurring. Does not gate the target math.
    ///   - tasksById: Id → task, for every selected id and compound child.
    ///   - childrenByCompoundId: Compound id → its `compound_children` rows.
    ///   - sourceWindowByTaskId: Task id → the window of the source board it came from.
    ///   - rootsById: Root id → root, for roots not in `tasksById`.
    ///   - rng: Uniform `[0, 1)` source.
    /// - Returns: One ``PlannedPlacement`` per selected id.
    static func planDerivedTasks(
        selectedIds: [String],
        supplies: [ExpandedSupply],
        manualTaskIds: [String],
        manualTaskVary: [String: VaryLevel],
        window: BoardWindow,
        mode: PlanMode,
        tasksById: [String: Task],
        childrenByCompoundId: [String: [CompoundChild]],
        sourceWindowByTaskId: [String: BoardWindow],
        rootsById: [String: Task] = [:],
        rng: () -> Double
    ) -> PlanDerivedTasksResult {
        let manual = Set(manualTaskIds)
        /// The member's shared-counter root (itself when it is the root), if known.
        func rootOf(_ t: Task) -> Task? {
            guard let sid = t.sharedCounterId, !sid.isEmpty else { return t }
            return rootsById[sid] ?? tasksById[sid]
        }
        /// A root's timeframe default for this board (docs/SHARED_COUNTER_SETTINGS.md §2).
        func defaultOf(_ root: Task?, kindFallback: Bool = true) -> CountValue? {
            root.flatMap { CounterPlacement.counterTimeframeDefault(.init(task: $0), window: window, kindFallback: kindFallback) }
        }
        let targetDays = nominalWindowDays(
            window.timeframe,
            startDate: window.startDate,
            endDate: window.endDate
        )
        var placements: [PlannedPlacement] = []

        func supplying(_ id: String) -> ExpandedSupply? {
            supplies.first { $0.supplyTaskIds.contains(id) }
        }
        func sourceDaysFor(_ taskId: String) -> Int? {
            guard let sourceWindow = sourceWindowByTaskId[taskId] else { return nil }
            return nominalWindowDays(
                sourceWindow.timeframe,
                startDate: sourceWindow.startDate,
                endDate: sourceWindow.endDate
            )
        }
        /// The pre-vary target: an explicit rule if there is one, else the
        /// window-pro-rated ``autoTarget(goal:sourceDays:targetDays:kind:)`` for a
        /// BOARD-sourced member, else the member's own goal. The final clamp is
        /// kept verbatim from the TS twin (only observable on an off-step explicit target).
        func resolveTarget(
            goal: CountValue,
            explicit: CountValue?,
            fromBoard: Bool,
            taskIdForWindow: String,
            kind: CountKind
        ) -> CountValue {
            // A board-sourced member consults its root's timeframe default FIRST
            // (a source pull and a hand-add agree), as-is even above `goal`; no kind fallback (own goal pro-rates).
            if explicit == nil, fromBoard, let dflt = defaultOf(tasksById[taskIdForWindow].flatMap(rootOf), kindFallback: false) {
                return dflt
            }
            let base: CountValue
            if let explicit {
                base = explicit
            } else if fromBoard {
                base = autoTarget(
                    goal: goal,
                    sourceDays: sourceDaysFor(taskIdForWindow),
                    targetDays: targetDays,
                    kind: kind
                )
            } else {
                base = goal
            }
            // R17: the goal itself is always a valid target as-is (26.25, 0.05).
            if base >= goal { return goal }
            return Swift.min(Swift.max(countTargetStep(kind), floorToCountStep(base, kind: kind)), goal)
        }
        /// A supplied member's EFFECTIVE goal (slice 3a): the source placement's
        /// `targetOverride` when a BOARD source carries one (`goalByTaskId`),
        /// else the member's own goal. A hand-added member reads its own.
        func effectiveGoalOf(_ id: String, _ task: Task, _ sup: ExpandedSupply?) -> CountValue? {
            if sup?.source.kind == .board, let supplied = sup?.goalByTaskId?[id], supplied > 0 {
                if isWholeCountKind(resolveCountKind(task.countKind)) {
                    return supplied >= 1 ? supplied.rounded(.down) : nil
                }
                return quantizeCount(supplied)
            }
            return goalOf(task)
        }
        /// The placement for `t` at the pre-vary `target` rolled by `vary`: the
        /// override lands only when the rolled target differs from the task's
        /// own goal.
        func param(_ t: Task, _ target: CountValue, _ vary: VaryLevel, _ effGoal: CountValue?) -> PlannedPlacement {
            let goal = Swift.max(effGoal ?? goalOf(t) ?? 0, target)
            let kind = resolveCountKind(t.countKind)
            let rolled = rollTarget(t: target, level: vary, goal: goal, rng: rng, kind: kind)
            var out = PlannedPlacement(taskId: t.id)
            let own = goalOf(t)
            if own == nil || rolled != own {
                out.targetOverride = rolled
                out.targetKind = kind
            }
            return out
        }

        for id in selectedIds {
            guard let task = tasksById[id] else {
                placements.append(PlannedPlacement(taskId: id))
                continue
            }
            let isManual = manual.contains(id)
            let supply = isManual ? nil : supplying(id)
            let fromBoard = supply?.source.kind == .board
            let rules = supply?.source.memberRules ?? [:]
            let parentId = supply?.partOf[id]

            if task.type == .counting {
                let ownGoal = effectiveGoalOf(id, task, supply)
                // A hand-added or POOL-sourced ROOT with a differing default
                // takes it (also the vary base); a LINKED row keeps its own goal.
                if isManual || (supply != nil && !fromBoard), !isLinkedMember(task),
                   let dflt = defaultOf(task), dflt != ownGoal {
                    let vary = isManual ? (manualTaskVary[id] ?? .off)
                        : parentId.map { rules[$0]?.parts?[id]?.vary ?? .off } ?? (rules[id]?.vary ?? .off)
                    placements.append(param(task, dflt, vary, ownGoal))
                    continue
                }
                // A goal-less member pulled from a board takes its root's default.
                guard let goal = ownGoal ?? (fromBoard ? defaultOf(rootOf(task)) : nil) else {
                    // Goal-less (an accumulator): nothing to target — placed as-is.
                    placements.append(PlannedPlacement(taskId: id))
                    continue
                }
                if isManual {
                    placements.append(param(task, goal, manualTaskVary[id] ?? .off, ownGoal))
                    continue
                }
                if let parentId {
                    // Split part — the part rule governs; the parent's `vary` is ignored.
                    let part = rules[parentId]?.parts?[id] ?? BoardSourcePartRule()
                    let vary = part.vary ?? .off
                    if fromBoard || vary != .off {
                        let target = resolveTarget(
                            goal: goal,
                            explicit: fromBoard ? part.target : nil,
                            fromBoard: fromBoard,
                            taskIdForWindow: id,
                            kind: resolveCountKind(task.countKind)
                        )
                        placements.append(param(task, target, vary, ownGoal))
                        continue
                    }
                    placements.append(PlannedPlacement(taskId: id))
                    continue
                }
                let rule = rules[id] ?? BoardSourceMemberRule()
                let vary = rule.vary ?? .off
                if fromBoard {
                    let target = resolveTarget(
                        goal: goal,
                        explicit: rule.target,
                        fromBoard: true,
                        taskIdForWindow: id,
                        kind: resolveCountKind(task.countKind)
                    )
                    placements.append(param(task, target, vary, ownGoal))
                    continue
                }
                // Pool-sourced: vary only.
                placements.append(param(task, goal, vary, ownGoal))
                continue
            }

            if task.type == .compound, supply != nil, rules[id]?.split != true {
                // Total comparator, as in `applyMemberRules`.
                let kids = (childrenByCompoundId[id] ?? [])
                    .sorted { ($0.childIndex, $0.childTaskId) < ($1.childIndex, $1.childTaskId) }
                guard let rule = rules[id], !kids.isEmpty else {
                    placements.append(PlannedPlacement(taskId: id))
                    continue
                }
                var childTargets: [PlacementChildTarget] = []
                for link in kids {
                    guard let child = tasksById[link.childTaskId], child.type == .counting,
                          let goal = effectiveGoalOf(link.childTaskId, child, supply) else { continue }
                    let part = rule.parts?[link.childTaskId] ?? BoardSourcePartRule()
                    let vary = part.vary ?? rule.vary ?? .off
                    let hasTarget = fromBoard && (part.target != nil || (rule.vary ?? .off) != .off)
                    if !hasTarget && vary == .off { continue }
                    let kind = resolveCountKind(child.countKind)
                    let target = resolveTarget(
                        goal: goal,
                        explicit: fromBoard ? part.target : nil,
                        fromBoard: fromBoard,
                        taskIdForWindow: link.childTaskId,
                        kind: kind
                    )
                    let rolled = rollTarget(t: target, level: vary, goal: Swift.max(goal, target), rng: rng, kind: kind)
                    // An entry only when the child's target differs from its own goal.
                    if rolled == goalOf(child) { continue }
                    childTargets.append(PlacementChildTarget(childId: link.childTaskId, target: rolled))
                }
                placements.append(PlannedPlacement(taskId: id, childTargets: childTargets.isEmpty ? nil : childTargets))
                continue
            }

            placements.append(PlannedPlacement(taskId: id))
        }

        return PlanDerivedTasksResult(placements: placements)
    }
}
