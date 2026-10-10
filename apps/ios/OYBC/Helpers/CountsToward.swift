import Foundation

// MARK: - "Counts toward" — pure half
//
// Swift twin of `packages/shared/src/algorithms/countsToward.ts`
// (docs/SHARED_COUNTER_SETTINGS.md §3). A contributing task carries
// `countsTowardCounterId` (+ `countsTowardAmount`, nil = 1; `countsTowardSince`,
// the instant the flag was set — D11). Its counter ROOT receives ONE increment
// per COMPLETION OCCURRENCE of the contributor (D10, ruled 2026-10-10). Each
// occurrence has a stable key and a deterministic credit id
// (`eventId(contributorId:occurrence:)`); a withdrawn occurrence has its credit
// tombstoned. The write lives in the cascade (`AppDatabase+CountsToward.swift`).
//
// Occurrence keys: NORMAL — one per live completion event (key = the event
// id); plain COUNTING — one per live placement window in which its windowed
// state is complete (key = the crossing increment's id; unplaced → the lifetime
// evaluation, same key); COMPOUND — one per live placement window in which its
// derivation is complete, keyed by the COMPLETING CHILD's event (All of → the
// last child's, Any of → the first, At least N → the N-th; nested compounds
// pass theirs up), so overlapping boards and board date edits collapse to one
// credit; a latched child with no event → `board:<boardId>`, or `lifetime`
// unplaced. An event key omits the contributor id, and a board-scoped fork's
// copied event (`BoardScopedFork.forkedEventId`) resolves to its SOURCE event
// through the `forkedFromTaskId` lineage (`ForkEventResolver`), so the original
// and the fork share one credit; a member tombstones an event-keyed credit only
// when NO live, flagged lineage member wants it (`plan`'s `lineageWantedIds`).
//
// Pinned by `countsTowardVectors.json` (`CountsTowardVectorTests`). A change
// here is a change in two places.
enum CountsToward {

    /// uuidv5 name prefix for a contributing task's counts-toward increments.
    static let namespace = "counts-toward:event"

    /// How many of an unflagged task's most recent events `probeContributionIds` looks at.
    static let probeEventLimit = 256

    /// Deepest `forkedFromTaskId` chain followed when resolving a copied event / a lineage.
    static let maxForkLineage = 8

    /// One completion occurrence of a contributor — the key its credit is minted under.
    enum Occurrence: Equatable, Hashable {
        /// A NORMAL / plain COUNTING contributor's OWN completing event.
        case event(eventId: String)
        /// A COMPOUND contributor's completing CHILD event (scoped — several compounds may share a child).
        case childEvent(eventId: String)
        /// A placed compound whose completing child owns no event.
        case board(boardId: String)
        /// An unplaced compound whose completing child owns no event.
        case lifetime
    }

    /// Deterministic id of the credit a contributor writes on its root for
    /// `occurrence` (twin of the TS `countsTowardEventId`). `contributorScopeId`
    /// is the contributor's fork-lineage ROOT (`lineageRootId`) — a fork shares
    /// its original's scope. An own-event key omits the scope (an event belongs
    /// to one task; a fork's copy resolves to its source).
    static func eventId(contributorScopeId: String, occurrence: Occurrence) -> String {
        switch occurrence {
        case let .event(eventId):
            return UUIDv5.uuidv5(name: "\(namespace):\(eventId)")
        case let .childEvent(eventId):
            return UUIDv5.uuidv5(name: "\(namespace):\(contributorScopeId):child-event:\(eventId)")
        case let .board(boardId):
            return UUIDv5.uuidv5(name: "\(namespace):\(contributorScopeId):board:\(boardId)")
        case .lifetime:
            return UUIDv5.uuidv5(name: "\(namespace):\(contributorScopeId):lifetime")
        }
    }

    /// The top of `task`'s `forkedFromTaskId` chain present in `taskById`
    /// (bounded) — the scope every contributor-scoped credit key of the lineage
    /// is minted under. A non-fork, or a fork whose original is not loaded, is its own root.
    static func lineageRootId(_ task: Task, taskById: [String: Task]) -> String {
        var current = task
        for _ in 0..<maxForkLineage {
            guard let parentId = current.forkedFromTaskId, let parent = taskById[parentId] else { return current.id }
            current = parent
        }
        return current.id
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
        /// The event that completed it (own crossing / first completion; a compound's completing child's).
        let completingEventId: String?
        /// The task that owns `completingEventId` (a linked child's crossing belongs to its ROOT).
        let completingTaskId: String?

        init(isCompleted: Bool, completedAt: String?, completingEventId: String? = nil, completingTaskId: String? = nil) {
            self.isCompleted = isCompleted
            self.completedAt = completedAt
            self.completingEventId = completingEventId
            self.completingTaskId = completingTaskId
        }

        static let incomplete = ContributionState(isCompleted: false, completedAt: nil)
    }

    /// A window a contribution is evaluated over (`nil` bounds = lifetime).
    struct Window {
        let windowStart: String?
        let windowEnd: String?
        static let lifetime = Window(windowStart: nil, windowEnd: nil)
    }

    /// Epoch MILLISECONDS of an ISO instant, rounded (`NaN` when unparseable —
    /// the TS `new Date(x).getTime()` degrade).
    static func epochMs(_ iso: String) -> Double {
        guard let d = DateFormatting.parseISO(iso) else { return .nan }
        return (d.timeIntervalSince1970 * 1000).rounded()
    }

    /// Whether two ISO instants denote the same moment: parsed-ms equality, or
    /// the raw strings when either does not parse.
    private static func sameInstant(_ a: String, _ b: String) -> Bool {
        let (ma, mb) = (epochMs(a), epochMs(b))
        if ma.isNaN || mb.isNaN { return a == b }
        return ma == mb
    }

    /// Ascending by parsed instant, then by the tie-break keys (deterministic).
    private static func stateBefore(_ a: ContributionState, _ b: ContributionState) -> Bool {
        let (ia, ib) = (a.completedAt ?? "", b.completedAt ?? "")
        let (ma, mb) = (epochMs(ia), epochMs(ib))
        if ma != mb, !(ma.isNaN && mb.isNaN) { return ma.isNaN ? false : mb.isNaN ? true : ma < mb }
        if ia != ib { return ia < ib }
        let (ea, eb) = (a.completingEventId ?? "", b.completingEventId ?? "")
        if ea != eb { return ea < eb }
        return (a.completingTaskId ?? "") < (b.completingTaskId ?? "")
    }

    private static func eventBefore(_ a: TaskEvent, _ b: TaskEvent) -> Bool {
        let (ma, mb) = (epochMs(a.occurredAt), epochMs(b.occurredAt))
        if ma != mb { return ma < mb }
        return a.id < b.id
    }

    /// Live events whose `occurredAt` falls inside `[windowStart, windowEnd]` (inclusive; `nil` = unbounded).
    private static func eventsInWindow(_ events: [TaskEvent], _ ctx: CompoundWindowContext) -> [TaskEvent] {
        let lower = ctx.windowStart.map(epochMs)
        let upper = ctx.windowEnd.map(epochMs)
        return events.filter { e in
            if e.isDeleted { return false }
            let t = epochMs(e.occurredAt)
            if let lower, !(t >= lower) { return false }
            if let upper, !(t <= upper) { return false }
            return true
        }
    }

    /// The increment that last carried the running sum from below `target` to
    /// at-or-above it, or `nil` when it never did.
    private static func crossingEvent(_ events: [TaskEvent], target: CountValue) -> TaskEvent? {
        let live = events.filter { !$0.isDeleted && $0.kind == .increment }.sorted(by: eventBefore)
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
        return ContributionState(isCompleted: true, completedAt: event.occurredAt, completingEventId: event.id, completingTaskId: event.taskId)
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
            let done = eventsInWindow(events, ctx).filter { $0.kind == .completion }.sorted(by: eventBefore)
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
            childStates.append(stateOf(child, ctx: ctx, childrenByCompound: childrenByCompound, taskById: taskById, visiting: &visiting))
        }
        visiting.remove(task.id)

        if childStates.isEmpty {
            // Mirrors `CompoundEvaluation`: AND over nothing is vacuously true —
            // except an unfilled counts-toward container (§3a).
            let vacuous = task.operatorType == .and && task.countsTowardCounterId == nil
            return vacuous ? ContributionState(isCompleted: true, completedAt: nil) : .incomplete
        }
        let done = childStates.filter(\.isCompleted).sorted(by: stateBefore)
        func nth(_ n: Int) -> ContributionState {
            let s = done[min(n, done.count) - 1]
            return ContributionState(isCompleted: true, completedAt: s.completedAt, completingEventId: s.completingEventId, completingTaskId: s.completingTaskId)
        }

        switch task.operatorType {
        case .and:
            return done.count == childStates.count ? nth(done.count) : .incomplete
        case .or:
            return done.isEmpty ? .incomplete : nth(1)
        case .mOfN:
            let required = max(1, task.threshold ?? 1)
            return done.count >= required ? nth(required) : .incomplete
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
        return ContributionState(
            isCompleted: true, completedAt: s.completedAt ?? task.createdAt,
            completingEventId: s.completingEventId, completingTaskId: s.completingTaskId
        )
    }

    // MARK: - Fork lineage

    /// Resolves an event of a board-scoped fork to its SOURCE event id
    /// (`forkedEventId(fork.id, source.id)` inverted), transitively up the
    /// lineage. Builds ONE reverse map per fork from its source's events the
    /// first time that fork is asked; every further event is a lookup.
    final class ForkEventResolver {
        private let taskById: [String: Task]
        private let allEventsByTaskId: [String: [TaskEvent]]
        private var reverseByFork: [String: [String: String]] = [:]

        init(taskById: [String: Task], allEventsByTaskId: [String: [TaskEvent]]) {
            self.taskById = taskById
            self.allEventsByTaskId = allEventsByTaskId
        }

        private func reverse(forkId: String, sourceId: String) -> [String: String] {
            if let map = reverseByFork[forkId] { return map }
            var map: [String: String] = [:]
            for e in allEventsByTaskId[sourceId] ?? [] { map[BoardScopedFork.forkedEventId(forkId: forkId, eventId: e.id)] = e.id }
            reverseByFork[forkId] = map
            return map
        }

        /// The canonical (source) event id of `eventId` owned by `task`; `eventId` itself for a non-copy.
        func resolve(_ eventId: String, task: Task) -> String {
            var current = task
            var id = eventId
            for _ in 0..<CountsToward.maxForkLineage {
                guard let sourceId = current.forkedFromTaskId, let source = taskById[sourceId] else { return id }
                guard let sourceEventId = reverse(forkId: current.id, sourceId: sourceId)[id] else { return id }
                id = sourceEventId
                current = source
            }
            return id
        }
    }

    /// `ForkEventResolver` for one lookup (tests; the writer shares one per cascade).
    static func canonicalOccurrenceEventId(
        _ eventId: String, task: Task, taskById: [String: Task], allEventsByTaskId: [String: [TaskEvent]]
    ) -> String {
        ForkEventResolver(taskById: taskById, allEventsByTaskId: allEventsByTaskId).resolve(eventId, task: task)
    }

    /// `forkedFromTaskId` → the ids of the tasks forked from it (any state).
    static func buildForkChildrenIndex(_ tasks: [Task]) -> [String: [String]] {
        var out: [String: [String]] = [:]
        for t in tasks { if let p = t.forkedFromTaskId { out[p, default: []].append(t.id) } }
        return out
    }

    /// The OTHER members of `taskId`'s fork lineage — ancestors, descendants and
    /// their relatives, transitively, bounded by `maxForkLineage` hops; only
    /// tasks present in `taskById`. Sorted, `taskId` excluded.
    static func forkLineageIds(_ taskId: String, taskById: [String: Task], forkChildren: [String: [String]]) -> [String] {
        var seen: Set<String> = [taskId]
        var frontier = [taskId]
        var depth = 0
        while depth < maxForkLineage, !frontier.isEmpty {
            var next: [String] = []
            for id in frontier {
                var related: [String] = []
                if let p = taskById[id]?.forkedFromTaskId { related.append(p) }
                related.append(contentsOf: forkChildren[id] ?? [])
                for r in related where !seen.contains(r) && taskById[r] != nil {
                    seen.insert(r)
                    next.append(r)
                }
            }
            frontier = next
            depth += 1
        }
        seen.remove(taskId)
        return seen.sorted()
    }

    // MARK: - Credits

    /// The data a contributor's credits are derived from (twin of the TS `ContributionInputs`).
    struct Inputs {
        /// Every task by id (resolves the counter root, compound children, fork lineage).
        var taskById: [String: Task]
        /// `compoundTaskId` → LIVE links.
        var childrenByCompound: [String: [CompoundChild]]
        /// `compoundTaskId` → links in ANY state (the candidate subtree); defaults to `childrenByCompound`.
        var allChildrenByCompound: [String: [CompoundChild]]? = nil
        /// Non-deleted events grouped by `taskId` (the kernel convention).
        var eventsByTaskId: [String: [TaskEvent]]
        /// EVERY event (tombstones included) by `taskId`.
        var allEventsByTaskId: [String: [TaskEvent]]
        /// The contributor's placements, any state (rows for other tasks are ignored).
        var placements: [BoardTask]
        /// Boards referenced by `placements`, any state.
        var boardById: [String: Board]
        /// A shared resolver; one is created over the inputs when absent.
        var forkEvents: ForkEventResolver? = nil

        fileprivate var resolver: ForkEventResolver {
            forkEvents ?? ForkEventResolver(taskById: taskById, allEventsByTaskId: allEventsByTaskId)
        }
    }

    /// One credit a contributor wants on its counter root.
    struct Credit: Equatable {
        /// The credit's deterministic id (`eventId(contributorId:occurrence:)`).
        let eventId: String
        let occurrence: Occurrence
        /// The completion instant the credit is stamped at.
        let occurredAt: String
    }

    /// The event-keyed occurrence for `eventId` owned by `taskId`, resolved through the fork lineage.
    private static func eventOccurrence(_ eventId: String, ownerId: String, inputs: Inputs, resolver: ForkEventResolver) -> Occurrence {
        guard let owner = inputs.taskById[ownerId] else { return .event(eventId: eventId) }
        return .event(eventId: resolver.resolve(eventId, task: owner))
    }

    /// The live boards placing `task`, each as the window its square is evaluated
    /// over (sealed → events bounded at `sealedAt`), by start date then board id.
    private static func liveWindows(of task: Task, inputs: Inputs) -> [(boardId: String, startDate: String, ctx: CompoundWindowContext)] {
        var seen = Set<String>()
        var out: [(boardId: String, startDate: String, ctx: CompoundWindowContext)] = []
        for p in inputs.placements where !p.isDeleted && p.taskId == task.id && !seen.contains(p.boardId) {
            seen.insert(p.boardId)
            guard let b = inputs.boardById[p.boardId], !b.isDeleted, b.status != .draft else { continue }
            let sealedAtMs = b.sealedAt.map(epochMs) ?? .nan
            let events = sealedAtMs.isNaN
                ? inputs.eventsByTaskId
                : boundWindowContextAtSeal(eventsByTaskId: inputs.eventsByTaskId, sealedAtMs: sealedAtMs).eventsByTaskId
            out.append((b.id, b.startDate, CompoundWindowContext(windowStart: b.startDate, windowEnd: boardWindowEnd(b), eventsByTaskId: events)))
        }
        return out.sorted { a, b in
            let (ma, mb) = (epochMs(a.startDate), epochMs(b.startDate))
            if ma != mb { return ma < mb }
            return a.boardId < b.boardId
        }
    }

    /// The credits `task` WANTS on its counter root, from live data (twin of
    /// the TS `resolveContributionCredits`). Does NOT consult the flag, the
    /// target or `countsTowardSince`: `plan` applies those.
    static func resolveContributionCredits(_ task: Task, inputs: Inputs) -> [Credit] {
        if task.isDeleted || task.isCounter { return [] }
        let resolver = inputs.resolver
        let scope = lineageRootId(task, taskById: inputs.taskById)
        var byId: [String: Credit] = [:]
        func want(_ occurrence: Occurrence, _ occurredAt: String) {
            let id = eventId(contributorScopeId: scope, occurrence: occurrence)
            if let prior = byId[id], !(epochMs(occurredAt) < epochMs(prior.occurredAt)) { return }
            byId[id] = Credit(eventId: id, occurrence: occurrence, occurredAt: occurredAt)
        }
        func evaluate(_ ctx: CompoundWindowContext) -> ContributionState {
            resolveContributionState(
                task, childrenByCompound: inputs.childrenByCompound, taskById: inputs.taskById,
                eventsByTaskId: ctx.eventsByTaskId, window: Window(windowStart: ctx.windowStart, windowEnd: ctx.windowEnd)
            )
        }
        let lifetimeCtx = CompoundWindowContext(windowStart: nil, windowEnd: nil, eventsByTaskId: inputs.eventsByTaskId)

        switch task.type {
        case .normal:
            for e in inputs.eventsByTaskId[task.id] ?? [] where !e.isDeleted && e.kind == .completion {
                want(eventOccurrence(e.id, ownerId: task.id, inputs: inputs, resolver: resolver), e.occurredAt)
            }
        case .counting:
            if let rootId = task.sharedCounterId, !rootId.isEmpty { return [] }
            let windows = liveWindows(of: task, inputs: inputs)
            for ctx in windows.isEmpty ? [lifetimeCtx] : windows.map(\.ctx) {
                let s = evaluate(ctx)
                if s.isCompleted, let crossing = s.completingEventId, let at = s.completedAt {
                    want(eventOccurrence(crossing, ownerId: s.completingTaskId ?? task.id, inputs: inputs, resolver: resolver), at)
                }
            }
        case .compound:
            func childEvent(_ s: ContributionState) -> Occurrence? {
                guard let completing = s.completingEventId else { return nil }
                if case let .event(resolved) = eventOccurrence(completing, ownerId: s.completingTaskId ?? task.id, inputs: inputs, resolver: resolver) {
                    return .childEvent(eventId: resolved)
                }
                return nil
            }
            let windows = liveWindows(of: task, inputs: inputs)
            if windows.isEmpty {
                let s = evaluate(lifetimeCtx)
                if s.isCompleted, let at = s.completedAt { want(childEvent(s) ?? .lifetime, at) }
            }
            for w in windows {
                let s = evaluate(w.ctx)
                if s.isCompleted, let at = s.completedAt { want(childEvent(s) ?? .board(boardId: w.boardId), at) }
            }
        case .achievement:
            return []
        }
        return byId.values.sorted { $0.eventId < $1.eventId }
    }

    /// D11 — "count from now on": an occurrence credits only when its instant is
    /// at or after the contributor's `countsTowardSince`. No `since` → every
    /// occurrence; an unparseable `since` applies no bound; an unparseable
    /// instant is never wanted. The single place the "wanted" policy lives.
    static func isOccurrenceWanted(since: String?, occurredAt: String) -> Bool {
        guard let since else { return true }
        let sinceMs = epochMs(since)
        if sinceMs.isNaN { return true }
        let at = epochMs(occurredAt)
        return !at.isNaN && at >= sinceMs
    }

    /// A live, unlinked, Discrete counting row (root-ness is a write-time rule).
    static func isTarget(_ task: Task?) -> Bool {
        guard let task else { return false }
        return !task.isDeleted && task.type == .counting && task.sharedCounterId == nil
            && resolveCountKind(task.countKind) == .discrete
    }

    /// Whether `task` can hold or want a credit at all: not a counter root, not a
    /// linked copy, not an Achievement. The writer skips such rows first.
    static func canContribute(_ task: Task) -> Bool {
        !task.isCounter && task.sharedCounterId == nil && task.type != .achievement
    }

    /// The credit ids the planner would KEEP for `contributor` — its wanted
    /// credits gated by the flag, the target and `isOccurrenceWanted` — exposed
    /// so a lineage member's wants can be unioned (`plan`'s `lineageWantedIds`).
    static func keptCreditIds(for contributor: Task, inputs: Inputs) -> [String] {
        let target = contributor.countsTowardCounterId.flatMap { inputs.taskById[$0] }
        guard !contributor.isDeleted, canContribute(contributor), isTarget(target) else { return [] }
        return resolveContributionCredits(contributor, inputs: inputs)
            .filter { isOccurrenceWanted(since: contributor.countsTowardSince, occurredAt: $0.occurredAt) }
            .map(\.eventId)
    }

    /// The task ids a compound's candidate keys reach: its subtree (links in any
    /// state) and the roots its linked children read.
    private static func candidateSubtreeIds(_ task: Task, inputs: Inputs) -> [String] {
        let links = inputs.allChildrenByCompound ?? inputs.childrenByCompound
        var seen: Set<String> = [task.id]
        var out: [String] = []
        var stack = [task.id]
        while let parent = stack.popLast() {
            for link in links[parent] ?? [] where !seen.contains(link.childTaskId) {
                seen.insert(link.childTaskId)
                out.append(link.childTaskId)
                guard let child = inputs.taskById[link.childTaskId] else { continue }
                if let rootId = child.sharedCounterId, !rootId.isEmpty, !out.contains(rootId) { out.append(rootId) }
                if child.type == .compound { stack.append(link.childTaskId) }
            }
        }
        return out
    }

    /// Every credit id `task` MAY own (twin of the TS `candidateContributionIds`):
    /// every event of the task (raw, plus its fork-resolved id when that differs),
    /// for a compound every event of its subtree and the roots its linked children
    /// read, a `board` key per placement (any state), and `lifetime`.
    static func candidateContributionIds(_ task: Task, inputs: Inputs) -> [String] {
        let resolver = inputs.resolver
        let scope = lineageRootId(task, taskById: inputs.taskById)
        var ids = Set<String>()
        func addEvents(of ownerId: String, asChild: Bool) {
            let owner = inputs.taskById[ownerId]
            func key(_ id: String) -> Occurrence { asChild ? .childEvent(eventId: id) : .event(eventId: id) }
            for e in inputs.allEventsByTaskId[ownerId] ?? [] {
                ids.insert(eventId(contributorScopeId: scope, occurrence: key(e.id)))
                let canonical = owner.map { resolver.resolve(e.id, task: $0) } ?? e.id
                if canonical != e.id { ids.insert(eventId(contributorScopeId: scope, occurrence: key(canonical))) }
            }
        }
        addEvents(of: task.id, asChild: false)
        if task.type == .compound { for id in candidateSubtreeIds(task, inputs: inputs) { addEvents(of: id, asChild: true) } }
        for p in inputs.placements where p.taskId == task.id {
            ids.insert(eventId(contributorScopeId: scope, occurrence: .board(boardId: p.boardId)))
        }
        ids.insert(eventId(contributorScopeId: scope, occurrence: .lifetime))
        return ids.sorted()
    }

    /// The cheap PROBE the writer runs for an unflagged contributor before
    /// deciding whether it is relevant: `lifetime`, a `board` key per placement
    /// (any state) and the raw event key of each of its most recent events
    /// (`ownEvents`, capped by the caller at `probeEventLimit`), scoped by the
    /// task's OWN id (the lineage is not known yet; a flagged lineage member
    /// reconciles lineage-scoped keys).
    static func probeContributionIds(taskId: String, ownEvents: [TaskEvent], placements: [BoardTask]) -> [String] {
        var ids: Set<String> = [eventId(contributorScopeId: taskId, occurrence: .lifetime)]
        for e in ownEvents { ids.insert(eventId(contributorScopeId: taskId, occurrence: .event(eventId: e.id))) }
        for p in placements where p.taskId == taskId { ids.insert(eventId(contributorScopeId: taskId, occurrence: .board(boardId: p.boardId))) }
        return ids.sorted()
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

        /// The roots the action touches, each with the instant it writes there.
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
    /// `planCountsTowardActions`): insert / revise / tombstone per candidate id,
    /// in id order; nothing for an identical live row; a tombstone is withheld
    /// for a credit another live, flagged lineage member still wants
    /// (`lineageWantedIds`); nothing at all while the counter is deleted (or not
    /// pulled yet). Occurrences before `countsTowardSince` are not wanted (D11).
    static func plan(
        contributor: Task,
        taskById: [String: Task],
        wanted: [Credit],
        candidateIds: [String],
        storedById: [String: TaskEvent],
        lineageWantedIds: Set<String> = []
    ) -> [Action] {
        let targetId = contributor.countsTowardCounterId
        let target = targetId.flatMap { taskById[$0] }
        if targetId != nil, target == nil || target?.isDeleted == true { return [] }

        var wantedById: [String: (rootId: String, delta: Int, occurredAt: String)] = [:]
        if !contributor.isDeleted, canContribute(contributor), isTarget(target), let target {
            for w in wanted where isOccurrenceWanted(since: contributor.countsTowardSince, occurredAt: w.occurredAt) {
                wantedById[w.eventId] = (target.id, amount(of: contributor), w.occurredAt)
            }
        }
        let ids = Set(wantedById.keys).union(candidateIds).sorted()

        var actions: [Action] = []
        for id in ids {
            let existing = storedById[id]
            let want = wantedById[id]
            if let existing, !existing.isDeleted {
                guard let want else {
                    if lineageWantedIds.contains(id) { continue }
                    guard let root = taskById[existing.taskId], !root.isDeleted else { continue }
                    actions.append(.tombstone(eventId: id, rootId: root.id, occurredAt: existing.occurredAt))
                    continue
                }
                let same = existing.kind == .increment && existing.taskId == want.rootId
                    && existing.delta == CountValue(want.delta) && sameInstant(existing.occurredAt, want.occurredAt)
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

    /// D11 — credits honour the counter's sealed windows like every other event:
    /// a write is SKIPPED when any instant it writes (the credit's `occurredAt`;
    /// for a revise also the previous instant, on the previous root) sits inside
    /// a seal-immune window of a sealed board holding that root or one of its
    /// copies (`AppDatabase.sealImmuneWindows(db:taskId:)` on the root), EXCEPT
    /// inside the closed-board late-log path (`lateLog`), which re-derives every
    /// sealed board deterministically. The single place the write-skip policy lives.
    static func isCreditWriteSealSuppressed(
        _ action: Action, immuneWindowsByRoot: [String: [SealImmuneWindow]], now: String, lateLog: Bool
    ) -> Bool {
        if lateLog { return false }
        return action.reach.contains { r in
            let windows = immuneWindowsByRoot[r.rootId] ?? []
            return !windows.isEmpty && isEventSealImmune(occurredAt: r.occurredAt, createdAt: now, boardId: nil, windows: windows)
        }
    }

    // MARK: - Write-time validation

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

    /// `taskId` and every task in its subtree (live links).
    private static func subtreeIds(_ taskId: String, children: [CompoundChild]) -> Set<String> {
        var seen: Set<String> = [taskId]
        var stack = [taskId]
        while let parent = stack.popLast() {
            for link in children where !link.isDeleted && link.compoundTaskId == parent && !seen.contains(link.childTaskId) {
                seen.insert(link.childTaskId)
                stack.append(link.childTaskId)
            }
        }
        return seen
    }

    /// Write-time validation for `task.countsTowardCounterId = targetId` (twin
    /// of the TS `countsTowardProblem`): the shape rules, then a transitive
    /// loop walk — counter → (the counter and its live copies) → the compounds
    /// holding any of them → each holder's own counts-toward counter → …; a loop
    /// exists as soon as a node of that walk is `task` or a task in its subtree.
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
        let liveLinks = children.filter { !$0.isDeleted }
        let reachesTask = subtreeIds(task.id, children: liveLinks)
        var visitedCounters = Set<String>()
        var counters = [targetId]
        while let counterId = counters.popLast() {
            if visitedCounters.contains(counterId) { continue }
            visitedCounters.insert(counterId)
            let nodes = [counterId] + tasks.filter { !$0.isDeleted && $0.sharedCounterId == counterId }.map(\.id)
            for node in nodes {
                if reachesTask.contains(node) { return .cycle }
                for holder in DerivationPass.findTransitiveParentCompounds(changedTaskId: node, children: liveLinks) {
                    if reachesTask.contains(holder) { return .cycle }
                    if let next = byId[holder]?.countsTowardCounterId, !visitedCounters.contains(next) { counters.append(next) }
                }
            }
        }
        return nil
    }
}
