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

    // MARK: - Deterministic id namespaces

    /// uuidv5 name prefix for a per-window derived counter.
    static let derivedTaskNamespace = "sources:derived"
    /// uuidv5 name prefix for a per-window derived compound.
    static let derivedCompoundNamespace = "sources:derived-compound"
    /// uuidv5 name prefix for a derived compound's `compound_children` link.
    static let derivedLinkNamespace = "sources:derived-link"

    /// Deterministic id of the derived counter for `rootTaskId` on `boardId`.
    ///
    /// - Parameters:
    ///   - boardId: The board the derived counter is stamped for.
    ///   - rootTaskId: The shared-counter root (`sharedCounterId ?? id`).
    /// - Returns: A stable uuidv5 — re-deriving the same window yields the same id.
    static func derivedTaskId(boardId: String, rootTaskId: String) -> String {
        UUIDv5.uuidv5(name: "\(derivedTaskNamespace):\(boardId):\(rootTaskId)")
    }

    /// Deterministic id of the derived compound for `compoundId` on `boardId`.
    ///
    /// - Parameters:
    ///   - boardId: The board the derived compound is stamped for.
    ///   - compoundId: The source compound task's id.
    /// - Returns: A stable uuidv5.
    static func derivedCompoundId(boardId: String, compoundId: String) -> String {
        UUIDv5.uuidv5(name: "\(derivedCompoundNamespace):\(boardId):\(compoundId)")
    }

    /// Deterministic id of the `compound_children` link from a derived
    /// compound to one of its children (derived or original).
    ///
    /// - Parameters:
    ///   - derivedCompoundId: The derived compound's id (from ``derivedCompoundId(boardId:compoundId:)``).
    ///   - childId: The child task id the link points at — the LITERAL id,
    ///     i.e. a derived uuid for a derived child, the raw source id otherwise.
    /// - Returns: A stable uuidv5.
    static func derivedLinkId(derivedCompoundId: String, childId: String) -> String {
        UUIDv5.uuidv5(name: "\(derivedLinkNamespace):\(derivedCompoundId):\(childId)")
    }

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

        /// The un-expanded view, for the selection helpers that take a ``Supply``.
        var asSupply: Supply {
            Supply(source: source, supplyTaskIds: supplyTaskIds)
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
            return ExpandedSupply(source: supply.source, supplyTaskIds: out, partOf: partOf)
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

    /// An in-memory window-stamped derived counter, before B2 persists it.
    struct DerivedTaskDraft: Equatable {
        let id: String
        /// The shared-counter root this derives from (`sharedCounterId ?? id`).
        let rootTaskId: String
        /// The member id that produced it (may be another derived counter).
        let sourceMemberId: String
        /// The selected id this draft stands in for on the board.
        let replacesId: String
        let maxCount: CountValue
        /// The kind the copy counts in — the root's (D5).
        let countKind: CountKind
        /// Event-derived lifetime count at mint time — a cache, never authored.
        let baseline: CountValue
        let title: String
        let action: String
        let unit: String
        let timeframe: Timeframe
        let startDate: String?
        let endDate: String?
    }

    /// One `compound_children` link of a ``DerivedCompoundDraft``.
    struct DerivedCompoundChildDraft: Equatable {
        let linkId: String
        let childTaskId: String
        let childIndex: Int
        /// True when `childTaskId` is a derived counter rather than the original child.
        let isDerived: Bool
    }

    /// An in-memory derived compound (a One-square compound with re-targeted parts).
    struct DerivedCompoundDraft: Equatable {
        let id: String
        let sourceCompoundId: String
        let replacesId: String
        let title: String
        /// Swift names the field `operatorType` (as `Task` does — `operator`
        /// is a Swift keyword); it is the TS twin's `operator`.
        let operatorType: OperatorType?
        let threshold: Int?
        /// The window this derived compound is stamped for — the same one its
        /// parts carry, copied from the board being assembled. ``buildDerivedRows(drafts:userId:now:rootsById:compoundsById:)``
        /// writes it onto the compound `Task` row, so the derived compound
        /// expires with its window exactly like its parts do.
        let timeframe: Timeframe
        let startDate: String?
        let endDate: String?
        let children: [DerivedCompoundChildDraft]
    }

    /// Output of ``planDerivedTasks(selectedIds:supplies:manualTaskIds:manualTaskVary:boardId:window:mode:tasksById:childrenByCompoundId:sourceWindowByTaskId:baselineByRootId:rng:)``.
    struct PlanDerivedTasksResult: Equatable {
        /// What actually lands in `board_tasks`, in `selectedIds` order.
        let placementIds: [String]
        let derivedTasks: [DerivedTaskDraft]
        let derivedCompounds: [DerivedCompoundDraft]
    }

    /// A member is LINKED to a shared counter — a window-stamped derived
    /// counter (both marks) OR a hub-linked copy (`sharedCounterId` alone).
    ///
    /// Owner rule 2026-10-01: a counting square on a board accounts only for
    /// the counter's logs inside that board's window, so EVERY linked
    /// hand-added member is re-minted as a window-stamped row for the window
    /// being planned (before, only an already-window-stamped member or a
    /// vary > 0 roll minted). Deliberately looser than the exported
    /// ``isWindowStampedDerived(_:)``, which also requires `createdInWizard`
    /// — a PLANNED member is judged on `sharedCounterId` alone, while the
    /// exported predicate identifies a STORED row and wants all three. Twin
    /// of the TS `isLinkedMember`.
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

    /// One child of a One-square compound, plus the decision made about it.
    private struct ChildPlan {
        let link: CompoundChild
        let child: Task?
        let derive: Bool
        let target: CountValue
        let vary: VaryLevel
    }

    /// Spec step 3 — decide, per selected id, whether it is placed as-is or
    /// replaced by a window-stamped derived counter / derived compound.
    ///
    /// Semantics (rng sampling order, precedence, the no-identical-clone rule
    /// and the collapse rule): see the TS twin `planDerivedTasks` in
    /// `packages/shared/src/algorithms/memberRules.ts` — mirrored exactly and
    /// pinned by `memberRuleVectors.json`.
    ///
    /// - Parameters:
    ///   - selectedIds: The task ids picked for the board, in placement order.
    ///   - supplies: Per-source supplies, already Split-up expanded.
    ///   - manualTaskIds: Hand-added ids — they win over any source copy.
    ///   - manualTaskVary: Hand-added id → its dice.
    ///   - boardId: The board being assembled (seeds every derived id).
    ///   - window: The board's window; every derived draft is stamped with it.
    ///   - mode: One-off or recurring. Does not gate the target math (the
    ///     vectors pin identical resolution in both modes).
    ///   - tasksById: Id → task, for every selected id and compound child.
    ///   - childrenByCompoundId: Compound id → its `compound_children` rows.
    ///   - sourceWindowByTaskId: Task id → the window of the source board it
    ///     came from. Keyed by every id whose source window matters —
    ///     supplied members AND the children of a One-square compound (a
    ///     compound's parts are pro-rated by looking up the CHILD's id,
    ///     never the compound's).
    ///   - baselineByRootId: Shared-counter root id → its event-derived lifetime count.
    ///   - rootsById: Root id → root, for roots not in `tasksById` (copy titles
    ///     render through the root's templates; board pulls consult its defaults).
    ///   - rng: Uniform `[0, 1)` source.
    /// - Returns: Placement ids plus the derived drafts they refer to.
    static func planDerivedTasks(
        selectedIds: [String],
        supplies: [ExpandedSupply],
        manualTaskIds: [String],
        manualTaskVary: [String: VaryLevel],
        boardId: String,
        window: BoardWindow,
        mode: PlanMode,
        tasksById: [String: Task],
        childrenByCompoundId: [String: [CompoundChild]],
        sourceWindowByTaskId: [String: BoardWindow],
        baselineByRootId: [String: CountValue],
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
        func defaultOf(_ root: Task?) -> CountValue? {
            root.flatMap { CounterPlacement.counterTimeframeDefault(.init(task: $0), timeframe: window.timeframe) }
        }
        let targetDays = nominalWindowDays(
            window.timeframe,
            startDate: window.startDate,
            endDate: window.endDate
        )
        var placementIds: [String] = []
        var derivedTasks: [DerivedTaskDraft] = []
        var derivedCompounds: [DerivedCompoundDraft] = []
        var derivedByRoot: [String: DerivedTaskDraft] = [:]

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
        /// BOARD-sourced member, else the member's own goal. The gate is
        /// `fromBoard` alone — pool-sourced and hand-added members never
        /// auto-target (they offer vary / split / part-exclusion only), while
        /// a board-pulled member pro-rates on one-off AND recurring boards
        /// alike (owner ruling 2026-09-21).
        ///
        /// The final clamp is kept verbatim from the TS twin (only observable
        /// on an off-step explicit target).
        func resolveTarget(
            goal: CountValue,
            explicit: CountValue?,
            fromBoard: Bool,
            taskIdForWindow: String,
            kind: CountKind
        ) -> CountValue {
            // A board-sourced member consults its root's timeframe default FIRST
            // (a source pull and a hand-add agree), as-is even above `goal`.
            if explicit == nil, fromBoard, let dflt = defaultOf(tasksById[taskIdForWindow].flatMap(rootOf)) {
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
        func mint(_ task: Task, replacesId: String, target: CountValue, vary: VaryLevel) -> DerivedTaskDraft {
            // The vary clamp's ceiling: the goal, or a timeframe default above it
            // (every pre-default target is ≤ the goal, so unchanged there).
            let goal = Swift.max(goalOf(task) ?? 0, target)
            let root = task.sharedCounterId ?? task.id
            // The dedupe is checked BEFORE the roll: a collapsed occurrence
            // consumes no rng sample, so a seeded sequence reproduces
            // identically on both platforms (TS twin, verbatim).
            if let existing = derivedByRoot[root] { return existing }
            let countKind = resolveCountKind(task.countKind)
            let maxCount = rollTarget(t: target, level: vary, goal: goal, rng: rng, kind: countKind)
            let action = task.action ?? ""
            let unit = task.unit ?? ""
            let draft = DerivedTaskDraft(
                id: derivedTaskId(boardId: boardId, rootTaskId: root),
                rootTaskId: root,
                sourceMemberId: task.id,
                replacesId: replacesId,
                maxCount: maxCount,
                countKind: countKind,
                baseline: isWholeCountKind(countKind) ? (baselineByRootId[root] ?? 0).rounded(.down) : quantizeCount(baselineByRootId[root] ?? 0),
                title: TaskTitle.counterCopyTitle(
                    member: task, newMaxCount: maxCount, settings: rootOf(task).map(CounterSettings.TitleSettings.init(task:))
                ),
                action: action,
                unit: unit,
                timeframe: window.timeframe,
                startDate: window.startDate,
                endDate: window.endDate
            )
            derivedByRoot[root] = draft
            derivedTasks.append(draft)
            return draft
        }

        for id in selectedIds {
            guard let task = tasksById[id] else {
                placementIds.append(id)
                continue
            }
            let isManual = manual.contains(id)
            let supply = isManual ? nil : supplying(id)
            let fromBoard = supply?.source.kind == .board
            let rules = supply?.source.memberRules ?? [:]
            let parentId = supply?.partOf[id]

            if task.type == .counting {
                let ownGoal = goalOf(task)
                // A hand-added or POOL-sourced ROOT with a differing default mints
                // at it (also the vary base); a LINKED row keeps its own goal.
                if isManual || (supply != nil && !fromBoard), !isLinkedMember(task),
                   let dflt = defaultOf(task), dflt != ownGoal {
                    let vary = isManual ? (manualTaskVary[id] ?? .off)
                        : parentId.map { rules[$0]?.parts?[id]?.vary ?? .off } ?? (rules[id]?.vary ?? .off)
                    placementIds.append(mint(task, replacesId: id, target: dflt, vary: vary).id)
                    continue
                }
                // A goal-less member pulled from a board takes its root's default.
                guard let goal = ownGoal ?? (fromBoard ? defaultOf(rootOf(task)) : nil) else {
                    // Goal-less (an accumulator — including a goal-less
                    // LINKED member): nothing to mint a per-window target
                    // from, so it is placed as-is. Documented edge of the
                    // 2026-10-01 rule; `TaskSchema` requires a goal on every
                    // non-hub-born counting task, so this is defensive.
                    placementIds.append(id)
                    continue
                }
                if isManual {
                    let vary = manualTaskVary[id] ?? .off
                    // A LINKED member (window-stamped OR hub-linked) is ALWAYS
                    // minted for this window — owner rule 2026-10-01. Vary off
                    // consumes no rng.
                    if isLinkedMember(task) {
                        placementIds.append(mint(task, replacesId: id, target: goal, vary: vary).id)
                        continue
                    }
                    if vary != .off {
                        placementIds.append(mint(task, replacesId: id, target: goal, vary: vary).id)
                        continue
                    }
                    placementIds.append(id)
                    continue
                }
                if let parentId {
                    // Split part — the part rule governs; the parent's
                    // `vary` is ignored.
                    let part = rules[parentId]?.parts?[id] ?? BoardSourcePartRule()
                    let vary = part.vary ?? .off
                    // `target` — member- OR part-level — is honoured on
                    // board sources only; a pool member offers vary / split
                    // / part-exclusion and nothing else.
                    if fromBoard || vary != .off {
                        let target = resolveTarget(
                            goal: goal,
                            explicit: fromBoard ? part.target : nil,
                            fromBoard: fromBoard,
                            taskIdForWindow: id,
                            kind: resolveCountKind(task.countKind)
                        )
                        // No identical clone (owner ruling 2026-09-22) — the TS
                        // twin carries the full reasoning, including why the
                        // `sharedCounterId == nil` guard is load-bearing (a
                        // window-stamped member must re-mint for THIS window).
                        if target == ownGoal, vary == .off, task.sharedCounterId == nil {
                            placementIds.append(id)
                            continue
                        }
                        placementIds.append(
                            mint(task, replacesId: id, target: target, vary: vary).id
                        )
                        continue
                    }
                    placementIds.append(id)
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
                    // No identical clone (owner ruling 2026-09-22) — same rule as the split part.
                    if target == ownGoal, vary == .off, task.sharedCounterId == nil {
                        placementIds.append(id)
                        continue
                    }
                    placementIds.append(mint(task, replacesId: id, target: target, vary: vary).id)
                    continue
                }
                if vary != .off {
                    placementIds.append(mint(task, replacesId: id, target: goal, vary: vary).id)
                    continue
                }
                placementIds.append(id)
                continue
            }

            if task.type == .compound, supply != nil, rules[id]?.split != true {
                // Total comparator, as in `applyMemberRules` — a duplicate
                // `childIndex` must not roll in a different order (and so
                // consume the seeded rng differently) than the TS twin.
                let kids = (childrenByCompoundId[id] ?? [])
                    .sorted { ($0.childIndex, $0.childTaskId) < ($1.childIndex, $1.childTaskId) }
                guard let rule = rules[id], !kids.isEmpty else {
                    placementIds.append(id)
                    continue
                }
                let plans: [ChildPlan] = kids.map { link in
                    let child = tasksById[link.childTaskId]
                    let goal = child.flatMap { goalOf($0) }
                    guard let child, child.type == .counting, let goal else {
                        return ChildPlan(link: link, child: child, derive: false, target: 0, vary: .off)
                    }
                    let part = rule.parts?[link.childTaskId] ?? BoardSourcePartRule()
                    let vary = part.vary ?? rule.vary ?? .off
                    // Board sources only, as in the split-part branch above.
                    let hasTarget = fromBoard && (part.target != nil || (rule.vary ?? .off) != .off)
                    if !hasTarget && vary == .off {
                        return ChildPlan(link: link, child: child, derive: false, target: 0, vary: .off)
                    }
                    let target = resolveTarget(
                        goal: goal,
                        explicit: fromBoard ? part.target : nil,
                        fromBoard: fromBoard,
                        taskIdForWindow: link.childTaskId,
                        kind: resolveCountKind(child.countKind)
                    )
                    return ChildPlan(link: link, child: child, derive: true, target: target, vary: vary)
                }
                guard plans.contains(where: { $0.derive }) else {
                    placementIds.append(id)
                    continue
                }
                let compoundId = derivedCompoundId(boardId: boardId, compoundId: id)
                var children: [DerivedCompoundChildDraft] = []
                var seenChildIds = Set<String>()
                for plan in plans {
                    let childTaskId: String
                    if plan.derive, let child = plan.child {
                        childTaskId = mint(
                            child,
                            replacesId: plan.link.childTaskId,
                            target: plan.target,
                            vary: plan.vary
                        ).id
                    } else {
                        childTaskId = plan.link.childTaskId
                    }
                    // Two parts that collapse onto one derived counter (same
                    // shared-counter root) would otherwise emit the same
                    // `childTaskId` — and the same `linkId` — twice. First in
                    // `childIndex` order wins, keeping its own `childIndex`
                    // and `linkId`.
                    guard seenChildIds.insert(childTaskId).inserted else { continue }
                    children.append(DerivedCompoundChildDraft(
                        linkId: derivedLinkId(derivedCompoundId: compoundId, childId: childTaskId),
                        childTaskId: childTaskId,
                        childIndex: plan.link.childIndex,
                        isDerived: plan.derive
                    ))
                }
                derivedCompounds.append(DerivedCompoundDraft(
                    id: compoundId,
                    sourceCompoundId: id,
                    replacesId: id,
                    title: task.title,
                    operatorType: task.operatorType,
                    threshold: task.threshold,
                    timeframe: window.timeframe,
                    startDate: window.startDate,
                    endDate: window.endDate,
                    children: children
                ))
                placementIds.append(compoundId)
                continue
            }

            placementIds.append(id)
        }

        return PlanDerivedTasksResult(
            placementIds: placementIds,
            derivedTasks: derivedTasks,
            derivedCompounds: derivedCompounds
        )
    }

    // MARK: - B2: baseline + row building

    /// The window baseline of a shared-counter root: the lifetime count the
    /// root had reached when the window opened, so the derived counter's
    /// displayed value (`root.currentCount − baseline`) starts this window at
    /// zero.
    ///
    /// Ruling RB2 — the sum of the `delta`s of the root's LIVE increment
    /// events whose `occurredAt` is strictly BEFORE `boundary`, clamped at 0.
    /// Completion events, tombstoned events and other tasks' events are
    /// ignored, and an event exactly ON the boundary belongs to the new
    /// window, not to the baseline.
    ///
    /// Both sides are compared as INSTANTS (`DateFormatting.parseISO`), never
    /// as strings: board dates are local ISO (`2026-09-18T00:00:00`, no
    /// offset) while events carry a UTC stamp, so a lexical compare — or
    /// re-stamping a local date as UTC — would move the boundary by the local
    /// offset and admit or drop every event either side of local midnight.
    /// `parseISO` is the repo's existing parser and accepts all three shapes
    /// the two sides can take (fractional-second internet time, plain internet
    /// time, and the wizard's offset-less local ISO). A stamp that doesn't
    /// parse (on either side) skips the event rather than counting it.
    ///
    /// `boundary` is decided by the CALLER (the board's `startDate`, or the
    /// mint instant for an INDEFINITE / date-less board) — this helper never
    /// guesses it. It must be a FULL timestamp; a date-only string is not
    /// supported (`parseISO` has no date-only format and returns nil, and the
    /// TS twin's `Date.parse` would read it as UTC midnight — the two would
    /// disagree).
    ///
    /// - Parameters:
    ///   - rootTaskId: The shared-counter root whose events are summed.
    ///   - events: Candidate events; any task's, any kind, live or tombstoned.
    ///   - boundary: ISO8601 instant the window opens at.
    /// - Returns: The baseline count (≥ 0).
    static func computeWindowBaseline(
        rootTaskId: String,
        events: [TaskEvent],
        boundary: String
    ) -> CountValue {
        guard let boundaryDate = DateFormatting.parseISO(boundary) else { return 0 }
        var sum: CountValue = 0
        for event in events {
            guard !event.isDeleted,
                  event.taskId == rootTaskId,
                  event.kind == .increment,
                  // A malformed increment with no delta is SKIPPED, not
                  // treated as 0 — matching the TS twin's finite-number guard.
                  let delta = event.delta,
                  let occurred = DateFormatting.parseISO(event.occurredAt),
                  occurred < boundaryDate
            else { continue }
            sum += delta
        }
        return Swift.max(0, quantizeCount(sum))
    }

    /// Is this STORED task row one of our per-window derived counters?
    ///
    /// All three marks together — a shared-counter link, a window start, and
    /// the wizard-born provenance flag. Each alone is ordinary user data: a
    /// hand-made linked counter has the first, a timeboxed task the second, a
    /// wizard-born task the third. Only the three together identify a row this
    /// pipeline minted for one window (and may therefore refresh or retire
    /// when that window is re-derived).
    ///
    /// - Parameter task: The task row to test.
    /// - Returns: True when the row is a window-stamped derived counter.
    static func isWindowStampedDerived(_ task: Task) -> Bool {
        !(task.sharedCounterId ?? "").isEmpty
            && !(task.startDate ?? "").isEmpty
            && task.createdInWizard
    }

    /// Is this STORED row a window-stamped derived counter whose window has
    /// ENDED, so shared-counter propagation must skip it (the propagation
    /// freeze)? Twin of the TS `isFrozenDerivedRow`, pinned by the
    /// `frozenDerivedRow` section of `memberRuleVectors.json`.
    ///
    /// Increment / decrement / undo skip a frozen row's authored write and
    /// enqueue; completion reads the ROOT's in-window events, not the latch.
    /// Increment / decrement (event stamped `now`) skip its cascade too; undo
    /// cascades — never writes — the rows `isFrozenRowReachedByEvent` names
    /// (TaskEvents.swift). `refreshDerivedBaselines` is NOT gated by this.
    ///
    /// "Ended" uses the kernel's inclusive window convention
    /// (`DateFormatting.isWithinTimeframe`): frozen only once `now` is
    /// strictly after the `endDate` instant. Rows with no `endDate` and
    /// hub-linked rows (no `startDate`) are never frozen. An unparseable
    /// `endDate` or `now` is treated as not frozen.
    ///
    /// - Parameters:
    ///   - task: The linked task row to test.
    ///   - now: The current instant as an ISO8601 string (a parameter, never
    ///     read from the clock here, so the predicate stays pure).
    /// - Returns: True when propagation must skip the row.
    static func isFrozenDerivedRow(_ task: Task, now: String) -> Bool {
        guard isWindowStampedDerived(task),
              let endDate = task.endDate,
              let end = DateFormatting.parseISO(endDate),
              let nowDate = DateFormatting.parseISO(now) else { return false }
        return nowDate > end
    }

    /// Output of ``buildDerivedRows(drafts:userId:now:rootsById:compoundsById:)``
    /// — complete, writable rows. (Swift twin of the TS `DerivedRows`
    /// interface; a named struct rather than a bare tuple so the two write
    /// paths and their tests can name the type.)
    struct DerivedRows {
        var tasks: [Task]
        var links: [CompoundChild]
    }

    /// Materialise the ``planDerivedTasks(selectedIds:supplies:manualTaskIds:manualTaskVary:boardId:window:mode:tasksById:childrenByCompoundId:sourceWindowByTaskId:baselineByRootId:rng:)``
    /// drafts as complete `Task` / `CompoundChild` rows. Pure — the caller
    /// writes them (in one transaction, before the `board_tasks` rows that
    /// point at them).
    ///
    /// Derived counters come first, in draft order, then the derived
    /// compounds; every row keeps the deterministic id its draft carries, so
    /// re-deriving the same window overwrites rather than duplicates. A
    /// derived counter mirrors its root's lifetime `currentCount` and reads
    /// its window value from that minus `baseline`, so `isCompleted` at mint
    /// is whatever `deriveDisplayedCount` already says — a root that has raced
    /// past the target is born complete rather than hand-initialised to false.
    ///
    /// Two invariants the CALLER owes, because the builder degrades quietly
    /// rather than throwing: every `rootTaskId` in `drafts.derivedTasks` must
    /// be present in `rootsById` (a missing root mirrors a count of 0, writing
    /// a row that contradicts its own root until the next increment heals it),
    /// and every `sourceCompoundId` in `drafts.derivedCompounds` must be
    /// present in `compoundsById`.
    ///
    /// - Parameters:
    ///   - drafts: The drafts to materialise, straight out of `planDerivedTasks`.
    ///   - userId: Owner of every row written.
    ///   - now: ISO8601 mint time — every row's `createdAt` / `updatedAt`.
    ///   - rootsById: Root id → the root row (its `currentCount` is mirrored).
    ///   - compoundsById: Source compound id → the row the derived compound copies from.
    /// - Returns: The derived `Task` rows and the derived compounds' child links.
    static func buildDerivedRows(
        drafts: PlanDerivedTasksResult,
        userId: String,
        now: String,
        rootsById: [String: Task],
        compoundsById: [String: Task]
    ) -> DerivedRows {
        var tasks: [Task] = []
        var links: [CompoundChild] = []

        for draft in drafts.derivedTasks {
            let mirror = rootsById[draft.rootTaskId]?.currentCount ?? 0
            let shown = deriveDisplayedCount(
                derivedBaseline: draft.baseline,
                derivedMaxCount: draft.maxCount,
                sourceCurrentCount: mirror,
                countKind: draft.countKind
            )
            tasks.append(Task(
                id: draft.id,
                userId: userId,
                title: draft.title,
                type: .counting,
                // `planDerivedTasks` fills these with "" for an action-less
                // counter; an empty string is not a value — leave the column
                // absent instead.
                action: draft.action.isEmpty ? nil : draft.action,
                unit: draft.unit.isEmpty ? nil : draft.unit,
                maxCount: draft.maxCount,
                totalCompletions: 0,
                totalInstances: 0,
                isCompleted: shown.isCompleted,
                // Stamped here or never: every other write path stamps
                // `completedAt` on the false → true transition, and for a row
                // born complete that transition has already happened.
                completedAt: shown.isCompleted ? now : nil,
                currentCount: mirror,
                createdAt: now,
                updatedAt: now,
                version: 1,
                isDeleted: false,
                timeframe: draft.timeframe,
                startDate: draft.startDate,
                endDate: draft.endDate,
                sharedCounterId: draft.rootTaskId,
                baseline: draft.baseline,
                createdInWizard: true,
                countKind: draft.countKind
            ))
        }

        for compound in drafts.derivedCompounds {
            let source = compoundsById[compound.sourceCompoundId]
            tasks.append(Task(
                id: compound.id,
                userId: userId,
                title: compound.title,
                description: source?.description,
                type: .compound,
                operatorType: compound.operatorType,
                // A nil threshold stays nil (the column is absent), exactly as
                // the TS twin refuses to write an explicit null there.
                threshold: compound.threshold,
                totalCompletions: 0,
                totalInstances: 0,
                // Written false for column uniformity and never read: a
                // compound's completion is derived from its children.
                isCompleted: false,
                createdAt: now,
                updatedAt: now,
                version: 1,
                isDeleted: false,
                timeframe: compound.timeframe,
                startDate: compound.startDate,
                endDate: compound.endDate,
                createdInWizard: true
            ))
            for child in compound.children {
                links.append(CompoundChild(
                    id: child.linkId,
                    compoundTaskId: compound.id,
                    childTaskId: child.childTaskId,
                    childIndex: child.childIndex,
                    createdAt: now,
                    updatedAt: now,
                    lastSyncedAt: nil,
                    version: 1,
                    isDeleted: false,
                    deletedAt: nil
                ))
            }
        }

        return DerivedRows(tasks: tasks, links: links)
    }
}
