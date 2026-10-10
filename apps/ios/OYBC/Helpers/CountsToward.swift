import Foundation

// MARK: - "Counts toward" — pure half
//
// Swift twin of `packages/shared/src/algorithms/countsToward.ts`
// (docs/SHARED_COUNTER_SETTINGS.md §3). A contributing task carries
// `countsTowardCounterId` (+ `countsTowardAmount`, nil = 1). Its counter ROOT
// receives ONE increment per COMPLETION OCCURRENCE of the contributor (D10,
// ruled 2026-10-10 — a manual square on a repeating weekly board is the SAME
// task every week and counts every week it is completed). Each occurrence has
// a stable key and a deterministic credit id (`eventId(contributorId:occurrence:)`);
// a withdrawn occurrence (an undo, a removed placement, a cleared flag) has its
// credit tombstoned. The write lives in the cascade (`AppDatabase+CountsToward.swift`).
//
// Occurrence keys per contributor type: NORMAL — one per live completion event
// (key = the event id); plain COUNTING — one per live placement window in which
// its windowed state is complete (key = the crossing increment's id; unplaced →
// the lifetime evaluation, same key); COMPOUND — one per live placement window
// in which its derivation is complete (key = `window:<board startDate>`;
// unplaced → `lifetime`). An event key omits the contributor id, and a
// board-scoped fork's copied event (`BoardScopedFork.forkedEventId`) resolves to
// its SOURCE event through the `forkedFromTaskId` lineage, so the original and
// the fork share one credit.
//
// Pinned by `countsTowardVectors.json` (`CountsTowardVectorTests`). A change
// here is a change in two places.
enum CountsToward {

    /// uuidv5 name prefix for a contributing task's counts-toward increments.
    static let namespace = "counts-toward:event"

    /// One completion occurrence of a contributor — the key its credit is minted under.
    enum Occurrence: Equatable, Hashable {
        case event(eventId: String)
        case window(startDate: String)
        case lifetime
    }

    /// Deterministic id of the credit `contributorId` writes on its root for
    /// `occurrence` (twin of the TS `countsTowardEventId`): an event key is
    /// globally unique, so the contributor is NOT part of its name.
    static func eventId(contributorId: String, occurrence: Occurrence) -> String {
        switch occurrence {
        case let .event(eventId):
            return UUIDv5.uuidv5(name: "\(namespace):\(eventId)")
        case let .window(startDate):
            return UUIDv5.uuidv5(name: "\(namespace):\(contributorId):window:\(startDate)")
        case .lifetime:
            return UUIDv5.uuidv5(name: "\(namespace):\(contributorId):lifetime")
        }
    }

    /// The increment a contributor writes: `countsTowardAmount`, or 1 when absent / not positive.
    static func amount(of task: Task) -> Int {
        if let a = task.countsTowardAmount, a > 0 { return a }
        return 1
    }

    /// A task's completion (over one window) and the instant it completed.
    struct ContributionState: Equatable {
        let isCompleted: Bool
        /// ISO instant the task became complete; `nil` when incomplete.
        let completedAt: String?
        /// For an event-owning contributor: the event that completed it.
        let completingEventId: String?

        init(isCompleted: Bool, completedAt: String?, completingEventId: String? = nil) {
            self.isCompleted = isCompleted
            self.completedAt = completedAt
            self.completingEventId = completingEventId
        }

        static let incomplete = ContributionState(isCompleted: false, completedAt: nil)
    }

    /// A window a contribution is evaluated over (`nil` bounds = lifetime).
    struct Window {
        let windowStart: String?
        let windowEnd: String?
        static let lifetime = Window(windowStart: nil, windowEnd: nil)
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

    /// Live events whose `occurredAt` falls inside `[windowStart, windowEnd]` (inclusive; `nil` = unbounded).
    private static func eventsInWindow(_ events: [TaskEvent], _ ctx: CompoundWindowContext) -> [TaskEvent] {
        let lower = ctx.windowStart.map(ms)
        let upper = ctx.windowEnd.map(ms)
        return events.filter { e in
            if e.isDeleted { return false }
            let t = ms(e.occurredAt)
            if let lower, !(t >= lower) { return false }
            if let upper, !(t <= upper) { return false }
            return true
        }
    }

    /// The increment that last carried the running sum from below `target` to
    /// at-or-above it, or `nil` when it never did.
    private static func crossingEvent(_ events: [TaskEvent], target: CountValue) -> TaskEvent? {
        let live = events
            .filter { !$0.isDeleted && $0.kind == .increment }
            .sorted { a, b in
                let (ma, mb) = (ms(a.occurredAt), ms(b.occurredAt))
                if ma != mb { return ma < mb }
                return a.id < b.id
            }
        var sum: CountValue = 0
        var at: TaskEvent?
        for e in live {
            let prev = sum
            sum = quantizeCount(sum + (e.delta ?? 0))
            if prev < target && sum >= target { at = e } else if sum < target { at = nil }
        }
        return at
    }

    private static func completed(by event: TaskEvent?) -> ContributionState {
        guard let event else { return .incomplete }
        return ContributionState(isCompleted: true, completedAt: event.occurredAt, completingEventId: event.id)
    }

    private static func latchState(_ task: Task) -> ContributionState {
        task.isCompleted ? ContributionState(isCompleted: true, completedAt: task.completedAt) : .incomplete
    }

    private static func stateOf(
        _ task: Task,
        ctx: CompoundWindowContext,
        childrenByCompound: [String: [CompoundChild]],
        taskById: [String: Task],
        visiting: inout Set<String>
    ) -> ContributionState {
        if task.isDeleted { return .incomplete }
        switch task.type {
        case .normal:
            let events = ctx.eventsByTaskId[task.id] ?? []
            guard resolveTaskWindowState(task: task, events: events, windowStart: ctx.windowStart, windowEnd: ctx.windowEnd).isCompleted else {
                return .incomplete
            }
            let done = eventsInWindow(events, ctx)
                .filter { $0.kind == .completion }
                .sorted { a, b in
                    let (ma, mb) = (ms(a.occurredAt), ms(b.occurredAt))
                    if ma != mb { return ma < mb }
                    return a.id < b.id
                }
            return completed(by: done.first)
        case .counting:
            if let rootId = task.sharedCounterId, !rootId.isEmpty {
                let rootEvents = ctx.eventsByTaskId[rootId] ?? []
                if BoardSources.isWindowStampedDerived(task) {
                    guard resolveWindowStampedDerivedState(task: task, rootEvents: rootEvents).isCompleted else { return .incomplete }
                    let own = CompoundWindowContext(windowStart: task.startDate, windowEnd: task.endDate, eventsByTaskId: [:])
                    return completed(by: crossingEvent(eventsInWindow(rootEvents, own), target: task.maxCount ?? 0))
                }
                // Owner rule 2026-10-01: any other linked row on a board resolves
                // over the HOST window; only a lifetime reader still reads its latch.
                guard let derived = resolveDerivedCounterWindowState(
                    task: task, eventsByTaskId: ctx.eventsByTaskId, windowStart: ctx.windowStart, windowEnd: ctx.windowEnd
                ) else { return latchState(task) }
                guard derived.isCompleted else { return .incomplete }
                return completed(by: crossingEvent(eventsInWindow(rootEvents, ctx), target: task.maxCount ?? 0))
            }
            let events = ctx.eventsByTaskId[task.id] ?? []
            guard resolveTaskWindowState(task: task, events: events, windowStart: ctx.windowStart, windowEnd: ctx.windowEnd).isCompleted else {
                return .incomplete
            }
            return completed(by: crossingEvent(eventsInWindow(events, ctx), target: task.maxCount ?? 0))
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
                child, ctx: ctx, childrenByCompound: childrenByCompound, taskById: taskById, visiting: &visiting
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

    /// A task's completion as "counts toward" reads it over `window` (default
    /// lifetime), and the instant it became complete (twin of the TS
    /// `resolveContributionState` — see its doc for the per-type rules). A
    /// complete task whose instant can't be derived falls back to its own
    /// `createdAt`. A sealed board's caller bounds `eventsByTaskId` at `sealedAt` first.
    static func resolveContributionState(
        _ task: Task,
        childrenByCompound: [String: [CompoundChild]],
        taskById: [String: Task],
        eventsByTaskId: [String: [TaskEvent]],
        window: Window = .lifetime
    ) -> ContributionState {
        let ctx = CompoundWindowContext(windowStart: window.windowStart, windowEnd: window.windowEnd, eventsByTaskId: eventsByTaskId)
        var visiting = Set<String>()
        let s = stateOf(task, ctx: ctx, childrenByCompound: childrenByCompound, taskById: taskById, visiting: &visiting)
        guard s.isCompleted else { return .incomplete }
        return ContributionState(isCompleted: true, completedAt: s.completedAt ?? task.createdAt, completingEventId: s.completingEventId)
    }

    /// The data a contributor's credits are derived from (twin of the TS `ContributionInputs`).
    struct Inputs {
        /// Every task by id (resolves the counter root, compound children, fork lineage).
        var taskById: [String: Task]
        /// `compoundTaskId` → links (deleted ones ignored).
        var childrenByCompound: [String: [CompoundChild]]
        /// Non-deleted events grouped by `taskId` (the kernel convention).
        var eventsByTaskId: [String: [TaskEvent]]
        /// EVERY event (tombstones included) of the contributor and its fork ancestors, by `taskId`.
        var allEventsByTaskId: [String: [TaskEvent]]
        /// The contributor's placements, any state (rows for other tasks are ignored).
        var placements: [BoardTask]
        /// Boards referenced by `placements`, any state. A board absent here is treated as not live.
        var boardById: [String: Board]
    }

    /// One credit a contributor wants on its counter root.
    struct Credit: Equatable {
        /// The credit's deterministic id (`eventId(contributorId:occurrence:)`).
        let eventId: String
        let occurrence: Occurrence
        /// The completion instant the credit is stamped at.
        let occurredAt: String
    }

    /// Deepest `forkedFromTaskId` chain followed when resolving a copied event.
    private static let maxForkLineage = 8

    /// The SOURCE event id an event of `task` is keyed by (twin of the TS
    /// `canonicalOccurrenceEventId`): a board-scoped fork's copied event
    /// resolves to the original's event, transitively up the lineage; any
    /// other event is its own key.
    static func canonicalOccurrenceEventId(
        _ eventId: String, task: Task, taskById: [String: Task], allEventsByTaskId: [String: [TaskEvent]]
    ) -> String {
        var current = task
        var id = eventId
        for _ in 0..<maxForkLineage {
            guard let sourceId = current.forkedFromTaskId, let source = taskById[sourceId] else { return id }
            guard let match = (allEventsByTaskId[sourceId] ?? []).first(where: {
                BoardScopedFork.forkedEventId(forkId: current.id, eventId: $0.id) == id
            }) else { return id }
            id = match.id
            current = source
        }
        return id
    }

    /// The live boards placing `task`, each as the window its square is
    /// evaluated over (sealed → events bounded at `sealedAt`), by start date.
    private static func liveWindows(of task: Task, inputs: Inputs) -> [(startDate: String, ctx: CompoundWindowContext)] {
        var seen = Set<String>()
        var out: [(startDate: String, ctx: CompoundWindowContext)] = []
        for p in inputs.placements where !p.isDeleted && p.taskId == task.id && !seen.contains(p.boardId) {
            seen.insert(p.boardId)
            guard let b = inputs.boardById[p.boardId], !b.isDeleted, b.status != .draft else { continue }
            let sealedAtMs = b.sealedAt.map { ms($0) * 1000 } ?? .nan
            let events = sealedAtMs.isNaN
                ? inputs.eventsByTaskId
                : boundWindowContextAtSeal(eventsByTaskId: inputs.eventsByTaskId, sealedAtMs: sealedAtMs).eventsByTaskId
            out.append((b.startDate, CompoundWindowContext(windowStart: b.startDate, windowEnd: boardWindowEnd(b), eventsByTaskId: events)))
        }
        return out.sorted { a, b in
            let (ma, mb) = (ms(a.startDate), ms(b.startDate))
            if ma != mb { return ma < mb }
            return a.startDate < b.startDate
        }
    }

    /// The credits `task` WANTS on its counter root, from live data (twin of
    /// the TS `resolveContributionCredits` — see its doc for the per-type
    /// rules). Does NOT consult the flag or the target: `plan` applies those.
    static func resolveContributionCredits(_ task: Task, inputs: Inputs) -> [Credit] {
        if task.isDeleted { return [] }
        var byId: [String: Credit] = [:]
        func want(_ occurrence: Occurrence, _ occurredAt: String) {
            let id = eventId(contributorId: task.id, occurrence: occurrence)
            if let prior = byId[id], !(ms(occurredAt) < ms(prior.occurredAt)) { return }
            byId[id] = Credit(eventId: id, occurrence: occurrence, occurredAt: occurredAt)
        }
        func eventKey(_ eventId: String) -> Occurrence {
            .event(eventId: canonicalOccurrenceEventId(eventId, task: task, taskById: inputs.taskById, allEventsByTaskId: inputs.allEventsByTaskId))
        }

        switch task.type {
        case .normal:
            for e in inputs.eventsByTaskId[task.id] ?? [] where !e.isDeleted && e.kind == .completion {
                want(eventKey(e.id), e.occurredAt)
            }
        case .counting:
            if let rootId = task.sharedCounterId, !rootId.isEmpty { return [] }
            let windows = liveWindows(of: task, inputs: inputs)
            let contexts = windows.isEmpty
                ? [CompoundWindowContext(windowStart: nil, windowEnd: nil, eventsByTaskId: inputs.eventsByTaskId)]
                : windows.map(\.ctx)
            for ctx in contexts {
                let s = resolveContributionState(
                    task, childrenByCompound: inputs.childrenByCompound, taskById: inputs.taskById,
                    eventsByTaskId: ctx.eventsByTaskId, window: Window(windowStart: ctx.windowStart, windowEnd: ctx.windowEnd)
                )
                if s.isCompleted, let crossing = s.completingEventId, let at = s.completedAt { want(eventKey(crossing), at) }
            }
        case .compound:
            let windows = liveWindows(of: task, inputs: inputs)
            if windows.isEmpty {
                let s = resolveContributionState(
                    task, childrenByCompound: inputs.childrenByCompound, taskById: inputs.taskById, eventsByTaskId: inputs.eventsByTaskId
                )
                if s.isCompleted, let at = s.completedAt { want(.lifetime, at) }
            }
            for w in windows {
                let s = resolveContributionState(
                    task, childrenByCompound: inputs.childrenByCompound, taskById: inputs.taskById,
                    eventsByTaskId: w.ctx.eventsByTaskId, window: Window(windowStart: w.ctx.windowStart, windowEnd: w.ctx.windowEnd)
                )
                if s.isCompleted, let at = s.completedAt { want(.window(startDate: w.startDate), at) }
            }
        case .achievement:
            return []
        }
        return byId.values.sorted { $0.eventId < $1.eventId }
    }

    /// Every credit id `task` MAY own — a superset of `resolveContributionCredits`
    /// built from live AND tombstoned data (twin of the TS `candidateContributionIds`).
    static func candidateContributionIds(_ task: Task, inputs: Inputs) -> [String] {
        var ids = Set<String>()
        for e in inputs.allEventsByTaskId[task.id] ?? [] {
            ids.insert(eventId(contributorId: task.id, occurrence: .event(eventId: e.id)))
            ids.insert(eventId(contributorId: task.id, occurrence: .event(eventId: canonicalOccurrenceEventId(
                e.id, task: task, taskById: inputs.taskById, allEventsByTaskId: inputs.allEventsByTaskId
            ))))
        }
        for p in inputs.placements where p.taskId == task.id {
            if let b = inputs.boardById[p.boardId] {
                ids.insert(eventId(contributorId: task.id, occurrence: .window(startDate: b.startDate)))
            }
        }
        ids.insert(eventId(contributorId: task.id, occurrence: .lifetime))
        return ids.sorted()
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

        /// The credit this action writes.
        var eventId: String {
            switch self {
            case let .insert(eventId, _, _, _), let .tombstone(eventId, _, _), let .revise(eventId, _, _, _, _, _, _):
                return eventId
            }
        }

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

    /// Reconcile a contributor's credit SET (twin of the TS
    /// `planCountsTowardActions`): compare the wanted credits with the stored
    /// events at every candidate id — insert / revise / tombstone per id, in
    /// id order; nothing for an identical live row; nothing at all while the
    /// counter is deleted (or not pulled yet).
    static func plan(
        contributor: Task,
        taskById: [String: Task],
        wanted: [Credit],
        candidateIds: [String],
        storedById: [String: TaskEvent]
    ) -> [Action] {
        let targetId = contributor.countsTowardCounterId
        let target = targetId.flatMap { taskById[$0] }
        if targetId != nil, target == nil || target?.isDeleted == true { return [] }

        var wantedById: [String: (rootId: String, delta: Int, occurredAt: String)] = [:]
        if !contributor.isDeleted, isTarget(target), let target {
            for w in wanted { wantedById[w.eventId] = (target.id, amount(of: contributor), w.occurredAt) }
        }
        let ids = Set(wantedById.keys).union(candidateIds).sorted()

        var actions: [Action] = []
        for id in ids {
            let existing = storedById[id]
            let want = wantedById[id]
            if let existing, !existing.isDeleted {
                guard let want else {
                    guard let root = taskById[existing.taskId], !root.isDeleted else { continue }
                    actions.append(.tombstone(eventId: id, rootId: root.id, occurredAt: existing.occurredAt))
                    continue
                }
                let same = existing.kind == .increment && existing.taskId == want.rootId
                    && existing.delta == CountValue(want.delta) && ms(existing.occurredAt) == ms(want.occurredAt)
                if same { continue }
                actions.append(.revise(
                    eventId: id, rootId: want.rootId, delta: want.delta, occurredAt: want.occurredAt,
                    previousRootId: existing.taskId, previousOccurredAt: existing.occurredAt, wasDeleted: false
                ))
                continue
            }
            guard let want else { continue }
            if let existing {
                actions.append(.revise(
                    eventId: id, rootId: want.rootId, delta: want.delta, occurredAt: want.occurredAt,
                    previousRootId: existing.taskId, previousOccurredAt: existing.occurredAt, wasDeleted: true
                ))
                continue
            }
            actions.append(.insert(eventId: id, rootId: want.rootId, delta: want.delta, occurredAt: want.occurredAt))
        }
        return actions
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
