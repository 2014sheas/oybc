import Foundation

/// The pure half of the counter sheet's EDIT mode (`NewCounterSheetView` with
/// `root`). A counter is edited through the counter sheet, never the task
/// editor (owner rule 2026-10-09): the same fields as create — Kind, "What are
/// you counting?" (unit), "Task verb" (action) — saved through the Task Detail
/// write (`AppDatabase.applyTaskEditPatch`), so #575 root → copy propagation
/// and the D5 family kind switch apply unchanged. Web twin:
/// `components/counters/counterEditModel.ts`.
enum CounterEditModel {

    /// The sheet's editable fields.
    struct Draft: Equatable {
        /// "Task verb" — stored as `action`; blank submits as "Do".
        var verb: String
        /// "What are you counting?" — stored as `unit`.
        var noun: String
        var kind: CountKind
    }

    /// Fallback verb for a blank "Task verb" (the create sheet's rule).
    static let defaultVerb = "Do"

    /// The sheet's fields seeded from the counter's root.
    ///
    /// - Parameter root: The counter's root task.
    /// - Returns: The prefilled draft.
    static func seed(_ root: Task) -> Draft {
        Draft(verb: root.action ?? "", noun: root.unit ?? "", kind: resolveCountKind(root.countKind))
    }

    /// The `applyTaskEditPatch` patch for a draft: action / unit, `countKind`
    /// only when it changed, the root's own description (kept), no goal
    /// (`maxCountStr` "" leaves it to the kind switch), no type — and the
    /// title, regenerated from the new fields (at the goal the kind switch
    /// leaves) when the root's title is auto, else kept verbatim.
    ///
    /// - Parameters:
    ///   - root: The counter's root task (stored).
    ///   - draft: The sheet's fields.
    /// - Returns: The patch for `applyTaskEditPatch(taskId: root.id, …)`.
    static func patch(root: Task, draft: Draft) -> EditTaskSheet.Patch {
        let storedKind = resolveCountKind(root.countKind)
        let action = trimmed(draft.verb).isEmpty ? defaultVerb : trimmed(draft.verb)
        let unit = trimmed(draft.noun)
        let kindChanged = draft.kind != storedKind
        let goal = kindChanged
            ? (planCountKindSwitch(maxCount: root.maxCount, defaultLogAmount: nil, from: storedKind, to: draft.kind)?.maxCount ?? root.maxCount)
            : root.maxCount
        let settings = CounterSettings.TitleSettings(task: root)
        let auto = TaskTitle.isAutoCounterTitle(
            title: root.title, action: root.action ?? "", maxCount: root.maxCount, unit: root.unit ?? "",
            countKind: storedKind, settings: settings
        )
        // Re-rendered through the root's stored name / templates (absent = the formula).
        let title = auto
            ? TaskTitle.renderedTitle(settings, action: action, unit: unit, countKind: draft.kind, goal: goal)
            : root.title
        return EditTaskSheet.Patch(
            title: title, description: root.description ?? "", action: action, unit: unit, maxCountStr: "",
            trigger: .bingo, requiredCountStr: "", refMode: .board, selectedBoardId: "", selectedTemplateId: "",
            countKind: kindChanged ? draft.kind : nil
        )
    }

    /// Whether the draft renames the counter (its verb / noun identity) — only
    /// then does the sheet check for an established counter of that name.
    static func identityChanged(root: Task, draft: Draft) -> Bool {
        let seed = seed(root)
        func verb(_ v: String) -> String { trimmed(v).isEmpty ? defaultVerb : trimmed(v) }
        return verb(draft.verb) != verb(seed.verb) || trimmed(draft.noun) != trimmed(seed.noun)
    }

    /// The dedupe pool for a rename: every task except the counter's own
    /// family (the root and the rows linking to it).
    static func dedupePool(root: Task, tasks: [Task]) -> [Task] {
        tasks.filter { $0.id != root.id && $0.sharedCounterId != root.id }
    }

    private static func trimmed(_ s: String) -> String {
        s.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
