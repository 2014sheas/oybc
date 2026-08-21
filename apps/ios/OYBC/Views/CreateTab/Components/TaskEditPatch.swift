import Foundation

/// Shared "Reads as: Action — Goal — Unit" live preview for counting task and
/// compound counting sub-task editors. Returns nil when all three fields are
/// blank; blanks render as an em dash.
func risoReadsAsPreview(action: String, goal: String, unit: String) -> String? {
    let a = action.trimmingCharacters(in: .whitespaces)
    let g = goal.trimmingCharacters(in: .whitespaces)
    let u = unit.trimmingCharacters(in: .whitespaces)
    guard !a.isEmpty || !g.isEmpty || !u.isEmpty else { return nil }
    return "Reads as: \(a.isEmpty ? "—" : a) — \(g.isEmpty ? "—" : g) — \(u.isEmpty ? "—" : u)"
}

/// A single compound sub-task edit.
struct ChildPatch: Identifiable, Equatable {
    /// Stable identity for SwiftUI: the child task id for existing links, or a
    /// fresh UUID for a not-yet-created sub-task.
    var id: String
    /// nil ⇒ a new sub-task created in the editor (see `isNew`).
    var childTaskId: String?
    var title: String
    /// A counting sub-task is a Counting child (Action/Goal/Unit); otherwise
    /// a Normal sub-task. A sub-task's type is fixed once added.
    var isCounting: Bool
    var action: String = ""
    var goal: String = ""
    var unit: String = ""
    var markedDeleted: Bool = false

    var isNew: Bool { childTaskId == nil }

    init(id: String, childTaskId: String?, title: String, isCounting: Bool,
         action: String = "", goal: String = "", unit: String = "", markedDeleted: Bool = false) {
        self.id = id
        self.childTaskId = childTaskId
        self.title = title
        self.isCounting = isCounting
        self.action = action
        self.goal = goal
        self.unit = unit
        self.markedDeleted = markedDeleted
    }

    /// Clone a sub-task from an existing child Task. A Counting child is a
    /// "counting" sub-task (Action/Goal/Unit); anything else is a Normal
    /// sub-task.
    init(from child: OYBC.Task) {
        self.id = child.id
        self.childTaskId = child.id
        self.title = child.title
        self.isCounting = child.type == .counting
        self.action = child.action ?? ""
        self.goal = child.maxCount.map(String.init) ?? ""
        self.unit = child.unit ?? ""
        self.markedDeleted = false
    }
}

/// A staged, not-yet-persisted edit to a pooled task. Applied ONLY inside the
/// board-create transaction (`saveWizardBoard`) — never while the board is a
/// draft. Modeled on `StagedTaskOverride` (board-edit mode) but carries
/// compound children (+ operator/threshold, for the rule picker) since a
/// compound is editable inline too.
///
/// `goal` is a String (not Int) so an in-progress empty field is representable
/// while the user types.
struct TaskEditPatch: Equatable {
    var title: String
    var action: String = ""
    var goal: String = ""
    var unit: String = ""
    var children: [ChildPatch] = []
    /// Compound completion operator. Seeded from `Task.operatorType` on open;
    /// written back onto the Task row in `applied(to:)`. `nil` for non-
    /// compound patches (never read).
    var operatorType: OperatorType?
    /// Compound "at least N" threshold. Only meaningful when
    /// `operatorType == .mOfN`; `applied(to:)` clamps it into
    /// `1...max(1, liveChildren.count)` and nils it out for `.and`/`.or`.
    var threshold: Int?

    init(title: String) { self.title = title }

    /// Clone the editable fields from a task on open. Compound children are
    /// populated by the caller from `effectiveChildrenByCompound`.
    init(from task: OYBC.Task) {
        self.title = task.title
        self.action = task.action ?? ""
        self.goal = task.maxCount.map(String.init) ?? ""
        self.unit = task.unit ?? ""
        self.operatorType = task.operatorType
        self.threshold = task.threshold
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var parsedGoal: Int? { Int(goal.trimmingCharacters(in: .whitespaces)) }

    /// Kept sub-tasks — excludes deleted and blank-titled entries (dropped on
    /// save). Shared by validation, apply-at-create clamping, the inline
    /// rule picker's max clamp, and the wizard's staged-overlay pool
    /// subtitle/preview — the one place "how many sub-tasks does this patch
    /// really have right now" is computed.
    var liveChildren: [ChildPatch] {
        children.filter {
            !$0.markedDeleted && !$0.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        }
    }

    /// Live "Reads as: Action — Goal — Unit" preview for counting editors.
    /// nil when all three fields are blank.
    var countingPreview: String? {
        risoReadsAsPreview(action: action, goal: goal, unit: unit)
    }

    /// The blocking validation message, or nil when the patch is valid for the
    /// given task type. Handles `.normal`, `.counting`, and `.compound`;
    /// `.achievement` isn't editable in the pool (returns nil).
    func validate(type: TaskType) -> String? {
        switch type {
        case .counting:
            // Counting titles are optional (auto-generated), so no title check.
            guard let g = parsedGoal, g > 0 else { return "Set a goal above zero." }
            if unit.trimmingCharacters(in: .whitespaces).isEmpty {
                return "Add a unit, like km or pages."
            }
            return nil
        case .normal:
            return trimmedTitle.isEmpty ? "A title is required." : nil
        case .compound:
            if trimmedTitle.isEmpty { return "A title is required." }
            let kept = liveChildren
            if kept.count < 2 { return "Add at least 2 sub-tasks." }
            for child in kept where child.isCounting {
                let g = Int(child.goal.trimmingCharacters(in: .whitespaces)) ?? 0
                let u = child.unit.trimmingCharacters(in: .whitespaces)
                if g <= 0 || u.isEmpty {
                    let name = child.title.trimmingCharacters(in: .whitespacesAndNewlines)
                    return "Counting sub-task \"\(name)\" needs a goal and a unit."
                }
            }
            if operatorType == .mOfN {
                guard let t = threshold, t >= 1, t <= kept.count else {
                    return "Choose how many sub-tasks must complete."
                }
            }
            return nil
        default:
            return nil
        }
    }

    /// Applies the patch's title/counting/compound-rule fields to a base
    /// task. Assumes `validate` already passed. Does NOT bump
    /// `version`/`updatedAt` — the persist caller owns that. Compound child
    /// Task/link CRUD is applied by the persist layer
    /// (`AppDatabase.applyStagedCompoundChildEdits`), not here.
    func applied(to base: OYBC.Task) -> OYBC.Task {
        var t = base
        switch base.type {
        case .counting:
            let a = action.trimmingCharacters(in: .whitespaces)
            let u = unit.trimmingCharacters(in: .whitespaces)
            let g = parsedGoal ?? base.maxCount ?? 0
            t.action = a
            t.unit = u
            t.maxCount = g
            let typed = trimmedTitle
            t.title = typed.isEmpty
                ? TaskTitle.generateCounterTaskTitle(action: a, maxCount: g, unit: u)
                : typed
        case .compound:
            // Parent-level fields only; child Task/link CRUD is applied by the
            // persist layer (saveWizardBoard / pending merge), not here.
            t.title = trimmedTitle
            t.operatorType = operatorType
            if operatorType == .mOfN {
                t.threshold = CompoundEvaluation.clampCompoundThreshold(threshold ?? 1, childCount: liveChildren.count)
            } else {
                t.threshold = nil
            }
        default:
            t.title = trimmedTitle
        }
        return t
    }
}

extension TaskEditPatch {
    /// Editor-seeding variant of `init(from:)` — used only when the inline
    /// pool-row editor opens a row for the FIRST time (reopens reuse the
    /// staged patch verbatim; see `BoardWizardTasksStepView.openEditor`).
    ///
    /// For a Counting task whose stored title still matches its
    /// auto-generated form, seeds the Title field BLANK so it keeps
    /// auto-deriving as Action/Goal/Unit change in the editor — a non-blank
    /// seeded title reads as "custom" in `applied(to:)` and would otherwise
    /// never re-derive (bug: editing the goal didn't update the title). A
    /// genuinely custom title is preserved verbatim. `init(from:)` itself is
    /// left unchanged — it's also asserted directly by
    /// `TaskEditPatchTests.test_init_from_counting_task_clones_fields`.
    static func seededForEditor(from task: OYBC.Task) -> TaskEditPatch {
        var patch = TaskEditPatch(from: task)
        if task.type == .counting {
            let autoTitle = TaskTitle.generateCounterTaskTitle(
                action: task.action ?? "", maxCount: task.maxCount, unit: task.unit ?? ""
            )
            if task.title == autoTitle {
                patch.title = ""
            }
        }
        return patch
    }
}
