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
        var subGoalText: String = ""
        var subUnitText: String = ""
        /// Pre-seeds the counter-link hint state directly, bypassing the
        /// `.onChange` recompute (which doesn't fire from a seeded initial
        /// value) — lets snapshot tests render `RisoCounterLinkHintView` in
        /// context without needing to simulate keystrokes.
        var subLinkSuggestion: LinkableCounterSuggestion? = nil
        var subLinkDisabled: Bool = false
    }

    // MARK: - Enums

    // `CompoundRuleChoice` (the "All of" / "Any of" / "At least N" rule
    // options) was promoted to a top-level type in `CompoundRuleChoice.swift`
    // so it — and the chips + threshold-stepper UI in `RisoCompoundRulePicker`
    // — can be shared verbatim with the inline pool-row editor
    // (`RisoPoolRowEditorView`).

    /// Sub-task type selector — Normal or Counting only (no nested compounds).
    enum NewSubType { case normal, counting }

    // MARK: - External dependencies

    /// The effective merged task library (live + pending) for smart autocomplete.
    /// Compound tasks are excluded from matches per spec.
    let taskLibrary: [OYBC.Task]
    /// Separate, UNFILTERED pool used only for the new-counting-sub
    /// counter-link suggestion (`updateSubLinkSuggestion`) — mirrors
    /// `RisoSpecialTaskPanel.suggestionPool`. Goal-less hub-born counters are
    /// excluded from the browsable `taskLibrary`, so matching against it
    /// would never surface a link suggestion for them. Defaults to `nil`,
    /// which falls back to `taskLibrary` so existing call sites (Tasks-tab,
    /// which already passes the full unfiltered library as `taskLibrary`)
    /// are unaffected. Autocomplete keeps using `taskLibrary` unconditionally.
    var suggestionPool: [OYBC.Task]? = nil

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

    // Counter-link suggestion state for the new-counting-sub fields (R1
    // counters refresh — auto-link default ON). Mirrors
    // `RisoSpecialTaskPanel`'s `linkSuggestion` / `linkDisabled` so inline
    // compound children are born linked exactly like standalone counting
    // tasks. `subInputText` doubles as the sub's verb when `newSubType ==
    // .counting`.
    @State private var subLinkSuggestion: LinkableCounterSuggestion? = nil
    @State private var subLinkDisabled: Bool = false

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
        suggestionPool: [OYBC.Task]? = nil,
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
        self.suggestionPool = suggestionPool
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
        _subGoalText      = State(initialValue: "")
        _subUnitText      = State(initialValue: "")
    }

    /// Seeded initialiser — snapshot tests use this to render a specific
    /// render variant without needing to drive the UI interactively.
    init(
        seed: Seed,
        taskLibrary: [OYBC.Task],
        suggestionPool: [OYBC.Task]? = nil,
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
        self.suggestionPool = suggestionPool
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
        _subLinkSuggestion = State(initialValue: seed.subLinkSuggestion)
        _subLinkDisabled  = State(initialValue: seed.subLinkDisabled)
    }

    // MARK: - Derived properties

    /// Live title preview for a new counting sub — "Title: {derived title}",
    /// matching `RisoSpecialTaskPanel.countingTitle` / web's
    /// `CountingStepFields` exactly. Empty (hidden) until verb + counting +
    /// a valid positive goal are all present — no placeholder-substituted
    /// fallback text.
    private var subCountingTitle: String {
        let a = subInputText.trimmingCharacters(in: .whitespacesAndNewlines)
        let g = subGoalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = subUnitText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !u.isEmpty, let goal = Int(g), goal > 0 else { return "" }
        return TaskTitle.generateCounterTaskTitle(action: a, maxCount: goal, unit: u)
    }

    /// The typed sub goal as a positive Int, or nil when blank/invalid.
    /// Gates `subCounterLinkBanner` — mirrors `RisoSpecialTaskPanel`'s
    /// `countingGoal` (the hint only shows once a valid goal exists).
    private var subCountingGoal: Int? {
        guard let g = Int(subGoalText.trimmingCharacters(in: .whitespacesAndNewlines)), g > 0 else { return nil }
        return g
    }

    /// Gates the sub "Add" button and `addNewSub()`. A Normal sub needs only
    /// its title; a Counting sub additionally needs a valid positive Goal and
    /// a non-blank Counting noun — mirroring `RisoSpecialTaskPanel`'s
    /// `canSubmitCounting` and web's `evaluateSubtaskReadiness`, so an
    /// untouched Goal (blank since R1 removed the "5" pre-fill) can never
    /// silently produce a `maxCount = 1` / "reps" child.
    private var canAddSub: Bool {
        guard !subInputText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return false }
        guard newSubType == .counting else { return true }
        return subCountingGoal != nil
            && !subUnitText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
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

    /// The effective threshold for "At least N", clamped to the valid stored
    /// range via the shared `clampCompoundThreshold` (used at persist, line
    /// ~610). "At least N" is only selectable at ≥2 sub-tasks, so this matches
    /// the old `max(2, …)` ceiling for every reachable state while staying
    /// byte-identical to web's stored value.
    private var effectiveThreshold: Int {
        CompoundEvaluation.clampCompoundThreshold(compoundThreshold, childCount: compoundSubs.count)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 9) {

            // Title field
            fieldRow(label: "Title") {
                RisoTextField(placeholder: "Morning routine", text: $compoundTitle)
            }

            // "Counts as done when…" label + the shared rule picker (chips +
            // conditional threshold stepper) — kept in lockstep with the
            // inline editor's compound fields via `RisoCompoundRulePicker`.
            VStack(alignment: .leading, spacing: 5) {
                fieldLabel("Counts as done when…")
                RisoCompoundRulePicker(
                    rule: $compoundRule,
                    threshold: $compoundThreshold,
                    subCount: compoundSubs.count
                )
            }

            // "Sub-tasks" label + chips list
            VStack(alignment: .leading, spacing: 5) {
                fieldLabel("Sub-tasks")
                if !compoundSubs.isEmpty {
                    compoundSubChips
                }
            }

            // "Verb" label — R1 vocabulary, only when adding a counting sub
            // (the same input doubles as the Normal sub's free-text title,
            // which has no fixed label).
            if newSubType == .counting {
                fieldLabel("Verb", required: true)
            }

            // Sub-add input row + Add button
            HStack(spacing: 8) {
                TextField(
                    newSubType == .counting ? "Do" : "Add a sub-task…",
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
                    updateSubLinkSuggestion()
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
                        .fill(canAddSub ? Color.risoGreen : Color.risoMuted)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Riso.cardRadius)
                        .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
                )
                .buttonStyle(.plain)
                .disabled(!canAddSub)
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
            .onChange(of: newSubType) { _, _ in updateSubLinkSuggestion() }

            // Counting sub config row: Goal + Counting + live preview
            // ("Title: {derived title}", matching RisoSpecialTaskPanel /
            // web's CountingStepFields exactly).
            if newSubType == .counting {
                VStack(alignment: .leading, spacing: 5) {
                    HStack(spacing: 10) {
                        VStack(alignment: .leading, spacing: 5) {
                            fieldLabel("Goal", required: true)
                            RisoNumberField(placeholder: "100", text: $subGoalText)
                                .frame(width: 70)
                        }
                        VStack(alignment: .leading, spacing: 5) {
                            fieldLabel("Counting", required: true)
                            RisoTextField(placeholder: "push-ups", text: $subUnitText)
                                .onChange(of: subUnitText) { _, _ in updateSubLinkSuggestion() }
                        }
                    }

                    if !subCountingTitle.isEmpty {
                        (Text("Title: ")
                            .font(.risoBody(11, .semibold))
                            .foregroundStyle(Color.risoMuted)
                        + Text(subCountingTitle)
                            .font(.risoBody(11, .extraBold))
                            .foregroundStyle(Color.risoInk))
                    }

                    // Counter-link hint (R1 — same auto-link-default-ON
                    // mechanism as RisoSpecialTaskPanel's standalone
                    // counting fields, only shown once a valid goal exists).
                    subCounterLinkBanner
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

    // MARK: - Sub chips

    /// Rendered list of added sub-task chips. Counting subs show a small
    /// blue type-dot; compound subs show a green dot.
    private var compoundSubChips: some View {
        VStack(alignment: .leading, spacing: 5) {
            ForEach(Array(compoundSubs.enumerated()), id: \.offset) { index, sub in
                HStack(spacing: 5) {
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
                            compoundThreshold = CompoundEvaluation.clampCompoundThreshold(compoundThreshold, childCount: compoundSubs.count)
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

    // MARK: - Counter-link hint (new counting sub)

    /// Hint shown below the new-counting-sub fields when an existing
    /// counter matches the typed (verb, noun) pair AND a valid goal is
    /// entered. R1 counters refresh: linking is ON by default; "Don't
    /// link" opts out for this sub (mirrors `RisoSpecialTaskPanel`'s
    /// `counterLinkBanner`, factored into the shared `RisoCounterLinkHintView`).
    @ViewBuilder
    private var subCounterLinkBanner: some View {
        if let suggestion = subLinkSuggestion, let goal = subCountingGoal {
            RisoCounterLinkHintView(
                counterName: suggestion.name,
                lifetime: suggestion.lifetime,
                goal: goal,
                linked: !subLinkDisabled,
                onToggle: { subLinkDisabled.toggle() }
            )
        }
    }

    /// Recomputes the sub's link suggestion whenever the typed (verb, noun)
    /// pair changes. Resets the opt-out flag so an edited pair re-offers
    /// linking by default (web parity).
    private func updateSubLinkSuggestion() {
        guard newSubType == .counting else {
            subLinkSuggestion = nil
            return
        }
        subLinkSuggestion = findLinkableCounter(
            action: subInputText,
            unit: subUnitText,
            tasks: suggestionPool ?? taskLibrary
        )
        subLinkDisabled = false
    }

    // MARK: - Sub-add action

    /// Adds the current sub-input as a new sub (new Normal or new Counting).
    /// Called on "Add" button tap or when the TextField submits (`.onSubmit`).
    private func addNewSub() {
        guard canAddSub else { return }
        let text = subInputText.trimmingCharacters(in: .whitespacesAndNewlines)

        let sub: CreateFormViewModel.CompoundSubItem
        switch newSubType {
        case .normal:
            sub = .newNormal(title: text)
        case .counting:
            // `canAddSub` guarantees a valid positive goal and non-blank unit
            // for a counting sub — no silent `?? 1` / "reps" fallbacks.
            guard let goal = subCountingGoal else { return }
            let unit = subUnitText.trimmingCharacters(in: .whitespacesAndNewlines)
            // R1: auto-link default ON — apply the suggestion unless opted
            // out via "Don't link". Baseline is always "start fresh".
            let linked = subLinkSuggestion != nil && !subLinkDisabled
            sub = .newCounting(
                action: text,
                goal: goal,
                unit: unit,
                sharedCounterId: linked ? subLinkSuggestion?.counterId : nil,
                baseline: linked ? subLinkSuggestion?.lifetime : nil
            )
        }

        compoundSubs.append(sub)
        subInputText = ""
        subAutocompleteVisible = false
        // Reset counting sub fields after each add
        subGoalText = ""
        subUnitText = ""
        newSubType = .normal
        subLinkSuggestion = nil
        subLinkDisabled = false
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
        subGoalText       = ""
        subUnitText       = ""
        subAutocompleteVisible = false
        subLinkSuggestion = nil
        subLinkDisabled   = false
    }

    // MARK: - Field helpers

    @ViewBuilder
    private func fieldRow<Content: View>(label: String, required: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            fieldLabel(label, required: required)
            content()
        }
    }

    /// - Parameter required: Appends a red "*" (matches
    ///   `RisoBoardSetupForm`'s / `RisoSpecialTaskPanel`'s required-field
    ///   convention) — web's `CountingStepFields` marks Verb/Goal/Counting
    ///   required-starred; the inline counting-sub fields here mirror that.
    private func fieldLabel(_ text: String, required: Bool = false) -> some View {
        HStack(spacing: 3) {
            Text(text)
                .risoSectionLabel()
            if required {
                Text("*")
                    .font(.risoBody(11, .bold))
                    .foregroundStyle(Color.risoRed)
            }
        }
    }

    // (risoTextInput / risoNumberInput removed — use the kit's
    // RisoTextField / RisoNumberField, which they duplicated verbatim.)
}
