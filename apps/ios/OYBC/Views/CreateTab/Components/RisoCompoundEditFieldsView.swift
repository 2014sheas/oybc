import SwiftUI

/// The compound structure editor — the shared `RisoCompoundRulePicker`
/// ("Counts as done when…"), the numbered sub-task cards (title, fixed type
/// indicator, counting Action/Goal/Unit + "Reads as" preview, ✕ unlink) and
/// the wizard's own quick-add row (`RisoQuickAddRowView`) to add a sub-task:
/// typing lists matching eligible library tasks — tap one to link it
/// (`appendPicked`); Return / Add appends a NEW sub-task titled with the
/// text, Normal or Counting per the "New sub:" chips (`appendTyped`). With
/// Counting on, the create panel's Goal + Counting config row
/// (`RisoCountingSubConfigRow`) and "Reads as" preview sit under the chips
/// and gate the append (`canAppendCounting`) — the text is the action. Same
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
    /// The FULL task set the sub-task quick-add resolves counter roots against.
    var counterRootTasks: [Task] = []
    /// The host board's window — a picked counter's goal starts at its default
    /// for it (`CounterPlacement.counterPickGoal`). nil: the compound's own
    /// window, else Indefinite (yearly). Web twin: `CompoundFields.goalWindow`.
    var goalWindow: CounterPlacement.PickWindow? = nil
    /// Live compound links across ALL compounds (for the loop check).
    var allLinks: [CompoundChild]
    /// Whether `libraryTasks` / `allLinks` have loaded (Task Detail loads them
    /// on open; the wizard already holds them).
    var libraryInputsState: LibraryInputsState = .loaded

    /// Load state of the host's library inputs. Twin of web `LibraryInputsState`.
    enum LibraryInputsState: Equatable {
        case loading, loaded, failed
    }

    /// Initial state of the new-sub entry (the "New sub:" chip + the row's
    /// text + the Counting config) — seeded by snapshot tests; production
    /// hosts start blank on Normal.
    struct NewSubSeed {
        var counting = false
        var text = ""
        var goal = ""
        var unit = ""
        var kind: CountKind = .discrete
    }

    /// The "New sub:" chip — whether Return / Add appends a Counting sub-task.
    @State private var newSubCounting: Bool
    /// The quick-add row's text, mirrored via `onTextChange` — the new
    /// Counting sub-task's action (preview + gate).
    @State private var newSubText: String
    /// The new Counting sub-task's Goal / Counting (unit) config.
    @State private var newSubGoal: String
    @State private var newSubUnit: String
    @State private var newSubKind: CountKind = .discrete
    /// The hub counter a pick primed the New sub row with (see `pinnedRoot`).
    @State private var newSubCounterId: String?
    private let seedText: String

    /// - Parameters:
    ///   - draft: The compound structure being edited.
    ///   - parentId: The compound being edited — the link guard's `parentId`.
    ///   - libraryTasks: Browsable library tasks offered as quick-add matches.
    ///   - allLinks: Live compound links across ALL compounds (loop check).
    ///   - libraryInputsState: Load state of the host's library inputs.
    ///   - newSubSeed: Initial new-sub entry state (tests only).
    init(
        draft: Binding<TaskEditPatch>,
        parentId: String,
        libraryTasks: [Task],
        counterRootTasks: [Task] = [],
        goalWindow: CounterPlacement.PickWindow? = nil,
        allLinks: [CompoundChild],
        libraryInputsState: LibraryInputsState = .loaded,
        newSubSeed: NewSubSeed = NewSubSeed()
    ) {
        _draft = draft
        self.parentId = parentId
        self.libraryTasks = libraryTasks
        self.counterRootTasks = counterRootTasks
        self.goalWindow = goalWindow
        self.allLinks = allLinks
        self.libraryInputsState = libraryInputsState
        _newSubCounting = State(initialValue: newSubSeed.counting)
        _newSubText = State(initialValue: newSubSeed.text)
        _newSubGoal = State(initialValue: newSubSeed.goal)
        _newSubUnit = State(initialValue: newSubSeed.unit)
        _newSubKind = State(initialValue: newSubSeed.kind)
        seedText = newSubSeed.text
    }

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

    /// The typed goal parsed at `kind` (positive), or nil when blank/invalid.
    private static func parsePositiveGoal(_ goal: String, kind: CountKind) -> CountValue? {
        parseCountInput(goal, kind: kind)
    }

    /// Whether the quick-add row may append a NEW Counting sub-task: the
    /// text (its action) is non-blank, the goal is a positive integer and
    /// the unit is non-blank — the create panel's `canAddSub` gate, so an
    /// untouched Goal can never silently produce a goal-less child. Twin of
    /// web `canAppendCounting`.
    ///
    /// - Parameters:
    ///   - text: The row's text (the action).
    ///   - goal: The Goal field's text.
    ///   - unit: The Counting (unit) field's text.
    ///   - kind: The new sub-task's kind (Duration needs no unit).
    /// - Returns: `true` when all required fields are valid.
    static func canAppendCounting(text: String, goal: String, unit: String, kind: CountKind = .discrete) -> Bool {
        !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && parsePositiveGoal(goal, kind: kind) != nil
            && (!countKindNeedsUnit(kind) || !unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
    }

    /// Appends a NEW sub-task typed into the quick-add row (Return / Add). A
    /// Normal sub-task takes the text as its title; a Counting one takes it
    /// as its action plus the Goal / Unit from the row's counting config,
    /// titled with the derived counter title ("Run 5 km") — the fields stay
    /// editable on its card. Twin of web `appendTypedChild`.
    ///
    /// - Parameters:
    ///   - text: The trimmed text from the row.
    ///   - isCounting: Whether the "Counting" chip is on.
    ///   - goal: The Goal field's text (Counting only).
    ///   - unit: The Counting (unit) field's text (Counting only).
    ///   - kind: The new Counting sub-task's kind.
    ///   - linkedRoot: The hub counter the Counting sub-task links to (picked
    ///     in the sub-task search): titled through its templates, linked,
    ///     counting from its lifetime count.
    ///   - draft: The compound structure being edited.
    static func appendTyped(
        _ text: String,
        isCounting: Bool,
        goal: String = "",
        unit: String = "",
        kind: CountKind = .discrete,
        linkedRoot: Task? = nil,
        to draft: inout TaskEditPatch
    ) {
        guard isCounting else {
            draft.children.append(
                ChildPatch(id: AppDatabase.generateUUID(), childTaskId: nil, title: text, isCounting: false)
            )
            return
        }
        let parsedGoal = parsePositiveGoal(goal, kind: kind)
        let trimmedUnit = countKindNeedsUnit(kind) ? unit.trimmingCharacters(in: .whitespacesAndNewlines) : ""
        let title: String
        if let g = parsedGoal, !trimmedUnit.isEmpty || !countKindNeedsUnit(kind) {
            title = linkedRoot.map { CounterSettings.renderCounterTitle(CounterSettings.Fields(task: $0), goal: g) }
                ?? TaskTitle.generateCounterTaskTitle(action: text, maxCount: g, unit: trimmedUnit, countKind: kind)
        } else {
            title = text
        }
        draft.children.append(
            ChildPatch(
                id: AppDatabase.generateUUID(),
                childTaskId: nil,
                title: title,
                isCounting: true,
                action: text,
                goal: parsedGoal.map { formatCountForInput($0, kind: kind) } ?? "",
                unit: trimmedUnit,
                countKind: kind,
                sharedCounterId: linkedRoot?.id,
                baseline: linkedRoot.map { $0.currentCount ?? 0 }
            )
        )
    }

    /// The sub-task search set: eligible tasks, then every counter in the
    /// library — a search returns the COUNTER, and a pick primes a NEW
    /// Counting sub-task linked to it.
    private var subCandidates: (candidates: [Task], counterIds: Set<String>) {
        QuickAddCounterPlacement.compoundSubCandidates(
            parentId: parentId,
            eligible: CompoundChildEligibility.pickerCandidates(
                parentId: parentId,
                browsable: libraryTasks,
                allLinks: allLinks,
                currentChildIds: draft.keptChildTaskIds
            ),
            library: libraryTasks,
            lookup: counterRootTasks
        )
    }

    /// The primed counter while the row still names it (verb, noun when the
    /// kind has one, kind) — the link target of the next Counting append.
    private var pinnedRoot: Task? {
        guard newSubCounting, let id = newSubCounterId, let root = libraryTasks.first(where: { $0.id == id }),
              newSubKind == resolveCountKind(root.countKind),
              newSubText.trimmingCharacters(in: .whitespacesAndNewlines) == (root.action ?? "").trimmingCharacters(in: .whitespacesAndNewlines),
              !countKindNeedsUnit(newSubKind)
                || newSubUnit.trimmingCharacters(in: .whitespacesAndNewlines) == (root.unit ?? "").trimmingCharacters(in: .whitespacesAndNewlines)
        else { return nil }
        return root
    }

    /// The compound's own window (its timeframe + dates), when it has one.
    private var ownWindow: CounterPlacement.PickWindow? {
        guard let parent = (counterRootTasks + libraryTasks).first(where: { $0.id == parentId }),
              let timeframe = parent.timeframe else { return nil }
        return .init(timeframe: timeframe, startDate: parent.startDate, endDate: parent.endDate)
    }

    /// A picked counter primes the New sub row as Counting at its kind / noun.
    private func primeCounterSub(_ root: Task) {
        let kind = resolveCountKind(root.countKind)
        newSubCounting = true
        newSubKind = kind
        newSubUnit = countKindNeedsUnit(kind) ? (root.unit ?? "") : ""
        newSubGoal = CounterPlacement.counterPickGoal(.init(task: root), window: goalWindow ?? ownWindow)
            .map { formatCountForInput($0, kind: kind) } ?? ""
        newSubCounterId = root.id
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
                    // Seed clamped to the live child count (web
                    // `clampThreshold(2, subCount)`): a one-child compound
                    // shows "1 of 1", never a 2 that only persist would clamp.
                    if draft.threshold == nil {
                        draft.threshold = CompoundEvaluation.clampCompoundThreshold(2, childCount: draft.liveChildren.count)
                    }
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
                    // An existing sub-task edits at its OWN kind (no picker).
                    // Duration's h/m wheel gets its own full-width line.
                    if child.wrappedValue.countKind == .duration {
                        RisoTextField(placeholder: "e.g. Run", text: child.action).frame(maxWidth: .infinity)
                        GoalEntryView(kind: .duration, text: child.goal, placeholder: "0h 0m")
                    } else {
                        HStack(spacing: 6) {
                            RisoTextField(placeholder: "e.g. Run", text: child.action).frame(maxWidth: .infinity)
                            GoalEntryView(kind: child.wrappedValue.countKind, text: child.goal, placeholder: "5")
                                .frame(width: 76)
                            if countKindNeedsUnit(child.wrappedValue.countKind) {
                                RisoTextField(placeholder: "km", text: child.unit).frame(maxWidth: .infinity)
                            }
                        }
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

    /// Appends the typed sub-task per the chip, then resets the chip to
    /// Normal and clears the Counting config for the next one, like the
    /// create panel (the row clears its own text).
    private func appendTyped(_ text: String) {
        Self.appendTyped(
            text, isCounting: newSubCounting, goal: newSubGoal, unit: newSubUnit, kind: newSubKind,
            linkedRoot: pinnedRoot, to: &draft
        )
        newSubCounting = false
        newSubKind = .discrete
        newSubGoal = ""
        newSubUnit = ""
        newSubCounterId = nil
    }

    /// The wizard's own quick-add row, draft-only (`onSubmitText`): Return
    /// appends a new sub-task (no task is created until Save); a tapped match
    /// links that existing task. `userId` / `onTaskCreated` /
    /// `onLibraryReloadRequested` feed only the create path, which
    /// `onSubmitText` replaces. Below it: the "New sub:" type chips, the
    /// Counting config row + "Reads as" preview (Counting on) and the
    /// library load line.
    private var subtaskQuickAdd: some View {
        let sub = subCandidates
        return VStack(alignment: .leading, spacing: 8) {
            RisoQuickAddRowView(
                userId: "",
                defaultStartDate: nil,
                defaultEndDate: nil,
                onTaskCreated: { _, _, _ in },
                onPendingCreated: nil,
                onLibraryReloadRequested: {},
                libraryTasks: sub.candidates,
                counterRootTasks: counterRootTasks,
                onExistingTaskPicked: { task in
                    if sub.counterIds.contains(task.id) { primeCounterSub(task) } else { Self.appendPicked(task, to: &draft) }
                },
                textAfterPick: { sub.counterIds.contains($0.id) ? ($0.action ?? "") : nil },
                onSubmitText: { text in appendTyped(text) },
                submitTextEnabled: !newSubCounting
                    || Self.canAppendCounting(text: newSubText, goal: newSubGoal, unit: newSubUnit, kind: newSubKind),
                onTextChange: { newSubText = $0 },
                placeholderOverride: newSubCounting ? "Do" : nil,
                seedText: seedText
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

            if newSubCounting {
                VStack(alignment: .leading, spacing: 5) {
                    RisoCountingSubConfigRow(goal: $newSubGoal, unit: $newSubUnit, kind: $newSubKind)
                    if let preview = risoReadsAsPreview(action: newSubText, goal: newSubGoal, unit: newSubUnit, kind: newSubKind) {
                        Text(preview)
                            .font(.risoBody(10.5, .extraBold))
                            .foregroundStyle(Color.risoBlue)
                    }
                }
            }

            switch libraryInputsState {
            case .loading:
                Text("Loading your tasks…")
                    .font(.risoBody(11.5, .semibold))
                    .foregroundStyle(Color.risoMuted)
            case .failed:
                Text("Couldn't load your tasks.")
                    .font(.risoBody(11.5, .semibold))
                    .foregroundStyle(Color.risoRed)
                    .fixedSize(horizontal: false, vertical: true)
            case .loaded:
                EmptyView()
            }
        }
    }

    private func subtaskCountingPreview(_ child: ChildPatch) -> String? {
        risoReadsAsPreview(action: child.action, goal: child.goal, unit: child.unit, kind: child.countKind)
    }
}
