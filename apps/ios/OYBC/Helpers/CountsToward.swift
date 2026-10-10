import Foundation

// MARK: - "Counts toward" — pure half
//
// Swift twin of `packages/shared/src/algorithms/countsToward.ts`
// (docs/SHARED_COUNTER_SETTINGS.md §3). A contributing task carries
// `countsTowardCounterId` (+ `countsTowardAmount`, nil = 1). When its derived
// LIFETIME state becomes complete, the counter ROOT receives ONE increment
// with the deterministic id `eventId(contributingTaskId:)`, stamped at the
// completion instant; when it becomes incomplete again that event is
// tombstoned. The write lives in the cascade (`AppDatabase+CountsToward.swift`).
//
// Pinned by `countsTowardVectors.json` (`CountsTowardVectorTests`). A change
// here is a change in two places.
enum CountsToward {

    /// uuidv5 name prefix for a contributing task's counts-toward increment.
    static let namespace = "counts-toward:event"

    /// Deterministic id of the increment `contributingTaskId` writes on its root.
    static func eventId(contributingTaskId: String) -> String {
        UUIDv5.uuidv5(name: "\(namespace):\(contributingTaskId)")
    }

    /// The increment a contributor writes: `countsTowardAmount`, or 1 when absent / not positive.
    static func amount(of task: Task) -> Int {
        if let a = task.countsTowardAmount, a > 0 { return a }
        return 1
    }

    /// A task's lifetime completion and the instant it completed.
    struct ContributionState: Equatable {
        let isCompleted: Bool
        /// ISO instant the task became complete; `nil` when incomplete.
        let completedAt: String?

        static let incomplete = ContributionState(isCompleted: false, completedAt: nil)
    }

    private static func ms(_ iso: String) -> Double {
        DateFormatting.parseISO(iso)?.timeIntervalSince1970 ?? .nan
    }

    /// Ascending by parsed instant, then by string (deterministic ties).
    private static func sortInstants(_ instants: [String]) -> [String] {
        instants.sorted { a, b in
            let (ma, mb) = (ms(a), ms(b))
            if ma != mb { return ma < mb }
            return a < b
        }
    }

    /// The `occurredAt` of the increment that last carried the running sum from
    /// below `target` to at-or-above it, or `nil` when it never did.
    private static func crossingInstant(_ events: [TaskEvent], target: CountValue) -> String? {
        let live = events
            .filter { !$0.isDeleted && $0.kind == .increment }
            .sorted { a, b in
                let (ma, mb) = (ms(a.occurredAt), ms(b.occurredAt))
                if ma != mb { return ma < mb }
                return a.id < b.id
            }
        var sum: CountValue = 0
        var at: String?
        for e in live {
            let prev = sum
            sum = quantizeCount(sum + (e.delta ?? 0))
            if prev < target && sum >= target { at = e.occurredAt } else if sum < target { at = nil }
        }
        return at
    }

    private static func latchState(_ task: Task) -> ContributionState {
        task.isCompleted ? ContributionState(isCompleted: true, completedAt: task.completedAt) : .incomplete
    }

    private static func stateOf(
        _ task: Task,
        childrenByCompound: [String: [CompoundChild]],
        taskById: [String: Task],
        eventsByTaskId: [String: [TaskEvent]],
        visiting: inout Set<String>
    ) -> ContributionState {
        if task.isDeleted { return .incomplete }
        switch task.type {
        case .normal:
            let done = (eventsByTaskId[task.id] ?? []).filter { !$0.isDeleted && $0.kind == .completion }
            guard !done.isEmpty else { return .incomplete }
            return ContributionState(isCompleted: true, completedAt: sortInstants(done.map(\.occurredAt)).first)
        case .counting:
            if let rootId = task.sharedCounterId, !rootId.isEmpty {
                guard BoardSources.isWindowStampedDerived(task) else { return latchState(task) }
                let rootEvents = eventsByTaskId[rootId] ?? []
                guard resolveWindowStampedDerivedState(task: task, rootEvents: rootEvents).isCompleted else {
                    return .incomplete
                }
                let inWindow = rootEvents.filter {
                    DateFormatting.isWithinTimeframe($0.occurredAt, startDate: task.startDate ?? "", endDate: task.endDate)
                }
                return ContributionState(isCompleted: true, completedAt: crossingInstant(inWindow, target: task.maxCount ?? 0))
            }
            let events = eventsByTaskId[task.id] ?? []
            guard resolveTaskWindowState(task: task, events: events, windowStart: nil, windowEnd: nil).isCompleted else {
                return .incomplete
            }
            return ContributionState(isCompleted: true, completedAt: crossingInstant(events, target: task.maxCount ?? 0))
        case .compound:
            break
        default:
            return latchState(task)
        }

        if visiting.contains(task.id) { return .incomplete }
        visiting.insert(task.id)
        var childStates: [ContributionState] = []
        for link in (childrenByCompound[task.id] ?? []) where !link.isDeleted {
            guard let child = taskById[link.childTaskId], !child.isDeleted else {
                childStates.append(.incomplete)
                continue
            }
            childStates.append(stateOf(
                child, childrenByCompound: childrenByCompound, taskById: taskById,
                eventsByTaskId: eventsByTaskId, visiting: &visiting
            ))
        }
        visiting.remove(task.id)

        if childStates.isEmpty {
            // Mirrors `CompoundEvaluation`: AND over nothing is vacuously true —
            // except an unfilled counts-toward container (§3a).
            let vacuous = task.operatorType == .and && task.countsTowardCounterId == nil
            return vacuous ? ContributionState(isCompleted: true, completedAt: nil) : .incomplete
        }
        let done = childStates.filter(\.isCompleted)
        let instants = sortInstants(done.compactMap(\.completedAt))
        func nth(_ n: Int) -> String? { instants.isEmpty ? nil : instants[min(n, instants.count) - 1] }

        switch task.operatorType {
        case .and:
            return done.count == childStates.count ? ContributionState(isCompleted: true, completedAt: nth(instants.count)) : .incomplete
        case .or:
            return done.isEmpty ? .incomplete : ContributionState(isCompleted: true, completedAt: nth(1))
        case .mOfN:
            let required = max(1, task.threshold ?? 1)
            return done.count >= required ? ContributionState(isCompleted: true, completedAt: nth(required)) : .incomplete
        case nil:
            return .incomplete
        }
    }

    /// A task's LIFETIME completion as "counts toward" reads it, and the instant
    /// it became complete (twin of the TS `resolveContributionState` — see its
    /// doc for the per-type rules). A complete task whose instant can't be
    /// derived falls back to its own `createdAt`.
    static func resolveContributionState(
        _ task: Task,
        childrenByCompound: [String: [CompoundChild]],
        taskById: [String: Task],
        eventsByTaskId: [String: [TaskEvent]]
    ) -> ContributionState {
        var visiting = Set<String>()
        let s = stateOf(
            task, childrenByCompound: childrenByCompound, taskById: taskById,
            eventsByTaskId: eventsByTaskId, visiting: &visiting
        )
        guard s.isCompleted else { return .incomplete }
        return ContributionState(isCompleted: true, completedAt: s.completedAt ?? task.createdAt)
    }

    /// A live, unlinked, Discrete counting row (root-ness is a write-time rule).
    static func isTarget(_ task: Task?) -> Bool {
        guard let task else { return false }
        return !task.isDeleted && task.type == .counting && task.sharedCounterId == nil
            && resolveCountKind(task.countKind) == .discrete
    }

    /// One write the cascade makes for a contributing task.
    enum Action: Equatable {
        case insert(eventId: String, rootId: String, delta: Int, occurredAt: String)
        /// Update a stored event in place (amount / instant / counter moved, or a revive).
        case revise(
            eventId: String, rootId: String, delta: Int, occurredAt: String,
            previousRootId: String, previousOccurredAt: String, wasDeleted: Bool
        )
        case tombstone(eventId: String, rootId: String, occurredAt: String)

        /// The root the action writes on, and the instant it reaches.
        var reach: [(rootId: String, occurredAt: String)] {
            switch self {
            case let .insert(_, rootId, _, occurredAt), let .tombstone(_, rootId, occurredAt):
                return [(rootId, occurredAt)]
            case let .revise(_, rootId, _, occurredAt, previousRootId, previousOccurredAt, _):
                return [(rootId, occurredAt), (previousRootId, previousOccurredAt)]
            }
        }
    }

    /// Decide the write a contributor needs (twin of the TS
    /// `planCountsTowardAction`): insert / revise / tombstone, or `nil` when
    /// nothing changes. A deleted (or not-yet-pulled) counter keeps its events.
    static func plan(
        contributor: Task,
        taskById: [String: Task],
        state: ContributionState,
        existing: TaskEvent?
    ) -> Action? {
        let id = eventId(contributingTaskId: contributor.id)
        let targetId = contributor.countsTowardCounterId
        let target = targetId.flatMap { taskById[$0] }
        if targetId != nil, target == nil || target?.isDeleted == true { return nil }

        var wanted: (rootId: String, delta: Int, occurredAt: String)?
        if !contributor.isDeleted, isTarget(target), let target, state.isCompleted, let at = state.completedAt {
            wanted = (target.id, amount(of: contributor), at)
        }

        if let existing, !existing.isDeleted {
            guard let wanted else {
                guard let root = taskById[existing.taskId], !root.isDeleted else { return nil }
                return .tombstone(eventId: id, rootId: root.id, occurredAt: existing.occurredAt)
            }
            let same = existing.kind == .increment && existing.taskId == wanted.rootId
                && existing.delta == CountValue(wanted.delta) && ms(existing.occurredAt) == ms(wanted.occurredAt)
            if same { return nil }
            return .revise(
                eventId: id, rootId: wanted.rootId, delta: wanted.delta, occurredAt: wanted.occurredAt,
                previousRootId: existing.taskId, previousOccurredAt: existing.occurredAt, wasDeleted: false
            )
        }
        guard let wanted else { return nil }
        if let existing {
            return .revise(
                eventId: id, rootId: wanted.rootId, delta: wanted.delta, occurredAt: wanted.occurredAt,
                previousRootId: existing.taskId, previousOccurredAt: existing.occurredAt, wasDeleted: true
            )
        }
        return .insert(eventId: id, rootId: wanted.rootId, delta: wanted.delta, occurredAt: wanted.occurredAt)
    }

    /// Why a counts-toward assignment is refused at write time.
    enum Problem: String, Equatable {
        case selfTarget = "self"
        case contributorIsCounter = "contributor-is-counter"
        case contributorIsLinked = "contributor-is-linked"
        case contributorIsAchievement = "contributor-is-achievement"
        case targetNotCounter = "target-not-counter"
        case targetNotDiscrete = "target-not-discrete"
        case invalidAmount = "invalid-amount"
        case cycle
    }

    /// A hub counter, or a task other live rows link to via `sharedCounterId`.
    static func isSharedCounterRoot(_ task: Task, tasks: [Task]) -> Bool {
        task.isCounter || tasks.contains { !$0.isDeleted && $0.sharedCounterId == task.id }
    }

    /// Write-time validation for `task.countsTowardCounterId = targetId` (twin
    /// of the TS `countsTowardProblem`).
    static func problem(
        task: Task, targetId: String, amount: Double?, tasks: [Task], children: [CompoundChild]
    ) -> Problem? {
        if targetId == task.id { return .selfTarget }
        if task.type == .achievement { return .contributorIsAchievement }
        if task.sharedCounterId != nil { return .contributorIsLinked }
        if isSharedCounterRoot(task, tasks: tasks) { return .contributorIsCounter }
        guard let target = tasks.first(where: { $0.id == targetId }), !target.isDeleted,
              target.type == .counting, target.sharedCounterId == nil,
              isSharedCounterRoot(target, tasks: tasks) else { return .targetNotCounter }
        if resolveCountKind(target.countKind) != .discrete { return .targetNotDiscrete }
        if let amount, !(amount > 0 && amount == amount.rounded()) { return .invalidAmount }

        let byId = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var seen: Set<String> = [task.id]
        var stack = [task.id]
        while let parent = stack.popLast() {
            for link in children where !link.isDeleted && link.compoundTaskId == parent && !seen.contains(link.childTaskId) {
                seen.insert(link.childTaskId)
                if let child = byId[link.childTaskId], child.id == targetId || child.sharedCounterId == targetId {
                    return .cycle
                }
                stack.append(link.childTaskId)
            }
        }
        return nil
    }
}
