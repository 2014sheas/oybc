import Foundation

// MARK: - Placement parameters — how a square READS them (TASK_WINDOW_REWORK slice 2a)
//
// Swift twin of `packages/shared/src/algorithms/placementParams.ts`, pinned by
// `placementParamsVectors.json`. A `BoardTask` may carry a per-board goal
// (`targetOverride` in `targetKind`), per-child goals for a compound
// (`childTargets`) and a per-board title (`titleOverride`). Every kernel and
// surface resolves the PLACEMENT-ADJUSTED task — the library row with its
// `maxCount` / `title` replaced — through `withPlacementParams`, so one
// function owns the override rule. A placement with no parameters resolves
// the library row unchanged; a leftover minted derived row keeps resolving
// as a plain linked task over the host window.

enum PlacementParams {
    /// A frozen goal expressed in `from`, read by a root whose current kind is
    /// `to` (ruling 5): the kind switch's own rounding (`planCountKindSwitch`).
    static func convertGoalToKind(_ goal: CountValue, from: CountKind, to: CountKind) -> CountValue {
        if from == to { return goal }
        return isWholeCountKind(to) ? max(1, (quantizeCount(goal) + 0.5).rounded(.down)) : quantizeCount(goal)
    }

    /// A counting placement's goal on its board: `targetOverride` (converted
    /// from `targetKind` into the task's current kind), else the task's own.
    static func goal(for task: Task, placement: BoardTask?) -> CountValue? {
        // A goal override means nothing on a non-counting task.
        guard task.type == .counting, let override = placement?.targetOverride else { return task.maxCount }
        let kind = resolveCountKind(task.countKind)
        return convertGoalToKind(override, from: placement?.targetKind ?? kind, to: kind)
    }

    /// The goal a compound placement assigns to one DIRECT child, if any.
    static func childTarget(_ placement: BoardTask?, childId: String) -> CountValue? {
        placement?.childTargets?.first { $0.childId == childId }?.target
    }

    /// A square's title: `titleOverride` (ruling 4), else — for a counting task
    /// placed with a goal override — the title re-rendered at that goal through
    /// the root's templates (`counterCopyTitle`), else the task's title.
    static func title(for task: Task, placement: BoardTask?, settings: CounterSettings.TitleSettings? = nil) -> String {
        if let override = placement?.titleOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            return override
        }
        guard task.type == .counting, placement?.targetOverride != nil, let goal = goal(for: task, placement: placement) else {
            return task.title
        }
        return TaskTitle.counterCopyTitle(member: task, newMaxCount: goal, settings: settings)
    }

    /// The placement-adjusted task every kernel and surface resolves. Returns
    /// the SAME value when no parameter applies (pre-rework rows cost nothing).
    static func apply(_ task: Task, placement: BoardTask?, settings: CounterSettings.TitleSettings? = nil) -> Task {
        guard let placement else { return task }
        let hasGoal = task.type == .counting && placement.targetOverride != nil
        let hasTitle = !(placement.titleOverride?.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ?? true)
        guard hasGoal || hasTitle else { return task }
        var out = task
        if hasGoal { out.maxCount = goal(for: task, placement: placement) }
        out.title = title(for: task, placement: placement, settings: settings)
        return out
    }

    /// A DIRECT child of a compound with the parent placement's `childTargets`
    /// entry (if any) as its goal; nested compounds' children keep their own.
    static func withChildTarget(_ child: Task, childTargets: [PlacementChildTarget]?) -> Task {
        guard child.type == .counting, let targets = childTargets, !targets.isEmpty,
              let target = targets.first(where: { $0.childId == child.id })?.target else { return child }
        var out = child
        out.maxCount = target
        return out
    }

    /// The state of a PRIMITIVE square (normal / counting, root or linked) on a
    /// board — the event owner's live events inside the host window, scored
    /// against the placement's goal. Twin of the TS `resolveSquareState`.
    static func resolveSquareState(_ task: Task, placement: BoardTask?, ctx: CompoundWindowContext) -> TaskWindowState {
        let effective = apply(task, placement: placement)
        if let derived = resolveDerivedCounterWindowState(
            task: effective, eventsByTaskId: ctx.eventsByTaskId, windowStart: ctx.windowStart, windowEnd: ctx.windowEnd
        ) {
            return derived
        }
        if effective.type == .counting, let linked = effective.sharedCounterId, !linked.isEmpty {
            // A hub-linked row with no host window: the context-less latch (slice 5 retires this).
            return TaskWindowState(isCompleted: effective.isCompleted, count: effective.currentCount ?? 0)
        }
        let events = ctx.eventsByTaskId[effective.id] ?? []
        return resolveTaskWindowState(task: effective, events: events, windowStart: ctx.windowStart, windowEnd: ctx.windowEnd)
    }
}
