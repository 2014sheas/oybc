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
    /// shrink), else the pro-rated ceiling.
    ///
    /// - Parameters:
    ///   - goal: The member's own `maxCount` (integer ≥ 1).
    ///   - sourceDays: Nominal days of the source board's window, or `nil`.
    ///   - targetDays: Nominal days of the board being assembled, or `nil`.
    /// - Returns: The auto target (integer ≥ 1, ≤ `goal`).
    static func autoTarget(goal: Int, sourceDays: Int?, targetDays: Int?) -> Int {
        guard let sourceDays else { return goal }
        guard let targetDays else { return goal }
        if targetDays >= sourceDays { return goal }
        // Double math throughout — an `Int` multiply would trap on overflow
        // where JS silently promotes to a float. Bit-identical in range.
        let prorated = Int((Double(goal) * Double(targetDays) / Double(sourceDays)).rounded(.up))
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

    /// Inclusive `lo...hi` a rolled target may land in. `t` is clamped to
    /// `1…goal` first, `lo` never drops below 1, and `hi` never rises above
    /// `goal` — a vary roll may soften a target but never asks for more than
    /// the member's own goal.
    ///
    /// Rounding is HALF-UP (`.rounded()` = `.toNearestOrAwayFromZero`),
    /// matching JS `Math.round` on the positive values this ever sees. Do
    /// NOT substitute `.toNearestOrEven` — the fixture pins ties.
    ///
    /// - Parameters:
    ///   - t: The pre-vary target.
    ///   - level: Vary level (`.off` = no spread).
    ///   - goal: The member's own `maxCount`, the hard ceiling.
    /// - Returns: The inclusive range.
    static func varyRange(t: Int, level: VaryLevel, goal: Int) -> ClosedRange<Int> {
        let clamped = Swift.min(Swift.max(1, t), goal)
        let fraction = varyFraction(level)
        let lo = Swift.max(1, Int((Double(clamped) * (1 - fraction)).rounded()))
        let hi = Swift.min(goal, Int((Double(clamped) * (1 + fraction)).rounded()))
        // `lo <= hi` holds for every `goal >= 1` (the only reachable input —
        // `goalOf` filters the rest); the outer `max` only stops a malformed
        // `goal < 1` from trapping on an inverted ClosedRange, where the TS
        // twin would merely return a nonsense tuple.
        return lo...Swift.max(lo, hi)
    }

    /// Uniform whole-number roll inside ``varyRange(t:level:goal:)``.
    /// `.off` never touches `rng`, and neither does a degenerate range
    /// (`lo == hi`) — which is what keeps a seeded sequence reproducible
    /// across platforms.
    ///
    /// - Parameters:
    ///   - t: The pre-vary target.
    ///   - level: Vary level (`.off` = no spread).
    ///   - goal: The member's own `maxCount`, the hard ceiling.
    ///   - rng: Uniform `[0, 1)` source; consumed at most once.
    /// - Returns: The rolled target (integer inside the range).
    static func rollTarget(t: Int, level: VaryLevel, goal: Int, rng: () -> Double) -> Int {
        let range = varyRange(t: t, level: level, goal: goal)
        if level == .off || range.lowerBound == range.upperBound { return range.lowerBound }
        let span = range.upperBound - range.lowerBound + 1
        return range.lowerBound + Int((rng() * Double(span)).rounded(.down))
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

    /// Which kind of board is being assembled — auto targets apply to
    /// `.recurring` only.
    enum PlanMode {
        case oneOff
        case recurring
    }

    /// The window a board (or a pulled source board) covers.
    struct BoardWindow {
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
        let maxCount: Int
        /// Event-derived lifetime count at mint time — a cache, never authored.
        let baseline: Int
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
        let children: [DerivedCompoundChildDraft]
    }

    /// Output of ``planDerivedTasks(selectedIds:supplies:manualTaskIds:manualTaskVary:boardId:window:mode:tasksById:childrenByCompoundId:sourceWindowByTaskId:baselineByRootId:rng:)``.
    struct PlanDerivedTasksResult: Equatable {
        /// What actually lands in `board_tasks`, in `selectedIds` order.
        let placementIds: [String]
        let derivedTasks: [DerivedTaskDraft]
        let derivedCompounds: [DerivedCompoundDraft]
    }

    /// A member is already a window-stamped derived counter when it has both marks.
    private static func isWindowStampedDerived(_ task: Task) -> Bool {
        !(task.sharedCounterId ?? "").isEmpty && !(task.startDate ?? "").isEmpty
    }

    /// A counting task's own goal, or `nil` when it is goal-less (an
    /// accumulator, which has no target to pro-rate or vary).
    private static func goalOf(_ task: Task) -> Int? {
        guard let maxCount = task.maxCount, maxCount >= 1 else { return nil }
        return maxCount
    }

    /// One child of a One-square compound, plus the decision made about it.
    private struct ChildPlan {
        let link: CompoundChild
        let child: Task?
        let derive: Bool
        let target: Int
        let vary: VaryLevel
    }

    /// Spec step 3 — decide, per selected id, whether it is placed as-is or
    /// replaced by a window-stamped derived counter / derived compound.
    ///
    /// Pure and deterministic for a seeded `rng`: at most one sample per
    /// roll, taken in `selectedIds` order (and within a compound, in
    /// `childIndex` order); a `.off` or degenerate range takes none. Drafts
    /// are in-memory only — B2 materialises them before the `board_tasks`
    /// rows in one transaction.
    ///
    /// Precedence, in order: hand-added beats any source copy; among
    /// sources, the FIRST supply that lists the id wins; a split part reads
    /// its part rule (the parent's member-level `vary` is deliberately
    /// ignored in split mode); a `target` — member-level OR part-level — is
    /// honoured on board sources only (a pool member offers vary / split /
    /// part-exclusion and nothing else).
    ///
    /// Collapse rule, mirrored verbatim from the TS twin: two things that
    /// share a shared-counter root resolve to ONE derived counter (the first
    /// one's roll). The dedupe is checked BEFORE the roll, so a collapsed
    /// occurrence consumes no rng sample. Two collapsed SELECTED members
    /// still both push that one derived id into `placementIds`, so the same
    /// id can appear twice there — B2 must dedupe before writing
    /// `board_tasks`. Two collapsed PARTS of one One-square compound are
    /// deduped here instead (first in `childIndex` order wins, keeping its
    /// own `childIndex`/`linkId`), because `derivedLinkId` is a pure function
    /// of `(compound, child)`: a repeated `childTaskId` is one
    /// `compound_children` primary key written twice, and a compound whose
    /// `threshold` counts children would count one child twice.
    /// Counter-family exclusivity constrains board *selection*, not compound
    /// *authorship*, so the part case is ordinary user data while the member
    /// case is belt-and-braces.
    ///
    /// - Parameters:
    ///   - selectedIds: The task ids picked for the board, in placement order.
    ///   - supplies: Per-source supplies, already Split-up expanded.
    ///   - manualTaskIds: Hand-added ids — they win over any source copy.
    ///   - manualTaskVary: Hand-added id → its dice.
    ///   - boardId: The board being assembled (seeds every derived id).
    ///   - window: The board's window; every derived draft is stamped with it.
    ///   - mode: Auto targets apply to `.recurring` only.
    ///   - tasksById: Id → task, for every selected id and compound child.
    ///   - childrenByCompoundId: Compound id → its `compound_children` rows.
    ///   - sourceWindowByTaskId: Task id → the window of the source board it
    ///     came from. Keyed by every id whose source window matters —
    ///     supplied members AND the children of a One-square compound (a
    ///     compound's parts are pro-rated by looking up the CHILD's id,
    ///     never the compound's).
    ///   - baselineByRootId: Shared-counter root id → its event-derived lifetime count.
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
        baselineByRootId: [String: Int],
        rng: () -> Double
    ) -> PlanDerivedTasksResult {
        let manual = Set(manualTaskIds)
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
        /// The pre-vary target. The final `min(max(1, floor(base)), goal)`
        /// clamp is redundant for integer targets (`varyRange` re-clamps `t`
        /// to `1…goal` identically) and is only observable on a fractional
        /// explicit target, which Zod already forbids — kept verbatim so the
        /// two platforms can never disagree about a malformed stored rule.
        func resolveTarget(
            goal: Int,
            explicit: Int?,
            fromBoard: Bool,
            taskIdForWindow: String
        ) -> Int {
            let base: Double
            if let explicit {
                base = Double(explicit)
            } else if fromBoard && mode == .recurring {
                base = Double(autoTarget(
                    goal: goal,
                    sourceDays: sourceDaysFor(taskIdForWindow),
                    targetDays: targetDays
                ))
            } else {
                base = Double(goal)
            }
            return Swift.min(Swift.max(1, Int(base.rounded(.down))), goal)
        }
        func mint(_ task: Task, replacesId: String, target: Int, vary: VaryLevel) -> DerivedTaskDraft {
            // `goalOf` is non-nil at every call site (each branch checks first).
            let goal = goalOf(task) ?? 1
            let root = task.sharedCounterId ?? task.id
            // The dedupe is checked BEFORE the roll: a collapsed occurrence
            // consumes no rng sample, so a seeded sequence reproduces
            // identically on both platforms (TS twin, verbatim).
            if let existing = derivedByRoot[root] { return existing }
            let maxCount = rollTarget(t: target, level: vary, goal: goal, rng: rng)
            let action = task.action ?? ""
            let unit = task.unit ?? ""
            let draft = DerivedTaskDraft(
                id: derivedTaskId(boardId: boardId, rootTaskId: root),
                rootTaskId: root,
                sourceMemberId: task.id,
                replacesId: replacesId,
                maxCount: maxCount,
                baseline: baselineByRootId[root] ?? 0,
                title: TaskTitle.generateCounterTaskTitle(
                    action: action,
                    maxCount: maxCount,
                    unit: unit,
                    providedTitle: action.isEmpty ? task.title : nil
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
                guard let goal = goalOf(task) else {
                    placementIds.append(id)
                    continue
                }
                if isManual {
                    let vary = manualTaskVary[id] ?? .off
                    // A member that is ALREADY window-stamped is re-minted
                    // for this window.
                    if isWindowStampedDerived(task) {
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
                            taskIdForWindow: id
                        )
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
                        taskIdForWindow: id
                    )
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
                        taskIdForWindow: link.childTaskId
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
}
