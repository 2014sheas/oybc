import Foundation

/// Placing a shared counter from the quick-add dropdown / Board Edit picker
/// (docs/SHARED_COUNTER_SETTINGS.md §2): which rows are counter roots, and the
/// PENDING linked counting task a goal-less root is placed as. Web twin:
/// `quickAddCounterPlacement.ts`.
enum QuickAddCounterPlacement {

    /// Whether `task` is a shared counter ROOT the match row treats as the
    /// COUNTER: counting, not itself linked, and created from the hub,
    /// carrying default goals, or linked to by another live task
    /// (`linkedRootIds`, from `counterRootIds(in:)`) — the same roots the
    /// Tasks tab shows as counters, so every search returns the counter.
    ///
    /// - Parameters:
    ///   - task: Any task.
    ///   - linkedRootIds: Ids other live tasks link to (default: none).
    /// - Returns: True for a counter root.
    static func isSharedCounterRoot(_ task: Task, linkedRootIds: Set<String> = []) -> Bool {
        task.type == .counting && task.sharedCounterId == nil
            && (task.isCounter || !(task.timeframeGoals?.isEmpty ?? true) || linkedRootIds.contains(task.id))
    }

    /// The counter roots in a surface's FULL task set (`sharedCounterRootIds`)
    /// — pass the unfiltered set: the browse list drops the linked members
    /// that make a root. Web twin: `counterRootIdsIn`.
    static func counterRootIds(in tasks: [Task]) -> Set<String> {
        sharedCounterRootIds(tasks)
    }

    /// The counters already sub-tasks of this compound draft: a live child
    /// linked to one (staged `sharedCounterId`, or a saved child whose task
    /// links to it), or a root linked as itself. Web twin: `countersInDraft`.
    static func countersInDraft(_ draft: TaskEditPatch, all: [Task]) -> Set<String> {
        let byId = Dictionary(all.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
        var used = Set<String>()
        for child in draft.children where !child.markedDeleted {
            if let id = child.sharedCounterId { used.insert(id) }
            if let id = child.childTaskId {
                used.insert(id)
                if let linked = byId[id]?.sharedCounterId { used.insert(linked) }
            }
        }
        return used
    }

    /// The compound editor's sub-task search set: the eligible tasks with every
    /// counter root in `library` listed as the COUNTER (a pick primes a new
    /// linked Counting sub-task). Left out: the counter the compound itself
    /// counts toward (a sub linked to it would credit it twice) and every
    /// counter already a sub-task of THIS compound (`countersInDraft`; other
    /// compounds and the board are separate scopes). Web twin:
    /// `compoundSubCandidates.ts`.
    ///
    /// - Parameters:
    ///   - parentId: The compound being edited.
    ///   - eligible: `CompoundChildEligibility.pickerCandidates` output.
    ///   - library: Browsable library tasks.
    ///   - lookup: The surface's FULL task set.
    ///   - draft: The staged structure (nil: nothing staged yet).
    /// - Returns: The search set (eligible first, then counters) and the counter ids.
    static func compoundSubCandidates(
        parentId: String, eligible: [Task], library: [Task], lookup: [Task], draft: TaskEditPatch? = nil
    ) -> (candidates: [Task], counterIds: Set<String>) {
        let all = lookup + library
        let rootIds = counterRootIds(in: all)
        let countsToward = all.first { $0.id == parentId }?.countsTowardCounterId
        let used = draft.map { countersInDraft($0, all: all) } ?? []
        let counters = library.filter {
            !$0.isDeleted && $0.id != countsToward && !used.contains($0.id)
                && isSharedCounterRoot($0, linkedRootIds: rootIds)
        }
        let counterIds = Set(counters.map(\.id))
        // A counter is only ever offered AS the counter — never as a plain task.
        let plain = eligible.filter { !isSharedCounterRoot($0, linkedRootIds: rootIds) && $0.id != countsToward }
        return (plain + counters, counterIds)
    }

    /// The pending LINKED counting task for a goal-less counter root placed at
    /// `goal`: the special panel's deferred auto-link shape — a row whose own
    /// goal is `goal`, counting from zero, carrying the host board's window
    /// fields so that, wherever it IS persisted (a draft; a repeating board's
    /// member list), it expires with its window. On an active one-off save
    /// and in Board Edit the planner / placement choke point mint the
    /// per-board copy at this goal, and the persist seams never write this
    /// row (`AppDatabase.dropReplacedLinkedPendingRows`). Nothing is written
    /// to the root.
    ///
    /// - Parameters:
    ///   - root: The counter's root task.
    ///   - goal: The goal entered in the row (positive).
    ///   - userId: Owning user.
    ///   - now: ISO8601 write timestamp.
    ///   - timeframe: The host board's timeframe, if any.
    ///   - startDate: The host board's window start, if any.
    ///   - endDate: The host board's window end, if any.
    /// - Returns: The payload to hand to the host's `onPendingCreated`.
    static func pendingLinkedTask(
        root: Task, goal: CountValue, userId: String, now: String,
        timeframe: Timeframe? = nil, startDate: String? = nil, endDate: String? = nil
    ) -> PendingTaskPayload {
        let kind = resolveCountKind(root.countKind)
        var task = Task(
            id: AppDatabase.generateUUID(),
            userId: userId,
            title: CounterSettings.renderCounterTitle(CounterSettings.Fields(task: root), goal: goal),
            description: nil,
            type: .counting,
            action: root.action,
            unit: root.unit,
            maxCount: goal,
            totalCompletions: 0,
            totalInstances: 0,
            createdAt: now,
            updatedAt: now,
            version: 1,
            isDeleted: false,
            timeframe: timeframe,
            startDate: startDate,
            endDate: endDate,
            sharedCounterId: root.id,
            baseline: root.currentCount ?? 0,
            createdInWizard: true
        )
        task.countKind = kind == .discrete ? nil : kind
        return PendingTaskPayload(task: task, childTasks: [], childLinks: [])
    }

    /// The linked copy a hand-added counter ROOT row edits as: the pending
    /// linked task at the board window's default goal (`placementGoalForCounter`),
    /// so the row's editor opens on the goal the board will get and a Save
    /// swaps the counter for this board-only copy — never writing the root.
    /// Nil when `task` isn't a counter root or nothing resolves a goal. TS
    /// twin: `counterRowEditCopy`.
    ///
    /// - Parameters:
    ///   - task: The row's task.
    ///   - linkedRootIds: `counterRootIds(in:)` over the surface's full task set.
    ///   - userId: Owning user.
    ///   - window: The host board's window.
    /// - Returns: The copy's payload, or nil.
    static func counterRowEditCopy(
        _ task: Task, linkedRootIds: Set<String>, userId: String, window: CounterPlacement.PickWindow
    ) -> PendingTaskPayload? {
        guard isSharedCounterRoot(task, linkedRootIds: linkedRootIds),
              let goal = CounterPlacement.placementGoalForCounter(
                  CounterSettings.Fields(task: task), timeframe: window.timeframe,
                  startDate: window.startDate, endDate: window.endDate
              )
        else { return nil }
        return pendingLinkedTask(
            root: task, goal: goal, userId: userId, now: AppDatabase.currentTimestamp(),
            timeframe: window.timeframe, startDate: window.startDate, endDate: window.endDate
        )
    }

    /// Is this pending payload a bare LINKED counting row (the match row's or
    /// the special panel's auto-link create) — the only pending shape a mint
    /// replaces with the per-board copy, so the persist seams must not write
    /// it once it is not among the placed ids. Ordinary pending pool tasks are
    /// never dropped. TS twin: `isLinkedPendingPayload`.
    static func isLinkedPendingPayload(_ payload: PendingTaskPayload) -> Bool {
        payload.task.sharedCounterId != nil && payload.task.type == .counting && payload.childTasks.isEmpty
    }

    /// A pending linked counter copy re-stamped onto the board's CURRENT
    /// window, for when the wizard's timeframe / dates change after the pick:
    /// the window fields move, and a goal still at the old window's default
    /// (never typed) follows to the new window's default. A typed goal is
    /// kept; a staged row edit still overrides either. Nil when it isn't a
    /// linked copy or is already on this window. TS twin:
    /// `restampPendingCounterCopy`.
    static func restampedPendingCounterCopy(
        _ payload: PendingTaskPayload, root: Task, window: CounterPlacement.PickWindow
    ) -> PendingTaskPayload? {
        guard isLinkedPendingPayload(payload) else { return nil }
        var task = payload.task
        if task.timeframe == window.timeframe, task.startDate == window.startDate, task.endDate == window.endDate {
            return nil
        }
        let fields = CounterSettings.Fields(task: root)
        let oldDefault = task.timeframe.flatMap {
            CounterPlacement.placementGoalForCounter(fields, timeframe: $0, startDate: task.startDate, endDate: task.endDate)
        }
        if let oldDefault, task.maxCount == oldDefault,
           let goal = CounterPlacement.placementGoalForCounter(
               fields, timeframe: window.timeframe, startDate: window.startDate, endDate: window.endDate
           ) {
            task.maxCount = goal
            task.title = CounterSettings.renderCounterTitle(fields, goal: goal)
        }
        task.timeframe = window.timeframe
        task.startDate = window.startDate
        task.endDate = window.endDate
        return PendingTaskPayload(task: task, childTasks: payload.childTasks, childLinks: payload.childLinks)
    }
}
