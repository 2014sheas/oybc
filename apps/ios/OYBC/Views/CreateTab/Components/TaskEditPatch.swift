import Foundation

/// A single compound-step edit. Present in PR 1's model so PR 2 (compound
/// editing) needs no model change; PR 1 never populates `children`.
struct ChildPatch: Identifiable, Equatable {
    /// Stable identity for SwiftUI: the child task id for existing links, or a
    /// fresh UUID for a not-yet-created step.
    var id: String
    /// nil ⇒ a new step created in the editor (see `isNew`).
    var childTaskId: String?
    var title: String
    /// A "progress" step is a counting child (Action/Goal/Unit); otherwise a
    /// simple step. A step's type is fixed once added.
    var isProgress: Bool
    var action: String = ""
    var goal: String = ""
    var unit: String = ""
    var markedDeleted: Bool = false

    var isNew: Bool { childTaskId == nil }
}

/// A staged, not-yet-persisted edit to a pooled task. Applied ONLY inside the
/// board-create transaction (`saveWizardBoard`) — never while the board is a
/// draft. Modeled on `StagedTaskOverride` (board-edit mode) but carries
/// compound children so the same type serves PR 2.
///
/// `goal` is a String (not Int) so an in-progress empty field is representable
/// while the user types.
struct TaskEditPatch: Equatable {
    var title: String
    var action: String = ""
    var goal: String = ""
    var unit: String = ""
    var ordered: Bool = false
    var children: [ChildPatch] = []

    init(title: String) { self.title = title }

    /// Clone the editable fields from a task on open. Compound children are
    /// populated by the caller (PR 2) from `effectiveChildrenByCompound`.
    init(from task: OYBC.Task) {
        self.title = task.title
        self.action = task.action ?? ""
        self.goal = task.maxCount.map(String.init) ?? ""
        self.unit = task.unit ?? ""
        self.ordered = task.isOrdered ?? false
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var parsedGoal: Int? { Int(goal.trimmingCharacters(in: .whitespaces)) }

    /// Live "Reads as: Action — Goal — Unit" preview for counting editors.
    /// nil when all three fields are blank.
    var countingPreview: String? {
        let a = action.trimmingCharacters(in: .whitespaces)
        let g = goal.trimmingCharacters(in: .whitespaces)
        let u = unit.trimmingCharacters(in: .whitespaces)
        guard !a.isEmpty || !g.isEmpty || !u.isEmpty else { return nil }
        return "Reads as: \(a.isEmpty ? "—" : a) — \(g.isEmpty ? "—" : g) — \(u.isEmpty ? "—" : u)"
    }

    /// The blocking validation message, or nil when the patch is valid for the
    /// given task type. PR 1 handles `.normal` + `.counting`; `.compound`
    /// returns nil here (PR 2 adds compound-step validation); `.achievement`
    /// isn't editable in the pool.
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
        default:
            return nil
        }
    }

    /// Applies the patch's title/counting fields to a base task. Assumes
    /// `validate` already passed. Does NOT bump `version`/`updatedAt` — the
    /// persist caller owns that. Compound children are applied by the persist
    /// layer in PR 2, not here.
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
        default:
            t.title = trimmedTitle
        }
        return t
    }
}
