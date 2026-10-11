import Foundation

/// The Counter Detail "Counts toward" section's per-contributor CREDIT COUNT
/// (docs/SHARED_COUNTER_SETTINGS.md §3d, PR 4; ruling 2026-10-10: the row
/// shows the contributor's live credit count as a muted "× N" only when
/// N ≥ 2 — a repeating contributor; a one-off looks like the drawing).
///
/// A credit is a live increment on the counter ROOT whose id is one of the
/// contributor's candidate ids (`candidateContributionIds`) — the key space
/// the cascade writes under. A fork and its original share one scope
/// (`lineageRootId`) and so one count: contributors are grouped by lineage,
/// the group's candidate set is the union of its members', and the count is
/// the number of live root increments inside it.
///
/// Swift twin of `packages/shared/src/algorithms/countsTowardCredits.ts`,
/// pinned by the `creditGroups` group of `countsTowardVectors.json`.
extension CountsToward {
    /// One fork lineage of contributors to a counter root, with its shared credit count.
    struct ContributorCreditGroup: Equatable {
        /// The lineage root id — the scope the lineage's credit keys are minted under.
        let scopeId: String
        /// The live, flagged members (sorted by id).
        let memberIds: [String]
        /// The member a row stands for: the lineage root when it is itself a
        /// live, flagged member, else the smallest member id.
        let representativeId: String
        /// Live increments on the root that belong to this lineage.
        let creditCount: Int
        /// The latest `occurredAt` among those credits; `nil` when there are none.
        let latestOccurredAt: String?
    }

    /// Groups the live contributors of counter root `rootId` by fork lineage
    /// and counts each lineage's live credits on the root.
    ///
    /// A contributor is a non-deleted task with `countsTowardCounterId ==
    /// rootId` that `canContribute`. `inputs` must carry every contributor's
    /// events (any state), its compound subtree and the root's live events
    /// (`eventsByTaskId[rootId]`); increments only are counted.
    ///
    /// - Parameters:
    ///   - rootId: The counter root.
    ///   - tasks: Every task (contributors are selected from it).
    ///   - inputs: See `Inputs`.
    /// - Returns: One group per lineage, sorted by `scopeId`.
    static func contributorCreditGroups(rootId: String, tasks: [Task], inputs: Inputs) -> [ContributorCreditGroup] {
        let contributors = tasks
            .filter { !$0.isDeleted && $0.countsTowardCounterId == rootId && canContribute($0) }
            .sorted { $0.id < $1.id }
        if contributors.isEmpty { return [] }

        let rootEvents = (inputs.eventsByTaskId[rootId] ?? []).filter { !$0.isDeleted && $0.kind == .increment }
        let liveById = Dictionary(rootEvents.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })

        var byScope: [String: [Task]] = [:]
        var scopeOrder: [String] = []
        for t in contributors {
            let scope = lineageRootId(t, taskById: inputs.taskById)
            if byScope[scope] == nil { scopeOrder.append(scope) }
            byScope[scope, default: []].append(t)
        }

        var groups: [ContributorCreditGroup] = []
        for scopeId in scopeOrder {
            let members = byScope[scopeId] ?? []
            var candidateIds = Set<String>()
            for m in members {
                for id in candidateContributionIds(m, inputs: inputs, rootIds: [rootId]) { candidateIds.insert(id) }
            }
            var creditCount = 0
            var latestOccurredAt: String?
            for id in candidateIds {
                guard let e = liveById[id] else { continue }
                creditCount += 1
                if latestOccurredAt == nil || e.occurredAt > latestOccurredAt! { latestOccurredAt = e.occurredAt }
            }
            let memberIds = members.map(\.id)
            groups.append(ContributorCreditGroup(
                scopeId: scopeId,
                memberIds: memberIds,
                representativeId: memberIds.contains(scopeId) ? scopeId : memberIds[0],
                creditCount: creditCount,
                latestOccurredAt: latestOccurredAt
            ))
        }
        return groups.sorted { $0.scopeId < $1.scopeId }
    }
}

// MARK: - Section rows

extension CountsToward {
    /// The StatusPill a Counter Detail "Counts toward" row shows.
    enum ContributorRowStatus: String, Equatable {
        case done
        case inProgress
        case notStarted
    }

    /// One row of the Counter Detail "Counts toward" section — one per fork lineage.
    struct ContributorRow: Equatable {
        /// The lineage's representative task (its title / type / tap target).
        let taskId: String
        /// The representative's CURRENT state on its primary board (lifetime when unplaced).
        let status: ContributorRowStatus
        /// The primary board (`pickPrimaryBoard`); `nil` when unplaced.
        let boardId: String?
        /// The lineage's live credits on the root (`contributorCreditGroups`).
        let creditCount: Int
        /// The latest credit instant; `nil` with no credits.
        let latestOccurredAt: String?
        /// A plain COUNTING representative that is not done: its windowed count
        /// vs its goal; `nil` otherwise.
        var progress: Progress? = nil
        /// A COMPOUND representative: done / total direct children on the same
        /// window (total 0 = the "No subtasks yet" row); `nil` otherwise.
        var childProgress: ChildProgress? = nil
        /// The lineage's live flagged members (sorted by id) — Remove clears every one.
        var memberIds: [String] = []
    }

    /// A Counting unit task's `{current} / {goal}` with its real kind (the formatting key).
    struct Progress: Equatable {
        let current: CountValue
        let goal: CountValue
        let kind: CountKind
    }

    /// A Compound unit task's direct-child tally.
    struct ChildProgress: Equatable {
        let done: Int
        let total: Int
    }

    /// The window a task is evaluated over on `board` — sealed boards bounded at `sealedAt`.
    private static func windowContext(of board: Board?, eventsByTaskId: [String: [TaskEvent]]) -> CompoundWindowContext {
        guard let board else { return CompoundWindowContext(windowStart: nil, windowEnd: nil, eventsByTaskId: eventsByTaskId) }
        let sealedAtMs = board.sealedAt.map(epochMs) ?? .nan
        let bounded = sealedAtMs.isNaN ? eventsByTaskId : boundWindowContextAtSeal(eventsByTaskId: eventsByTaskId, sealedAtMs: sealedAtMs).eventsByTaskId
        return CompoundWindowContext(windowStart: board.startDate, windowEnd: boardWindowEnd(board), eventsByTaskId: bounded)
    }

    /// A direct child's completion in `ctx` (a nested compound derives; a primitive resolves windowed).
    private static func childDone(_ child: Task, inputs: Inputs, ctx: CompoundWindowContext) -> Bool {
        if child.isDeleted { return false }
        if child.type == .compound {
            return CompoundEvaluation.evaluate(compound: child, childrenByCompound: inputs.childrenByCompound, taskById: inputs.taskById, windowContext: ctx)
        }
        return CompoundEvaluation.resolvePrimitiveChildState(child, ctx)
    }

    /// A contributor's StatusPill state on `board` (lifetime when `nil`):
    /// `done` when its derived completion holds in that window
    /// (`resolveContributionState`); `inProgress` for a plain Counting task
    /// with an in-window count above zero, or a Compound with at least one
    /// child complete in the window; `notStarted` otherwise (a Simple task is
    /// never in progress). Twin of the TS `contributorRowStatus`.
    static func contributorRowStatus(_ task: Task, inputs: Inputs, board: Board?) -> ContributorRowStatus {
        let ctx = windowContext(of: board, eventsByTaskId: inputs.eventsByTaskId)
        let window = Window(windowStart: ctx.windowStart, windowEnd: ctx.windowEnd)
        if resolveContributionState(task, childrenByCompound: inputs.childrenByCompound, taskById: inputs.taskById, eventsByTaskId: ctx.eventsByTaskId, window: window).isCompleted {
            return .done
        }
        if task.type == .counting {
            let state = resolveTaskWindowState(task: task, events: ctx.eventsByTaskId[task.id] ?? [], windowStart: ctx.windowStart, windowEnd: ctx.windowEnd)
            return state.count > 0 ? .inProgress : .notStarted
        }
        if task.type == .compound {
            for link in (inputs.childrenByCompound[task.id] ?? []) where !link.isDeleted {
                if let child = inputs.taskById[link.childTaskId], childDone(child, inputs: inputs, ctx: ctx) { return .inProgress }
            }
        }
        return .notStarted
    }

    private static func statusOrder(_ s: ContributorRowStatus) -> Int {
        switch s {
        case .inProgress: return 0
        case .notStarted: return 1
        case .done: return 2
        }
    }

    /// A plain Counting representative's windowed count vs goal (`nil` when it
    /// is done, not Counting, or has no goal). Twin of the TS `contributorRowProgress`.
    static func contributorRowProgress(_ task: Task, inputs: Inputs, board: Board?, status: ContributorRowStatus) -> Progress? {
        guard task.type == .counting, status != .done, let goal = task.maxCount else { return nil }
        let ctx = windowContext(of: board, eventsByTaskId: inputs.eventsByTaskId)
        let state = resolveTaskWindowState(task: task, events: ctx.eventsByTaskId[task.id] ?? [], windowStart: ctx.windowStart, windowEnd: ctx.windowEnd)
        return Progress(current: state.count, goal: goal, kind: resolveCountKind(task.countKind))
    }

    /// A Compound representative's done / total direct children on `board`'s window.
    /// Twin of the TS `contributorChildProgress`.
    static func contributorChildProgress(_ task: Task, inputs: Inputs, board: Board?) -> ChildProgress? {
        guard task.type == .compound else { return nil }
        let ctx = windowContext(of: board, eventsByTaskId: inputs.eventsByTaskId)
        var done = 0, total = 0
        for link in (inputs.childrenByCompound[task.id] ?? []) where !link.isDeleted {
            guard let child = inputs.taskById[link.childTaskId], !child.isDeleted else { continue }
            total += 1
            if childDone(child, inputs: inputs, ctx: ctx) { done += 1 }
        }
        return ChildProgress(done: done, total: total)
    }

    /// The Counter Detail "Counts toward" rows for counter root `rootId`: one
    /// per fork lineage (`contributorCreditGroups`), standing for the lineage's
    /// representative, placed on the representative's primary board
    /// (`pickPrimaryBoard` over `inputs.placements` / `inputs.boardById`), in
    /// the handoff's order — In progress, Not started, Done (Done by latest
    /// credit, newest first, no credit last) — then by title (case-insensitive),
    /// then id. Twin of the TS `countsTowardRows`.
    static func countsTowardRows(rootId: String, tasks: [Task], inputs: Inputs) -> [ContributorRow] {
        var rows: [(row: ContributorRow, title: String)] = []
        for g in contributorCreditGroups(rootId: rootId, tasks: tasks, inputs: inputs) {
            guard let task = inputs.taskById[g.representativeId] else { continue }
            let board = pickPrimaryBoard(taskId: task.id, boardTasks: inputs.placements, boardsById: inputs.boardById)
            let status = contributorRowStatus(task, inputs: inputs, board: board)
            rows.append((
                ContributorRow(
                    taskId: task.id,
                    status: status,
                    boardId: board?.id,
                    creditCount: g.creditCount,
                    latestOccurredAt: g.latestOccurredAt,
                    progress: contributorRowProgress(task, inputs: inputs, board: board, status: status),
                    childProgress: contributorChildProgress(task, inputs: inputs, board: board),
                    memberIds: g.memberIds
                ),
                task.title.lowercased()
            ))
        }
        rows.sort { a, b in
            let (oa, ob) = (statusOrder(a.row.status), statusOrder(b.row.status))
            if oa != ob { return oa < ob }
            if a.row.status == .done, a.row.latestOccurredAt != b.row.latestOccurredAt {
                guard let la = a.row.latestOccurredAt else { return false }
                guard let lb = b.row.latestOccurredAt else { return true }
                return la > lb
            }
            if a.title != b.title { return a.title < b.title }
            return a.row.taskId < b.row.taskId
        }
        return rows.map(\.row)
    }
}
