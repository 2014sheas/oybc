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

    /// The pending LINKED counting task for a goal-less counter root placed at
    /// `goal`: a deferred row (written at board save) whose own goal is `goal`,
    /// counting from zero. It deliberately carries NO `timeframe` / `startDate`
    /// / `endDate` — a linked row with a `startDate` and `createdInWizard`
    /// would read as a window-stamped derived row; the planner / Board Edit
    /// commit mints the per-board window copy from it.
    ///
    /// - Parameters:
    ///   - root: The counter's root task.
    ///   - goal: The goal entered in the row (positive).
    ///   - userId: Owning user.
    ///   - now: ISO8601 write timestamp.
    /// - Returns: The payload to hand to the host's `onPendingCreated`.
    static func pendingLinkedTask(root: Task, goal: CountValue, userId: String, now: String) -> PendingTaskPayload {
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
            sharedCounterId: root.id,
            baseline: root.currentCount ?? 0,
            createdInWizard: true
        )
        task.countKind = kind == .discrete ? nil : kind
        return PendingTaskPayload(task: task, childTasks: [], childLinks: [])
    }
}
