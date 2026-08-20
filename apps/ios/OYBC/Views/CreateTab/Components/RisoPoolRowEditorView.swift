import SwiftUI

/// Inline pool-row editor (Inline Task Editing) — renders `.normal`,
/// `.counting`, and `.compound` tasks.
///
/// Replaces a resting `RisoPoolListView` row in place: an accent header bar, a
/// Title field (autofocused), the counting Action/Goal/Unit row with a live
/// "Reads as" preview, the compound SUB-TASKS editor (the shared
/// `RisoCompoundRulePicker` + sub-task cards + add-sub-task buttons), a
/// validation line, and Discard / Save actions. Edits are staged only —
/// nothing touches the DB until the board is created (`onSave` writes the
/// parent's `stagedEdits`).
struct RisoPoolRowEditorView: View {

    let taskType: TaskType
    @Binding var draft: TaskEditPatch
    let onSave: () -> Void
    let onDiscard: () -> Void

    @FocusState private var titleFocused: Bool

    private var validationMessage: String? { draft.validate(type: taskType) }
    private var isBlocked: Bool { validationMessage != nil }

    var body: some View {
        VStack(spacing: 0) {
            headerBar
            VStack(alignment: .leading, spacing: 11) {
                titleField
                if taskType == .counting { countingFields }
                if taskType == .compound { compoundFields }
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
            HStack(alignment: .top, spacing: 8) {
                labeledField("Action", flex: true) {
                    RisoTextField(placeholder: "e.g. Run", text: $draft.action)
                }
                labeledField("Goal", width: 64) {
                    RisoNumberField(placeholder: "5", text: $draft.goal)
                }
                labeledField("Unit", flex: true) {
                    RisoTextField(placeholder: "km", text: $draft.unit)
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
    }

    /// Live "Title: {derived title}" preview for the counting editor —
    /// blank until Action/Unit are non-empty and Goal is a valid positive
    /// integer (mirrors `RisoSpecialTaskPanel.countingTitle` /
    /// `RisoCompoundFieldsView.subCountingTitle`).
    private var countingDerivedTitle: String {
        let a = draft.action.trimmingCharacters(in: .whitespacesAndNewlines)
        let g = draft.goal.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = draft.unit.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !u.isEmpty, let goal = Int(g), goal > 0 else { return "" }
        return TaskTitle.generateCounterTaskTitle(action: a, maxCount: goal, unit: u)
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

    // MARK: - Compound sub-tasks

    /// Compound rule (as a `CompoundRuleChoice`), bridged to `draft.operatorType`.
    /// Switching to `.atLeastN` seeds a default threshold when none is staged
    /// yet; switching away nils the threshold out (mirrors `applied(to:)`'s
    /// persist-time clamp/clear, so the picker and the eventual save agree).
    private var ruleBinding: Binding<CompoundRuleChoice> {
        Binding(
            get: { CompoundRuleChoice(operator: draft.operatorType) },
            set: { newRule in
                draft.operatorType = newRule.toOperator()
                if newRule == .atLeastN {
                    if draft.threshold == nil { draft.threshold = 2 }
                } else {
                    draft.threshold = nil
                }
            }
        )
    }

    private var thresholdBinding: Binding<Int> {
        Binding(
            get: { draft.threshold ?? 2 },
            set: { draft.threshold = $0 }
        )
    }

    private var compoundFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Shared rule picker (chips + conditional "How many?" stepper) —
            // the same `RisoCompoundRulePicker` the create panel uses, so the
            // two compound builders can't visually drift apart.
            VStack(alignment: .leading, spacing: 5) {
                Text("Counts as done when…").risoSectionLabel(.risoRed)
                RisoCompoundRulePicker(
                    rule: ruleBinding,
                    threshold: thresholdBinding,
                    subCount: draft.liveChildren.count
                )
            }

            Text("Sub-tasks").risoSectionLabel(.risoRed)
            ForEach($draft.children) { $child in
                subtaskCard($child)
            }
            HStack(spacing: 7) {
                addSubtaskButton(title: "+ Normal sub-task", isCounting: false)
                addSubtaskButton(title: "+ Counting sub-task", isCounting: true)
            }
            Text("A sub-task's type is fixed once added. Deleting a sub-task unlinks it — if it lives on another board it stays in your library.")
                .font(.risoBody(10.5, .semibold))
                .foregroundStyle(Color.risoMuted)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    private func subtaskCard(_ child: Binding<ChildPatch>) -> some View {
        let index = (draft.children.firstIndex { $0.id == child.wrappedValue.id } ?? 0) + 1
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Text("\(index)")
                    .font(.risoHead(9.5, .extraBold))
                    .foregroundStyle(Color.risoInk)
                    .frame(width: 20, height: 20)
                    .background(RoundedRectangle(cornerRadius: 5).fill(Color.risoPaper2))
                    .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
                RisoTextField(placeholder: "Sub-task title", text: child.title)
                subtaskTypeIndicator(isCounting: child.wrappedValue.isCounting)
                Button {
                    let id = child.wrappedValue.id
                    draft.children.removeAll { $0.id == id }
                    // Mirror the create panel: shrinking the sub-task set below an
                    // "At least N" threshold clamps N down so the rule stays valid.
                    if draft.operatorType == .mOfN {
                        draft.threshold = min(draft.threshold ?? 2, max(1, draft.liveChildren.count))
                    }
                } label: {
                    Text("✕")
                        .font(.system(size: 13, weight: .semibold))
                        .foregroundStyle(Color.risoMuted)
                        .frame(width: 24, height: 24)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel("Delete sub-task")
            }
            if child.wrappedValue.isCounting {
                VStack(alignment: .leading, spacing: 4) {
                    HStack(spacing: 6) {
                        RisoTextField(placeholder: "e.g. Run", text: child.action).frame(maxWidth: .infinity)
                        RisoNumberField(placeholder: "5", text: child.goal).frame(width: 56)
                        RisoTextField(placeholder: "km", text: child.unit).frame(maxWidth: .infinity)
                    }
                    if let preview = subtaskCountingPreview(child.wrappedValue) {
                        Text(preview)
                            .font(.risoBody(10.5, .extraBold))
                            .foregroundStyle(Color.risoBlue)
                    }
                }
                .padding(.leading, 27)
            }
        }
        .padding(7)
        .risoCard(fill: .risoPaper)
    }

    private func subtaskTypeIndicator(isCounting: Bool) -> some View {
        Text(isCounting ? "C" : "N")
            .font(.risoHead(9.5, .extraBold))
            .foregroundStyle(isCounting ? Color.risoPaper : Color.risoInk)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(isCounting ? Color.risoBlue : Color.risoPaper2))
            .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
            .accessibilityLabel(isCounting ? "Counting sub-task" : "Normal sub-task")
    }

    private func addSubtaskButton(title: String, isCounting: Bool) -> some View {
        Button {
            draft.children.append(
                ChildPatch(id: AppDatabase.generateUUID(), childTaskId: nil, title: "", isCounting: isCounting)
            )
        } label: {
            Text(title)
                .font(.risoHead(12, .extraBold))
                .foregroundStyle(Color.risoInk)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 8)
                .overlay(
                    RoundedRectangle(cornerRadius: Riso.cardRadius)
                        .strokeBorder(style: StrokeStyle(lineWidth: Riso.Keyline.container, dash: [4, 3]))
                        .foregroundStyle(Color.risoInk)
                )
        }
        .buttonStyle(.plain)
    }

    private func subtaskCountingPreview(_ child: ChildPatch) -> String? {
        risoReadsAsPreview(action: child.action, goal: child.goal, unit: child.unit)
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
