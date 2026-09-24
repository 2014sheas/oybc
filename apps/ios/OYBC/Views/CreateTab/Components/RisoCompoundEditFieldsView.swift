import SwiftUI

/// The compound structure editor — the shared `RisoCompoundRulePicker`
/// ("Counts as done when…"), the numbered sub-task cards (title, fixed type
/// indicator, counting Action/Goal/Unit + "Reads as" preview, ✕ unlink) and
/// the "+ Normal / + Counting sub-task" buttons — bound to a `TaskEditPatch`.
///
/// Extracted verbatim from `RisoPoolRowEditorView` so the wizard's inline row
/// editor and the Task Detail `EditTaskSheet` ("Sub-tasks & rule") edit a
/// compound through the same UI. Stateless: every edit writes straight into
/// `draft`; persisting is the host's job (staged edits in the wizard,
/// `AppDatabase.applyTaskEditPatch` from Task Detail). The draft's `title`
/// is neither shown nor edited here — the host owns the Title field.
struct RisoCompoundEditFieldsView: View {

    /// The compound structure being edited (operator / threshold / children).
    @Binding var draft: TaskEditPatch

    var body: some View {
        compoundFields
    }

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
                        draft.threshold = CompoundEvaluation.clampCompoundThreshold(draft.threshold ?? 2, childCount: draft.liveChildren.count)
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
}
