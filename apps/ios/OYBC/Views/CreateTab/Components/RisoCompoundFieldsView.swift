import SwiftUI

/// Inline compound-task authoring UI extracted from `RisoSpecialTaskPanel`.
///
/// This is the **single source of truth** for the compound builder — the
/// panel renders it directly rather than embedding a private `compoundFields`
/// computed property, so snapshot tests can target the real component.
///
/// ### Seedable init
/// Pass a `RisoCompoundFieldsView.Seed` to pre-populate `@State` fields
/// from outside (snapshot tests do this). Production callers pass no seed
/// and get the default empty state.
///
/// ### Submit flow
/// On "Add to board ✦" the view calls `form.handleCreateCompoundAndAddToPool`,
/// resets its own state, then calls `onSubmitted()` — the panel passes
/// `{ collapse() }` here.
struct RisoCompoundFieldsView: View {

    // MARK: - Seed (snapshot-only initialiser support)

    /// A value type that describes the initial `@State` for all compound
    /// fields. Snapshot tests construct a `Seed` matching each render variant
    /// so the real view body renders with the desired state on first layout.
    struct Seed {
        var title: String = ""
        var rule: CompoundRuleChoice = .allOf
        var threshold: Int = 2
        var subs: [CreateFormViewModel.CompoundSubItem] = []
        var subInputText: String = ""
        var newSubType: NewSubType = .normal
        var subGoalText: String = "5"
        var subUnitText: String = ""
    }

    // MARK: - Enums

    /// Completion rule options shown as pill chips in the compound builder.
    /// Maps to `CreateFormViewModel.CompoundRule` for the VM call.
    enum CompoundRuleChoice: String, CaseIterable {
        case allOf    = "All of"
        case anyOf    = "Any of"
        case atLeastN = "At least N"
        case inOrder  = "In order"

        /// Converts to the VM-layer rule (threshold is only used for `.atLeastN`).
        func toVMRule(threshold: Int) -> CreateFormViewModel.CompoundRule {
            switch self {
            case .allOf:    return .allOf
            case .anyOf:    return .anyOf
            case .atLeastN: return .atLeastN(threshold: threshold)
            case .inOrder:  return .inOrder
            }
        }
    }

    /// Sub-task type selector — Normal or Counting only (no nested compounds).
    enum NewSubType { case normal, counting }

    // MARK: - External dependencies

    /// The effective merged task library (live + pending) for smart autocomplete.
    /// Compound tasks are excluded from matches per spec.
    let taskLibrary: [OYBC.Task]

    let userId: String
    /// Optional timeframe — nil produces an indefinite task (Tasks-tab usage).
    /// Wizard callers pass a real `Timeframe` value; the optional param is
    /// backward-compatible with existing call sites.
    let defaultTimeframe: Timeframe?
    let defaultStartDate: String?
    let defaultEndDate: String?

    /// Called when a compound task is successfully saved (taskId, title, type).
    let onTaskCreated: (_ taskId: String, _ title: String, _ type: String) -> Void
    /// Non-nil when the caller uses deferred-persist mode (Bug #85 pattern).
    let onPendingCreated: ((_ payload: PendingTaskPayload) -> Void)?
    /// Triggers a library reload after a task is added to the pool.
    let onLibraryReloadRequested: () -> Void
    /// Called after a successful submit so the parent can collapse/reset.
    let onSubmitted: () -> Void

    // MARK: - Compound @State (all seedable from init)

    @State private var compoundTitle: String
    @State private var compoundRule: CompoundRuleChoice
    @State private var compoundThreshold: Int
    @State private var compoundSubs: [CreateFormViewModel.CompoundSubItem]
    @State private var subInputText: String
    @State private var newSubType: NewSubType
    @State private var subGoalText: String
    @State private var subUnitText: String

    /// Controls visibility of the smart-autocomplete dropdown below the sub input.
    @State private var subAutocompleteVisible: Bool = false

    /// Owned form VM — reset on each successful submit.
    @State private var form = CreateFormViewModel()

    // MARK: - Init (production)

    /// Production initialiser — all compound fields start at their defaults.
    ///
    /// - Parameters:
    ///   - defaultTimeframe: Optional board-window timeframe. Pass a real
    ///     `Timeframe` from the wizard; pass `nil` for indefinite Tasks-tab tasks.
    init(
        taskLibrary: [OYBC.Task],
        userId: String,
        defaultTimeframe: Timeframe? = nil,
        defaultStartDate: String? = nil,
        defaultEndDate: String? = nil,
        onTaskCreated: @escaping (_ taskId: String, _ title: String, _ type: String) -> Void,
        onPendingCreated: ((_ payload: PendingTaskPayload) -> Void)? = nil,
        onLibraryReloadRequested: @escaping () -> Void,
        onSubmitted: @escaping () -> Void
    ) {
        self.taskLibrary = taskLibrary
        self.userId = userId
        self.defaultTimeframe = defaultTimeframe
        self.defaultStartDate = defaultStartDate
        self.defaultEndDate = defaultEndDate
        self.onTaskCreated = onTaskCreated
        self.onPendingCreated = onPendingCreated
        self.onLibraryReloadRequested = onLibraryReloadRequested
        self.onSubmitted = onSubmitted

        // Default empty state
        _compoundTitle    = State(initialValue: "")
        _compoundRule     = State(initialValue: .allOf)
        _compoundThreshold = State(initialValue: 2)
        _compoundSubs     = State(initialValue: [])
        _subInputText     = State(initialValue: "")
        _newSubType       = State(initialValue: .normal)
        _subGoalText      = State(initialValue: "5")
        _subUnitText      = State(initialValue: "")
    }

    /// Seeded initialiser — snapshot tests use this to render a specific
    /// render variant without needing to drive the UI interactively.
    init(
        seed: Seed,
        taskLibrary: [OYBC.Task],
        userId: String = "preview-user",
        defaultTimeframe: Timeframe? = nil,
        defaultStartDate: String? = nil,
        defaultEndDate: String? = nil,
        onTaskCreated: @escaping (_ taskId: String, _ title: String, _ type: String) -> Void = { _, _, _ in },
        onPendingCreated: ((_ payload: PendingTaskPayload) -> Void)? = nil,
        onLibraryReloadRequested: @escaping () -> Void = {},
        onSubmitted: @escaping () -> Void = {}
    ) {
        self.taskLibrary = taskLibrary
        self.userId = userId
        self.defaultTimeframe = defaultTimeframe
        self.defaultStartDate = defaultStartDate
        self.defaultEndDate = defaultEndDate
        self.onTaskCreated = onTaskCreated
        self.onPendingCreated = onPendingCreated
        self.onLibraryReloadRequested = onLibraryReloadRequested
        self.onSubmitted = onSubmitted

        _compoundTitle    = State(initialValue: seed.title)
        _compoundRule     = State(initialValue: seed.rule)
        _compoundThreshold = State(initialValue: seed.threshold)
        _compoundSubs     = State(initialValue: seed.subs)
        _subInputText     = State(initialValue: seed.subInputText)
        _newSubType       = State(initialValue: seed.newSubType)
        _subGoalText      = State(initialValue: seed.subGoalText)
        _subUnitText      = State(initialValue: seed.subUnitText)
    }

    // MARK: - Derived properties

    /// Live preview title for a new counting sub: "Run 5 km".
    private var subCountingPreview: String {
        let a = subInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let g = Int(subGoalText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
        let u = subUnitText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? "reps"
            : subUnitText.trimmingCharacters(in: .whitespacesAndNewlines)
        return "\(a.isEmpty ? "Run" : a) \(g) \(u)"
    }

    /// Gates the "Add to board ✦" button — title must be non-empty and at
    /// least 2 sub-tasks must be present.
    private var canSubmitCompound: Bool {
        !compoundTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        compoundSubs.count >= 2
    }

    /// Autocomplete matches — up to 3 non-compound library tasks whose title
    /// contains the current `subInputText` (case-insensitive), excluding tasks
    /// already added as subs.
    private var subAutocompleteMatches: [OYBC.Task] {
        let q = subInputText.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !q.isEmpty else { return [] }
        let addedTitles = Set(compoundSubs.map { $0.displayTitle.lowercased() })
        return taskLibrary
            .filter { $0.type != .compound }
            .filter { !addedTitles.contains($0.title.lowercased()) }
            .filter { $0.title.lowercased().contains(q) }
            .prefix(3)
            .map { $0 }
    }

    /// The effective threshold for "At least N" (clamped to valid range).
    private var effectiveThreshold: Int {
        let maxN = Swift.max(2, compoundSubs.count)
        return Swift.min(Swift.max(1, compoundThreshold), maxN)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {

            // Title field
            fieldRow(label: "Title") {
                risoTextInput(placeholder: "Morning routine", text: $compoundTitle)
            }

            // "Counts as done when…" label + rule chips
            VStack(alignment: .leading, spacing: 5) {
                fieldLabel("Counts as done when…")
                compoundRuleChipsRow
            }

            // "How many?" stepper — only when rule is At least N
            if compoundRule == .atLeastN {
                HStack(alignment: .center, spacing: 9) {
                    fieldLabel("How many?")
                    Spacer()
                    RisoInlineStepperView(
                        value: Binding(
                            get: { effectiveThreshold },
                            set: { compoundThreshold = Swift.min(Swift.max(1, $0), Swift.max(2, compoundSubs.count)) }
                        ),
                        min: 1,
                        max: Swift.max(2, compoundSubs.count)
                    )
                    Text("of \(compoundSubs.isEmpty ? "…" : "\(compoundSubs.count)") sub-tasks")
                        .font(.risoBody(11, .semibold))
                        .foregroundStyle(Color.risoMuted)
                }
            }

            // "Sub-tasks" label + chips list
            VStack(alignment: .leading, spacing: 5) {
                fieldLabel("Sub-tasks")
                if !compoundSubs.isEmpty {
                    compoundSubChips
                }
            }

            // Sub-add input row + Add button
            HStack(spacing: 8) {
                TextField(
                    newSubType == .counting ? "Action — e.g. Run" : "Add a sub-task…",
                    text: $subInputText
                )
                .font(.risoHead(14, .bold))
                .foregroundStyle(Color.risoInk)
                .tint(Color.risoBlue)
                .padding(.horizontal, 11)
                .padding(.vertical, 10)
                .background(Color.risoPaper)
                .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Riso.cardRadius)
                        .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
                )
                .onChange(of: subInputText) { _, _ in
                    subAutocompleteVisible = !subInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                }
                .onSubmit { addNewSub() }

                Button("Add") {
                    addNewSub()
                }
                .font(.risoHead(13, .bold))
                .foregroundStyle(Color.risoPaper)
                .padding(.vertical, 10)
                .padding(.horizontal, 14)
                .background(
                    RoundedRectangle(cornerRadius: Riso.cardRadius)
                        .fill(subInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                            ? Color.risoMuted
                            : Color.risoGreen)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Riso.cardRadius)
                        .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
                )
                .buttonStyle(.plain)
                .disabled(subInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            }

            // Smart autocomplete dropdown
            if subAutocompleteVisible && !subAutocompleteMatches.isEmpty {
                subAutocompleteDropdown
            }

            // "New sub:" Normal / Counting type chips
            HStack(spacing: 8) {
                Text("New sub:")
                    .font(.risoBody(12, .semibold))
                    .foregroundStyle(Color.risoMuted)
                // Selected Normal chip uses risoRed fill — risoRaper-on-paper is invisible.
                subTypeChip("Normal", isOn: newSubType == .normal, fill: Color.risoRed) {
                    newSubType = .normal
                }
                subTypeChip("Counting", isOn: newSubType == .counting, fill: Color.risoBlue) {
                    newSubType = .counting
                }
            }

            // Counting sub config row: Goal + Unit + live preview
            if newSubType == .counting {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 8) {
                        Text("Goal")
                            .font(.risoBody(11, .semibold))
                            .foregroundStyle(Color.risoMuted)
                        risoNumberInput(placeholder: "5", text: $subGoalText)
                            .frame(width: 60)
                        risoTextInput(placeholder: "reps", text: $subUnitText)
                    }
                    (Text("reads as ")
                        .font(.risoBody(11, .semibold))
                        .foregroundStyle(Color.risoMuted)
                    + Text(subCountingPreview)
                        .font(.risoBody(11, .extraBold))
                        .foregroundStyle(Color.risoInk))
                }
            }

            // "Add at least 2 sub-tasks." warning
            if compoundSubs.count < 2 {
                Text("Add at least 2 sub-tasks.")
                    .font(.risoBody(11, .semibold))
                    .foregroundStyle(Color.risoRed)
            }

            // Add to board button — green fill matches compound type color
            RisoButton(title: "Add to board ✦", kind: .green, fullWidth: true) {
                submitCompound()
            }
            .opacity(canSubmitCompound ? 1 : 0.45)
            .allowsHitTesting(canSubmitCompound)
        }
    }

    // MARK: - Rule chips row

    /// Pill chips row for the compound completion rule.
    private var compoundRuleChipsRow: some View {
        HStack(spacing: 6) {
            ForEach(CompoundRuleChoice.allCases, id: \.rawValue) { choice in
                compoundRuleChip(choice)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }

    private func compoundRuleChip(_ choice: CompoundRuleChoice) -> some View {
        let isOn = compoundRule == choice
        return Button {
            compoundRule = choice
        } label: {
            Text(choice.rawValue)
                .font(.risoHead(11, .bold))
                .foregroundStyle(isOn ? Color.risoPaper : Color.risoInk)
                .padding(.vertical, 5)
                .padding(.horizontal, 9)
                .background(Capsule().fill(isOn ? Color.risoGreen : Color.risoPaper))
                .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sub chips

    /// Rendered list of added sub-task chips. Ordered rule shows "1." prefix;
    /// counting subs show a small blue type-dot; compound subs show a green dot.
    private var compoundSubChips: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(compoundSubs.enumerated()), id: \.offset) { index, sub in
                HStack(spacing: 5) {
                    // Ordered index prefix
                    if compoundRule == .inOrder {
                        Text("\(index + 1).")
                            .font(.risoHead(11, .extraBold))
                            .foregroundStyle(Color.risoInk)
                    }
                    // Type dot for non-normal tasks
                    if sub.taskType == .counting {
                        Circle()
                            .fill(Color.risoBlue)
                            .frame(width: 6, height: 6)
                    } else if sub.taskType == .compound {
                        Circle()
                            .fill(Color.risoGreen)
                            .frame(width: 6, height: 6)
                    }
                    Text(sub.displayTitle)
                        .font(.risoHead(12, .bold))
                        .foregroundStyle(Color.risoInk)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    // Remove button
                    Button {
                        compoundSubs.remove(at: index)
                        // Clamp threshold when sub count drops below it
                        if compoundRule == .atLeastN {
                            compoundThreshold = Swift.min(compoundThreshold, Swift.max(1, compoundSubs.count))
                        }
                    } label: {
                        Image(systemName: "xmark")
                            .font(.system(size: 10, weight: .bold))
                            .foregroundStyle(Color.risoMuted)
                    }
                    .buttonStyle(.plain)
                }
                .padding(.vertical, 5)
                .padding(.horizontal, 9)
                .background(
                    Capsule()
                        .fill(Color.risoPaper)
                        .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
                )
            }
        }
    }

    // MARK: - Autocomplete dropdown

    /// Smart autocomplete results dropdown. Each row shows ↩︎ · title ·
    /// [goal unit if counting] · "reuse" badge.
    private var subAutocompleteDropdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(subAutocompleteMatches) { task in
                Button {
                    // Add as EXISTING sub and clear input
                    let sub = CreateFormViewModel.CompoundSubItem.existing(
                        taskId: task.id,
                        title: task.title,
                        type: task.type
                    )
                    compoundSubs.append(sub)
                    subInputText = ""
                    subAutocompleteVisible = false
                } label: {
                    HStack(spacing: 6) {
                        Text("↩︎")
                            .font(.risoBody(12, .semibold))
                            .foregroundStyle(Color.risoMuted)
                        Text(task.title)
                            .font(.risoHead(13, .bold))
                            .foregroundStyle(Color.risoInk)
                            .lineLimit(1)
                        if task.type == .counting, let max = task.maxCount, let unit = task.unit {
                            Text("\(max) \(unit)")
                                .font(.risoBody(11, .semibold))
                                .foregroundStyle(Color.risoMuted)
                        }
                        Spacer(minLength: 0)
                        Text("reuse")
                            .font(.risoBody(11, .semibold))
                            .foregroundStyle(Color.risoGreen)
                    }
                    .padding(.vertical, 8)
                    .padding(.horizontal, 11)
                }
                .buttonStyle(.plain)

                if task.id != subAutocompleteMatches.last?.id {
                    Divider()
                        .overlay(Color.risoInk.opacity(0.12))
                }
            }
        }
        .background(Color.risoPaper)
        .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
        )
    }

    // MARK: - Sub type chip

    /// A small pill chip for the "New sub:" type selector.
    ///
    /// - Parameters:
    ///   - label: Display label.
    ///   - isOn: Whether this chip is currently selected.
    ///   - fill: Background color when selected (red for Normal, blue for Counting).
    ///   - action: Selection callback.
    private func subTypeChip(_ label: String, isOn: Bool, fill: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.risoHead(11, .bold))
                .foregroundStyle(isOn ? Color.risoPaper : Color.risoInk)
                .padding(.vertical, 4)
                .padding(.horizontal, 9)
                .background(Capsule().fill(isOn ? fill : Color.risoPaper))
                .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
        }
        .buttonStyle(.plain)
    }

    // MARK: - Sub-add action

    /// Adds the current sub-input as a new sub (new Normal or new Counting).
    /// Called on "Add" button tap or when the TextField submits (`.onSubmit`).
    private func addNewSub() {
        let text = subInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { return }

        let sub: CreateFormViewModel.CompoundSubItem
        switch newSubType {
        case .normal:
            sub = .newNormal(title: text)
        case .counting:
            let goal = Int(subGoalText.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 1
            let unit = subUnitText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? "reps"
                : subUnitText.trimmingCharacters(in: .whitespacesAndNewlines)
            sub = .newCounting(action: text, goal: goal, unit: unit)
        }

        compoundSubs.append(sub)
        subInputText = ""
        subAutocompleteVisible = false
        // Reset counting sub fields after each add
        subGoalText = "5"
        subUnitText = ""
        newSubType = .normal
    }

    // MARK: - Submit

    /// Fires `form.handleCreateCompoundAndAddToPool`, resets all field state,
    /// and calls `onSubmitted()` (which collapses the parent panel).
    private func submitCompound() {
        guard canSubmitCompound else { return }
        let rule = compoundRule.toVMRule(threshold: effectiveThreshold)
        form.handleCreateCompoundAndAddToPool(
            userId: userId,
            title: compoundTitle.trimmingCharacters(in: .whitespacesAndNewlines),
            rule: rule,
            subs: compoundSubs,
            onTaskCreated: { taskId, title, type in
                onTaskCreated(taskId, title, type)
            },
            onLibraryReloadRequested: onLibraryReloadRequested,
            defaultTimeframe: defaultTimeframe,
            defaultStartDate: defaultStartDate,
            defaultEndDate: defaultEndDate,
            deferPersist: onPendingCreated != nil,
            onPendingCreated: onPendingCreated
        )
        // NOTE: deliberately do NOT replace `form` here. The immediate-persist
        // path dispatches a background write that captures `[weak self]` on this
        // `form` instance and fires onTaskCreated/onLibraryReloadRequested in its
        // completion. Replacing `form` would drop that instance mid-flight and the
        // callbacks would never run (the deferred wizard path is synchronous, so it
        // was unaffected, but the non-deferred new-task-sheet caller would be).
        // `form` carries no field state we read — all inputs are passed as args and
        // its transient flags are reset at the top of each create call — so reuse is
        // safe. Only the view's own field state needs clearing.
        resetState()
        onSubmitted()
    }

    // MARK: - State reset

    /// Resets all compound fields to defaults. Called after a successful
    /// submit and by the parent panel's `collapse()`.
    func resetState() {
        compoundTitle     = ""
        compoundRule      = .allOf
        compoundThreshold = 2
        compoundSubs      = []
        subInputText      = ""
        newSubType        = .normal
        subGoalText       = "5"
        subUnitText       = ""
        subAutocompleteVisible = false
    }

    // MARK: - Field helpers

    @ViewBuilder
    private func fieldRow<Content: View>(label: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            fieldLabel(label)
            content()
        }
    }

    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .risoSectionLabel()
    }

    private func risoTextInput(placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .font(.risoHead(14, .bold))
            .foregroundStyle(Color.risoInk)
            .tint(Color.risoBlue)
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(Color.risoPaper)
            .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
            )
    }

    private func risoNumberInput(placeholder: String, text: Binding<String>) -> some View {
        TextField(placeholder, text: text)
            .font(.risoHead(14, .bold))
            .foregroundStyle(Color.risoInk)
            .tint(Color.risoBlue)
            .keyboardType(.numberPad)
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(Color.risoPaper)
            .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
            )
    }
}
