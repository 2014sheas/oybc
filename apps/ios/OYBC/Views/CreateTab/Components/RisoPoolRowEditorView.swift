import SwiftUI

/// Inline pool-row editor (Inline Task Editing) — renders `.normal`,
/// `.counting`, and `.compound` tasks.
///
/// Replaces a resting `RisoPoolListView` row in place: an accent header bar, a
/// Title field (autofocused), the counting Action/Goal/Unit row with a live
/// "Reads as" preview, the compound SUB-TASKS editor (`RisoCompoundEditFieldsView`:
/// the shared `RisoCompoundRulePicker` + sub-task cards + the quick-add row), a
/// validation line, and Discard / Save actions. Edits are staged only —
/// nothing touches the DB until the board is created (`onSave` writes the
/// parent's `stagedEdits`).
struct RisoPoolRowEditorView: View {

    /// The row's stored task (its id guards compound links; its kind / link drive the Kind row).
    let task: Task
    var database: AppDatabase = .shared
    @Binding var draft: TaskEditPatch
    /// Compound only — browsable library tasks the sub-task quick-add row matches against.
    let libraryTasks: [Task]
    /// Compound only — live links across all compounds (loop check).
    let allLinks: [CompoundChild]
    let onSave: () -> Void
    let onDiscard: () -> Void

    @FocusState private var titleFocused: Bool
    @State private var pendingSwitch: KindSwitchPreview?

    private var taskId: String { task.id }
    private var taskType: TaskType { task.type }

    private var validationMessage: String? { draft.validate(type: taskType) }
    private var isBlocked: Bool { validationMessage != nil }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            VStack(alignment: .leading, spacing: 11) {
                titleField
                if taskType == .counting { countingFields }
                if taskType == .compound {
                    RisoCompoundEditFieldsView(
                        draft: $draft,
                        parentId: taskId,
                        libraryTasks: libraryTasks,
                        allLinks: allLinks
                    )
                }
                if let msg = validationMessage {
                    Text(msg)
                        .font(.risoBody(11.5, .extraBold))
                        .foregroundStyle(Color.risoRed)
                        .fixedSize(horizontal: false, vertical: true)
                }
                actions
            }
            .padding(12)
        }
        .risoCard(fill: .risoPaper2)
        .risoHardShadow(Riso.Shadow.card)
        .onAppear { titleFocused = true }
    }

    // MARK: - Header

    private var headerBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "pencil")
                .font(.system(size: 14, weight: .bold))
            Text(headerLabel)
                .font(.risoBody(9.5, .extraBold))
                .tracking(1.3)
                .textCase(.uppercase)
            Spacer(minLength: 0)
        }
        .foregroundStyle(Color.risoPaper) // on-color: pairs with the blue fill in both themes
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.risoBlue)
        .overlay(alignment: .bottom) {
            Rectangle().fill(Color.risoInk).frame(height: Riso.Keyline.container)
        }
    }

    private var headerLabel: String {
        switch taskType {
        case .counting: return "Editing · Counting task"
        case .compound: return "Editing · Compound task"
        // "Normal" is the app's domain term for this TaskType (RisoTypeBadge
        // renders .normal as "Normal") — don't paraphrase it as "Simple".
        default: return "Editing · Normal task"
        }
    }

    // MARK: - Fields

    private var titleField: some View {
        VStack(alignment: .leading, spacing: 5) {
            Text("Task title").risoSectionLabel(.risoRed)
            RisoTextField(placeholder: "Task title", text: $draft.title)
                .focused($titleFocused)
        }
    }

    private var countingFields: some View {
        VStack(alignment: .leading, spacing: 7) {
            labeledField("Kind", flex: true) {
                if task.sharedCounterId != nil {
                    KindTagView(linkedTask: task, root: database.linkedCounterRoot(of: task))
                } else {
                    KindPickerView(
                        selection: $draft.countKind,
                        lock: kindPickerLock(mode: .edit, kind: resolveCountKind(task.countKind)),
                        onRequest: requestKind
                    )
                }
            }
            HStack(alignment: .top, spacing: 8) {
                labeledField("Action", flex: true) {
                    RisoTextField(placeholder: "e.g. Run", text: $draft.action)
                }
                labeledField("Goal", width: 84) {
                    GoalEntryView(kind: draft.countKind, text: $draft.goal, placeholder: "5")
                }
                if countKindNeedsUnit(draft.countKind) {
                    labeledField("Unit", flex: true) {
                        RisoTextField(placeholder: "km", text: $draft.unit)
                    }
                }
            }
            if let preview = draft.countingPreview {
                Text(preview)
                    .font(.risoBody(11.5, .bold))
                    .foregroundStyle(Color.risoBlue)
            }
            // Live derived-title preview — matches the create panel
            // (`RisoSpecialTaskPanel.countingTitle`) so the user can see what
            // an auto-generated title will read as once Action/Goal/Unit are
            // filled in (companion to the blank-title reseed in
            // `TaskEditPatch.seededForEditor`).
            if !countingDerivedTitle.isEmpty {
                (Text("Title: ")
                    .font(.risoBody(11, .semibold))
                    .foregroundStyle(Color.risoMuted)
                + Text(countingDerivedTitle)
                    .font(.risoBody(11, .extraBold))
                    .foregroundStyle(Color.risoInk))
            }
        }
        .kindSwitchConfirm(pending: $pendingSwitch) { p in
            draft.goal = KindSwitchCopy.switchedGoalText(draft.goal, from: p.from, to: p.to)
            draft.countKind = p.to
        }
    }

    /// Continuous → Discrete opens the confirm (previewing the DRAFT — title /
    /// goal typed in this editor); any other permitted change applies at once.
    private func requestKind(_ next: CountKind) {
        guard KindSwitchCopy.needsConfirm(from: draft.countKind, to: next) else { draft.countKind = next; return }
        var subject = task
        subject.title = draft.title.isEmpty ? task.title : draft.title
        subject.action = draft.action
        subject.unit = draft.unit
        subject.countKind = draft.countKind
        if let goal = parseCountInput(draft.goal, kind: draft.countKind) { subject.maxCount = goal }
        let linked = (try? database.previewCounterKindSwitch(rootTaskId: task.id, to: next))?.linkedCount ?? 0
        pendingSwitch = KindSwitchPreview.planned(task: subject, to: next, linkedCount: linked)
    }

    /// Live "Title: {derived title}" preview for the counting editor —
    /// blank until Action (and Unit, where the kind has one) are non-empty and
    /// Goal parses at the draft kind (mirrors `RisoSpecialTaskPanel.countingTitle`).
    private var countingDerivedTitle: String {
        let a = draft.action.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = draft.unit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !(countKindNeedsUnit(draft.countKind) && u.isEmpty),
              let goal = parseCountInput(draft.goal, kind: draft.countKind), goal > 0 else { return "" }
        return TaskTitle.generateCounterTaskTitle(
            action: a, maxCount: goal, unit: countKindNeedsUnit(draft.countKind) ? u : "", countKind: draft.countKind
        )
    }

    /// Kicker label above a field. `flex` fields expand; `width` pins a fixed
    /// width (the narrow Goal column).
    @ViewBuilder
    private func labeledField<Content: View>(
        _ label: String, flex: Bool = false, width: CGFloat? = nil,
        @ViewBuilder _ content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            Text(label).risoSectionLabel(.risoRed)
            content()
        }
        .frame(maxWidth: flex ? .infinity : nil)
        .frame(width: width)
    }

    // MARK: - Actions

    private var actions: some View {
        HStack(spacing: 9) {
            RisoButton(title: "Discard", kind: .neutral, fullWidth: true) { onDiscard() }
            RisoButton(title: "Save task", kind: .primary, fullWidth: true) { onSave() }
                .disabled(isBlocked)
                .opacity(isBlocked ? 0.45 : 1)
        }
    }
}
