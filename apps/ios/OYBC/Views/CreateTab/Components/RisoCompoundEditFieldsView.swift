import SwiftUI

/// The compound structure editor — the shared `RisoCompoundRulePicker`
/// ("Counts as done when…"), the numbered sub-task cards (title, fixed type
/// indicator, counting Action/Goal/Unit + "Reads as" preview, ✕ unlink) and
/// the wizard's own quick-add row (`RisoQuickAddRowView`) to add a sub-task:
/// typing lists matching eligible library tasks — tap one to link it
/// (`appendPicked`); Return / Add appends a NEW sub-task titled with the
/// text, Normal or Counting per the "New sub:" chips (`appendTyped`). Same
/// job, same interface as adding a task to a board. Bound to a
/// `TaskEditPatch`.
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
    /// The compound being edited — the link guard's `parentId`.
    var parentId: String
    /// Browsable library tasks (`TaskLibraryViewModel.browsableTasks` —
    /// wizard drafts and deleted rows already hidden). Narrowed via
    /// `CompoundChildEligibility.pickerCandidates` and offered as the
    /// quick-add row's matches.
    var libraryTasks: [Task]
    /// Live compound links across ALL compounds (for the loop check).
    var allLinks: [CompoundChild]
    /// Whether `libraryTasks` / `allLinks` have loaded (Task Detail loads them
    /// on open; the wizard already holds them).
    var libraryInputsState: LibraryInputsState = .loaded

    /// Load state of the host's library inputs. Twin of web `LibraryInputsState`.
    enum LibraryInputsState: Equatable {
        case loading, loaded, failed
    }

    /// The "New sub:" chip — whether Return / Add appends a Counting sub-task.
    @State private var newSubCounting = false

    var body: some View {
        compoundFields
    }

    // MARK: - Append paths (static for unit tests)

    /// Appends a library task picked from the quick-add row's matches as a
    /// LINKED sub-task (the save links the existing task; nothing is created).
    ///
    /// - Parameters:
    ///   - task: The picked (eligible) library task.
    ///   - draft: The compound structure being edited.
    static func appendPicked(_ task: Task, to draft: inout TaskEditPatch) {
        draft.children.append(ChildPatch(from: task))
    }

    /// Appends a NEW sub-task typed into the quick-add row (Return / Add). A
    /// Normal sub-task takes the text as its title; a Counting one also takes
    /// it as its action (Goal / Unit are then filled on its card). Twin of
    /// web `appendTypedChild`.
    ///
    /// - Parameters:
    ///   - text: The trimmed text from the row.
    ///   - isCounting: Whether the "Counting" chip is on.
    ///   - draft: The compound structure being edited.
    static func appendTyped(_ text: String, isCounting: Bool, to draft: inout TaskEditPatch) {
        draft.children.append(
            ChildPatch(
                id: AppDatabase.generateUUID(),
                childTaskId: nil,
                title: text,
                isCounting: isCounting,
                action: isCounting ? text : ""
            )
        )
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
            subtaskQuickAdd
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
                subtaskTypeIndicator(child.wrappedValue)
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

    /// The kit's letter badge (normal N, counting #, compound C) — the same
    /// square the picker rows use. A picked nested compound badges C; its card
    /// edits only the title (no counting fields) and ✕ only unlinks it.
    private func subtaskTypeIndicator(_ child: ChildPatch) -> some View {
        RisoTypeBadge(kind: RisoTaskKind(taskType: child.childType), style: .letterSquare)
            .frame(width: 26, height: 26)
            .accessibilityElement(children: .ignore)
            .accessibilityLabel(Self.subtaskTypeLabel(child.childType))
    }

    /// VoiceOver name for a sub-task card's type badge.
    static func subtaskTypeLabel(_ type: TaskType) -> String {
        switch type {
        case .counting: return "Counting sub-task"
        case .compound: return "Compound sub-task"
        default: return "Normal sub-task"
        }
    }

    /// The wizard's own quick-add row, draft-only (`onSubmitText`): Return
    /// appends a new sub-task (no task is created until Save); a tapped match
    /// links that existing task. `userId` / `onTaskCreated` /
    /// `onLibraryReloadRequested` feed only the create path, which
    /// `onSubmitText` replaces. Below it: the "New sub:" type chips and the
    /// library load line.
    private var subtaskQuickAdd: some View {
        VStack(alignment: .leading, spacing: 8) {
            RisoQuickAddRowView(
                userId: "",
                defaultStartDate: nil,
                defaultEndDate: nil,
                onTaskCreated: { _, _, _ in },
                onPendingCreated: nil,
                onLibraryReloadRequested: {},
                libraryTasks: CompoundChildEligibility.pickerCandidates(
                    parentId: parentId,
                    browsable: libraryTasks,
                    allLinks: allLinks,
                    currentChildIds: draft.keptChildTaskIds
                ),
                onExistingTaskPicked: { task in Self.appendPicked(task, to: &draft) },
                onSubmitText: { text in Self.appendTyped(text, isCounting: newSubCounting, to: &draft) }
            )
            .disabled(libraryInputsState == .loading)

            HStack(spacing: 8) {
                Text("New sub:")
                    .font(.risoBody(12, .semibold))
                    .foregroundStyle(Color.risoMuted)
                RisoChip(title: "Normal", isOn: !newSubCounting) { newSubCounting = false }
                    .accessibilityAddTraits(!newSubCounting ? .isSelected : [])
                RisoChip(title: "Counting", isOn: newSubCounting) { newSubCounting = true }
                    .accessibilityAddTraits(newSubCounting ? .isSelected : [])
            }

            switch libraryInputsState {
            case .loading:
                Text("Loading your tasks…")
                    .font(.risoBody(11.5, .semibold))
                    .foregroundStyle(Color.risoMuted)
            case .failed:
                Text("Couldn't load your tasks to link. New sub-tasks still work — close and reopen the editor to try again.")
                    .font(.risoBody(11.5, .semibold))
                    .foregroundStyle(Color.risoRed)
                    .fixedSize(horizontal: false, vertical: true)
            case .loaded:
                EmptyView()
            }
        }
    }

    private func subtaskCountingPreview(_ child: ChildPatch) -> String? {
        risoReadsAsPreview(action: child.action, goal: child.goal, unit: child.unit)
    }
}
