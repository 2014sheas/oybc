import Foundation

// MARK: - Board Edit: parameter vs non-parameter fields (TASK_WINDOW_REWORK slice 3a)
//
// A staged Board Edit "Edit task…" override mixes two kinds of fields
// (docs/TASK_WINDOW_REWORK.md §Writers emit parameters, Gate 1 ruling b / c):
//
//   PARAMETER fields land on the square's `BoardTask` and never fork the task:
//     - a counting task's GOAL      -> `targetOverride` + `targetKind`
//     - any task's TITLE            -> `titleOverride`
//     - a compound's EXISTING child's goal -> a `childTargets` entry
//   EVERYTHING ELSE (action, unit, a kind switch, a type switch, description,
//   compound structure: added / removed / reordered children, operator,
//   threshold, a child's action / unit / title) takes the existing board-scoped
//   path (`ensureBoardScopedTask` + apply) and forks only when the task is
//   placed on another board.
//
// "Changed" is judged against the task's own STORED field, never the
// placement-adjusted value the sheet is seeded with, so an untouched sheet
// writes nothing. Twin of the web `boardScopedSheet.patchHasNonParameterFields`.

extension StagedTaskOverride {
    /// The staged form of the sheet's Done patch (what `handleEditTaskOverride` stores).
    init(patch: SquareEditTaskSheet.Patch) {
        self.init(
            title: patch.title,
            type: patch.type,
            action: patch.action.isEmpty ? nil : patch.action,
            unit: patch.unit.isEmpty ? nil : patch.unit,
            maxCount: patch.maxCount,
            compound: patch.compound,
            countKind: patch.countKind
        )
    }
}

enum BoardEditParamSplit {

    /// Whether `override` still changes something a placement parameter cannot
    /// carry. A parameter-only edit (goal / title / an existing child's goal)
    /// returns false, and neither forks nor writes the task.
    ///
    /// - Parameters:
    ///   - task: The task as STORED (not placement-adjusted, not staged).
    ///   - override: The staged edit.
    ///   - storedChildren: A compound's stored sub-tasks in order; nil =
    ///     unknown, which reads as "structure changed" when a structure is staged.
    /// - Returns: True when the non-parameter path must run.
    static func hasNonParameterFields(task: Task, override: StagedTaskOverride, storedChildren: [Task]?) -> Bool {
        if BoardPlayViewModel.editedType(override, task) != task.type { return true }
        // A type the edit would not switch to is ignored (Achievement stays Achievement).
        switch task.type {
        case .counting:
            guard override.type == .counting else { return false }
            let kind = resolveCountKind(task.countKind)
            if (override.action ?? "") != (task.action ?? "") { return true }
            if countKindNeedsUnit(kind), (override.unit ?? "") != (task.unit ?? "") { return true }
            if let next = override.countKind, task.sharedCounterId == nil, next != kind { return true }
            return false
        case .compound:
            guard let structure = override.compound else { return false }
            return structureChangesNonParameter(task: task, structure: structure, storedChildren: storedChildren)
        default:
            return false
        }
    }

    /// Whether a staged compound structure differs from the stored one in
    /// anything but the title and an existing counting child's goal.
    static func structureChangesNonParameter(task: Task, structure: TaskEditPatch, storedChildren: [Task]?) -> Bool {
        guard let stored = storedChildren else { return true }
        if structure.operatorType != task.operatorType { return true }
        if structure.operatorType == .mOfN, structure.threshold != task.threshold { return true }
        if structure.children.contains(where: { $0.isNew || $0.markedDeleted }) { return true }
        if structure.children.map(\.childTaskId) != stored.map { Optional($0.id) } { return true }
        let rows = Dictionary(stored.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        return structure.children.contains { step in
            guard let id = step.childTaskId, let row = rows[id] else { return true }
            return stepChangesNonParameter(step, row: row)
        }
    }

    /// Whether an existing sub-task's step differs from its stored row in
    /// anything but the goal (a goal-regenerated auto title is not an edit).
    static func stepChangesNonParameter(_ step: ChildPatch, row: Task) -> Bool {
        let title = step.title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard row.type == .counting, step.isCounting else { return title != row.title }
        let kind = resolveCountKind(row.countKind)
        if step.action.trimmingCharacters(in: .whitespaces) != (row.action ?? "") { return true }
        if countKindNeedsUnit(kind), step.unit.trimmingCharacters(in: .whitespaces) != (row.unit ?? "") { return true }
        if title == row.title { return false }
        let goal = parseCountInput(step.goal, kind: kind) ?? row.maxCount
        return !TaskTitle.isAutoCounterTitle(
            title: title, action: row.action ?? "", maxCount: goal, unit: row.unit ?? "",
            countKind: kind, settings: CounterSettings.TitleSettings(task: row)
        )
    }

    /// `override` with every PARAMETER field reset to the stored value, so the
    /// non-parameter path writes nothing for them. A type conversion keeps its
    /// goal and title (the conversion IS the structural edit).
    ///
    /// - Parameters:
    ///   - override: The staged edit.
    ///   - task: The task as stored.
    ///   - storedChildren: A compound's stored sub-tasks (any order).
    static func nonParameterOverride(
        _ override: StagedTaskOverride, task: Task, storedChildren: [Task]?
    ) -> StagedTaskOverride {
        guard override.type == task.type else { return override }
        var out = override
        switch task.type {
        case .counting:
            // An auto title regenerates (blank) only when action / unit changed, at
            // the STORED goal; otherwise the stored title stands.
            let kind = resolveCountKind(task.countKind)
            let renamed = (override.action ?? "") != (task.action ?? "")
                || (countKindNeedsUnit(kind) && (override.unit ?? "") != (task.unit ?? ""))
            let isAuto = TaskTitle.isAutoCounterTitle(
                title: task.title, action: task.action ?? "", maxCount: task.maxCount, unit: task.unit ?? "",
                countKind: kind, settings: CounterSettings.TitleSettings(task: task)
            )
            out.title = (renamed && isAuto) ? "" : task.title
            out.maxCount = nil
        case .compound:
            out.title = task.title
            if var structure = out.compound {
                structure.title = task.title
                let rows = Dictionary((storedChildren ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
                structure.children = structure.children.map { step in
                    guard let id = step.childTaskId, let row = rows[id], row.type == .counting, step.isCounting else { return step }
                    if !stepChangesNonParameter(step, row: row) {
                        var restored = ChildPatch(from: row)
                        restored.id = step.id
                        return restored
                    }
                    var kept = step
                    kept.goal = row.maxCount.map { formatCountForInput($0, kind: resolveCountKind(row.countKind)) } ?? step.goal
                    return kept
                }
                out.compound = structure
            }
        default:
            out.title = task.title
        }
        return out
    }

    /// The placement parameters the staged edit asks for, relative to the
    /// current ones on `placement`. Compare-before-write lives in
    /// `AppDatabase.setPlacementParams`, so an untouched sheet yields a patch
    /// that writes nothing.
    ///
    /// - Parameters:
    ///   - override: The staged edit.
    ///   - task: The task AFTER any non-parameter write (stored fields).
    ///   - placement: The square's current `BoardTask`.
    ///   - storedChildren: A compound's stored sub-tasks (any order).
    ///   - titleSettings: The counter root's title templates for a linked row.
    /// - Returns: The patch to apply to the placement.
    static func parameterPatch(
        override: StagedTaskOverride, task: Task, placement: BoardTask, storedChildren: [Task]?,
        titleSettings: CounterSettings.TitleSettings? = nil
    ) -> PlacementParamsPatch {
        var patch = PlacementParamsPatch()

        // Goal: only a counting task that stays counting (a refused type switch is ignored).
        var goal = task.maxCount
        if task.type == .counting, override.type == .counting, let entered = override.maxCount {
            goal = entered
            if entered == task.maxCount {
                patch.targetOverride = .clear
                patch.targetKind = .clear
            } else {
                patch.targetOverride = .set(entered)
                patch.targetKind = .set(resolveCountKind(task.countKind))
            }
        }

        // Title: a custom name that differs from the stored title; blank / auto
        // / equal-to-stored clears it back to the task's own.
        let typed = override.title.trimmingCharacters(in: .whitespacesAndNewlines)
        var titleIsOverride = !typed.isEmpty && typed != task.title
        if titleIsOverride, task.type == .counting,
           TaskTitle.isAutoCounterTitle(
               title: typed, action: task.action ?? "", maxCount: goal, unit: task.unit ?? "",
               countKind: resolveCountKind(task.countKind),
               settings: titleSettings ?? CounterSettings.TitleSettings(task: task)
           ) {
            titleIsOverride = false
        }
        patch.titleOverride = titleIsOverride ? .set(typed) : .clear

        // A compound's EXISTING counting children: goal differs from the child's own.
        if task.type == .compound, let structure = override.compound {
            let rows = Dictionary((storedChildren ?? []).map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            var targets = Dictionary(
                uniqueKeysWithValues: (placement.childTargets ?? []).map { ($0.childId, $0.target) }
            )
            let liveIds = Set(structure.children.compactMap { $0.markedDeleted ? nil : $0.childTaskId })
            for id in targets.keys where !liveIds.contains(id) { targets.removeValue(forKey: id) }
            for step in structure.children where !step.markedDeleted {
                guard let id = step.childTaskId, let row = rows[id], row.type == .counting, step.isCounting,
                      let entered = parseCountInput(step.goal, kind: resolveCountKind(row.countKind)) else { continue }
                if entered == row.maxCount { targets.removeValue(forKey: id) } else { targets[id] = entered }
            }
            patch.childTargets = .set(targets.map { PlacementChildTarget(childId: $0.key, target: $0.value) })
        }
        return patch
    }
}
