import Foundation

/// Shared "Reads as: Action — Goal — Unit" live preview for counting task and
/// compound counting sub-task editors. Returns nil when all three fields are
/// blank; blanks render as an em dash.
func risoReadsAsPreview(action: String, goal: String, unit: String, kind: CountKind = .discrete) -> String? {
    let a = action.trimmingCharacters(in: .whitespaces)
    let g = goal.trimmingCharacters(in: .whitespaces)
    let u = unit.trimmingCharacters(in: .whitespaces)
    // Duration has no counted noun — the unit segment is dropped.
    if kind == .duration {
        guard !a.isEmpty || !g.isEmpty else { return nil }
        return "Reads as: \(a.isEmpty ? "—" : a) — \(g.isEmpty ? "—" : g)"
    }
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
    /// The sub-task's task type, for its card badge: `.normal` / `.counting`
    /// for a sub-task minted in the editor; the linked task's own type (which
    /// may be `.compound` — a nested compound, title-only) for an existing
    /// one. `isCounting` stays the switch for the Action/Goal/Unit fields.
    /// Twin of web `ChildPatch.childType`.
    var childType: TaskType
    var action: String = ""
    var goal: String = ""
    var unit: String = ""
    /// Counter kind (Counting only): picked for a NEW sub-task, the task's
    /// own for an existing one (no picker — its goal edits at its own kind).
    var countKind: CountKind = .discrete
    var markedDeleted: Bool = false

    var isNew: Bool { childTaskId == nil }

    /// - Parameter childType: Defaults to `.counting` / `.normal` per `isCounting`.
    init(id: String, childTaskId: String?, title: String, isCounting: Bool, childType: TaskType? = nil,
         action: String = "", goal: String = "", unit: String = "",
         countKind: CountKind = .discrete, markedDeleted: Bool = false) {
        self.id = id
        self.childTaskId = childTaskId
        self.title = title
        self.isCounting = isCounting
        self.childType = childType ?? (isCounting ? .counting : .normal)
        self.action = action
        self.goal = goal
        self.unit = unit
        self.countKind = countKind
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
        self.childType = child.type
        self.action = child.action ?? ""
        self.goal = child.maxCount.map { formatCountForInput($0, kind: resolveCountKind(child.countKind)) } ?? ""
        self.unit = child.unit ?? ""
        self.countKind = resolveCountKind(child.countKind)
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
    /// The task's own kind (seeded on open; the goal text is in this kind's grammar).
    var countKind: CountKind = .discrete
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
        self.goal = task.maxCount.map { formatCountForInput($0, kind: resolveCountKind(task.countKind)) } ?? ""
        self.unit = task.unit ?? ""
        self.countKind = resolveCountKind(task.countKind)
        self.operatorType = task.operatorType
        self.threshold = task.threshold
    }

    private var trimmedTitle: String { title.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var parsedGoal: CountValue? { parseCountInput(goal, kind: countKind) }

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

    /// The editor's current kept children for the compound link guard: the
    /// task id of every existing or picked sub-task not marked deleted (new
    /// drafts have no id yet). Twin of web `keptChildTaskIds`.
    var keptChildTaskIds: Set<String> {
        Set(children.compactMap { $0.markedDeleted ? nil : $0.childTaskId })
    }

    /// Live "Reads as: Action — Goal — Unit" preview for counting editors.
    /// nil when all three fields are blank.
    var countingPreview: String? {
        risoReadsAsPreview(action: action, goal: goal, unit: unit, kind: countKind)
    }

    /// The blocking validation message, or nil when the patch is valid for the
    /// given task type. Handles `.normal`, `.counting`, and `.compound`;
    /// `.achievement` isn't editable in the pool (returns nil).
    ///
    /// `countsToward` — the compound counts toward a counter
    /// (docs/SHARED_COUNTER_SETTINGS.md §3a): an unfilled container with zero
    /// sub-tasks is then allowed. Web twin: `validatePatch`'s `opts.countsToward`.
    func validate(type: TaskType, countsToward: Bool = false) -> String? {
        switch type {
        case .counting:
            // Counting titles are optional (auto-generated), so no title check.
            guard let g = parsedGoal, g > 0 else { return "Set a goal above zero." }
            if countKindNeedsUnit(countKind), unit.trimmingCharacters(in: .whitespaces).isEmpty {
                return "Add a unit, like km or pages."
            }
            return nil
        case .normal:
            return trimmedTitle.isEmpty ? "A title is required." : nil
        case .compound:
            if trimmedTitle.isEmpty { return "A title is required." }
            let kept = liveChildren
            // One sub-task is enough (2026-10-06, owner ask); zero stays blocked —
            // except for a container that counts toward a counter (§3a).
            if kept.count < 1 && !countsToward { return "A compound task needs a sub-task." }
            for child in kept where child.isCounting {
                let goalOK = parseCountInput(child.goal, kind: child.countKind) != nil
                let unitOK = !countKindNeedsUnit(child.countKind)
                    || !child.unit.trimmingCharacters(in: .whitespaces).isEmpty
                if !goalOK || !unitOK {
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
    /// (`AppDatabase.applyStagedCompoundChildEdits`), not here. A blank
    /// counting title renders through the counter root's templates
    /// (`settings`, default the task's own — docs/SHARED_COUNTER_SETTINGS.md §1b).
    func applied(to base: OYBC.Task, settings: CounterSettings.TitleSettings? = nil) -> OYBC.Task {
        var t = base
        switch base.type {
        case .counting:
            // A linked row never takes a kind from a patch.
            let kind = base.sharedCounterId == nil ? countKind : resolveCountKind(base.countKind)
            let a = action.trimmingCharacters(in: .whitespaces)
            let u = countKindNeedsUnit(kind) ? unit.trimmingCharacters(in: .whitespaces) : ""
            let g = parseCountInput(goal, kind: kind) ?? base.maxCount ?? 0
            t.action = a
            t.unit = u
            t.maxCount = g
            // Written explicitly (incl. .discrete) when it changes — sync merge-writes and
            // countKind is not a clearable field, so it is never set back to nil.
            if kind != resolveCountKind(base.countKind) { t.countKind = kind }
            let typed = trimmedTitle
            t.title = typed.isEmpty
                ? TaskTitle.generateCounterTaskTitle(
                    action: a, maxCount: g, unit: u, countKind: kind,
                    settings: settings ?? CounterSettings.TitleSettings(task: base)
                )
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
    static func seededForEditor(
        from task: OYBC.Task, settings: CounterSettings.TitleSettings? = nil
    ) -> TaskEditPatch {
        var patch = TaskEditPatch(from: task)
        // A title rendered from the counter root's templates is auto too
        // (docs/SHARED_COUNTER_SETTINGS.md §1b); `settings` defaults to the task's own.
        if task.type == .counting, TaskTitle.isAutoCounterTitle(
            title: task.title, action: task.action ?? "", maxCount: task.maxCount, unit: task.unit ?? "",
            countKind: resolveCountKind(task.countKind), settings: settings ?? CounterSettings.TitleSettings(task: task)
        ) {
            patch.title = ""
        }
        return patch
    }
}
