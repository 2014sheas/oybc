import Foundation

/// The wizard's per-cell placement parameters for one task (TASK_WINDOW_REWORK
/// slice 3b): a quick-added counter's window goal or a hand-edited goal / title.
/// Keyed by task id on `BoardWizardViewModel.placementParams`; persist writes
/// them onto the `board_tasks` row and an explicit parameter wins over the
/// planner's for that cell. Twin of the TS `PlacementParams`.
struct PlacementParamsDraft: Codable, Equatable {
    /// The cell's goal for THIS board, in `targetKind`.
    var targetOverride: CountValue?
    var targetKind: CountKind?
    /// A per-board title.
    var titleOverride: String?
    /// True when the draft carries nothing to write.
    var isEmpty: Bool { targetOverride == nil && titleOverride == nil }

    /// The parameters a counter ROOT placed at `goal` carries: a goal override
    /// (in the root's kind) only when it differs from the root's own goal; nil
    /// when the placement is the plain task. Twin of the TS quick-add rule.
    ///
    /// - Parameters:
    ///   - goal: The goal the cell should read on this board.
    ///   - root: The shared-counter root being placed.
    /// - Returns: The draft to store, or nil to clear.
    static func forCounterGoal(_ goal: CountValue, root: Task) -> PlacementParamsDraft? {
        guard goal > 0, goal != root.maxCount else { return nil }
        return PlacementParamsDraft(targetOverride: goal, targetKind: resolveCountKind(root.countKind))
    }

    /// `task` as the board reads it under these parameters, through the one
    /// placement rule (`PlacementParams.apply`) — for rows and previews that
    /// have no `board_tasks` row yet.
    ///
    /// - Parameters:
    ///   - task: The library / pending task.
    ///   - root: Its shared-counter root (title templates), if linked.
    func apply(to task: Task, root: Task? = nil) -> Task {
        let row = BoardTask(
            id: "wizard", boardId: "wizard", taskId: task.id, row: 0, col: 0, isCenter: false,
            targetOverride: targetOverride, targetKind: targetKind, titleOverride: titleOverride,
            createdAt: "", updatedAt: "", version: 1
        )
        return PlacementParams.apply(task, placement: row, settings: CounterSettings.TitleSettings(task: root ?? task))
    }

    /// Overlay these explicit parameters onto the planner's placement: any
    /// field the draft sets replaces the planner's; the planner's
    /// `childTargets` are kept.
    ///
    /// A hand-added member's dice roll AROUND the explicit goal (in its kind),
    /// not around the planner's default: pass its `vary` + `task` + `rng`. No
    /// dice (the default) keeps the explicit goal as-is.
    ///
    /// - Parameters:
    ///   - planned: The planner's placement for this cell.
    ///   - vary: The member's dice level (hand-added counting members only).
    ///   - task: The placed task (its kind is the fallback kind).
    ///   - rng: Uniform `[0, 1)` source; consumed at most once, and only when `vary` is on.
    /// - Returns: The placement to write.
    func overlaying(
        _ planned: BoardSources.PlannedPlacement,
        vary: VaryLevel = .off,
        task: Task? = nil,
        rng: () -> Double = { Double.random(in: 0..<1) }
    ) -> BoardSources.PlannedPlacement {
        var out = planned
        if let target = targetOverride {
            let kind = targetKind ?? planned.targetKind ?? resolveCountKind(task?.countKind)
            out.targetOverride = ExplicitGoalRoll.rolledExplicitGoal(goal: target, kind: kind, vary: vary, rng: rng)
            out.targetKind = kind
        }
        if let title = titleOverride { out.titleOverride = title }
        return out
    }
}

extension BoardTask {
    /// This (brand-new) placement row carrying the planned parameters,
    /// normalised through the one canonical rule. Fresh rows only — a row that
    /// may need a parameter CLEARED goes through `setPlacementParams`.
    func withPlanned(_ planned: BoardSources.PlannedPlacement) -> BoardTask {
        var out = self
        let norm = BoardTask.normalizedPlacementFields(
            targetOverride: planned.targetOverride,
            targetKind: planned.targetKind,
            childTargets: planned.childTargets,
            titleOverride: planned.titleOverride
        )
        out.taskId = planned.taskId
        out.targetOverride = norm.targetOverride
        out.targetKind = norm.targetKind
        out.childTargets = norm.childTargets
        out.titleOverride = norm.titleOverride
        return out
    }
}
