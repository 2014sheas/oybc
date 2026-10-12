import Foundation

/// Placing a shared counter from the quick-add dropdown / Board Edit picker
/// (docs/SHARED_COUNTER_SETTINGS.md §2): which rows are counter roots, and the
/// PENDING linked counting task a goal-less root is placed as. Web twin:
/// `quickAddCounterPlacement.ts`.
enum QuickAddCounterPlacement {

    /// Whether `task` is a shared counter ROOT (a counting task other boards
    /// link to): counting, not itself linked, and either created from the hub
    /// or carrying default goals.
    ///
    /// - Parameter task: Any task.
    /// - Returns: True for a counter root.
    static func isSharedCounterRoot(_ task: Task) -> Bool {
        task.type == .counting && task.sharedCounterId == nil
            && (task.isCounter || !(task.timeframeGoals?.isEmpty ?? true))
    }

    /// The quick-add candidates widened with every live goal-less counter
    /// ROOT in `pool` — not a fork, not itself linked (owner bug report
    /// 2026-10-12). A counter created from the Counters hub has no `maxCount`
    /// (its per-window defaults live in `timeframeGoals`), so the browse filter
    /// hides it and it is never in a browse-filtered `candidates`; an opted-in
    /// quick-add adds it back so typing the counter's name finds it.
    /// `requireDefault` (a pool / core defaults host, which stores the counter
    /// for later board creation): only counters with a window default, since
    /// board creation mints the copy at that board window's default and a
    /// counter with none would land goal-less.
    /// Web twin: `withGoalLessCounters` (`poolEditSheetSelectors.ts`).
    ///
    /// - Parameters:
    ///   - candidates: The browse-filtered candidates.
    ///   - pool: The surface's full task set.
    ///   - requireDefault: Keep only counters with at least one window default.
    /// - Returns: `candidates`, then the missing goal-less counters in pool order.
    static func withGoalLessCounters(_ candidates: [Task], pool: [Task], requireDefault: Bool = false) -> [Task] {
        var ids = Set(candidates.map(\.id))
        var out = candidates
        for task in pool where !task.isDeleted && BrowsableTasks.isGoalLessCounter(task)
            && task.forkedFromTaskId == nil && task.sharedCounterId == nil && !ids.contains(task.id)
            && (!requireDefault || hasWindowDefault(task)) {
            ids.insert(task.id)
            out.append(task)
        }
        return out
    }

    /// Whether a counter stores a positive default goal for any window.
    private static func hasWindowDefault(_ task: Task) -> Bool {
        guard let g = task.timeframeGoals else { return false }
        return [g.daily, g.weekly, g.monthly, g.yearly].contains { ($0 ?? 0) > 0 }
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

    /// Is this pending payload a bare LINKED counting row (the match row's or
    /// the special panel's auto-link create) — the only pending shape a mint
    /// replaces with the per-board copy, so the persist seams must not write
    /// it once it is not among the placed ids. Ordinary pending pool tasks are
    /// never dropped. TS twin: `isLinkedPendingPayload`.
    static func isLinkedPendingPayload(_ payload: PendingTaskPayload) -> Bool {
        payload.task.sharedCounterId != nil && payload.task.type == .counting && payload.childTasks.isEmpty
    }
}
