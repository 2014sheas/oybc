import SwiftUI

/// Special-type creation panel for the Riso wizard Tasks step.
///
/// Collapsed state: dashed button "＋ Add a counting, compound or achievement task"
/// Expanded state: type chips (Counting / Compound / Achievement) + type-specific fields.
///
/// Counting: Action / Goal / Unit + live "reads as **Run 5 km**" preview.
/// Compound: INLINE builder — Title · rule chips · sub-task add row with smart
///   autocomplete from `taskLibrary` · sub chips · "New sub: Normal/Counting" type
///   selector · Add-to-board button. No sheet — all inline, matching the prototype.
/// Achievement: Watch (Board / Template) + target picker + trigger chips + count.
///
/// All creation fires through `CreateFormViewModel` pipelines (deferred-persist
/// when `onPendingCreated` is non-nil) so Bug #85 is preserved identically.
///
/// `taskLibrary` is the effective merged task list from `BoardWizardTasksStepView`
/// (live + pending), needed for compound smart autocomplete. Exclude compounds
/// from autocomplete results per proto spec.
struct RisoSpecialTaskPanel: View {

    let userId: String
    /// Optional timeframe — nil produces an indefinite task (Tasks-tab usage).
    /// Wizard callers pass a real `Timeframe` value; the optional param is
    /// backward-compatible with existing call sites.
    var defaultTimeframe: Timeframe? = nil
    let defaultStartDate: String?
    let defaultEndDate: String?
    /// Effective task library (live + pending) for compound sub autocomplete.
    /// This is browsable-FILTERED at wizard call sites (draft-born tasks are
    /// excluded) — compound-child pickers must stay filtered like this.
    var taskLibrary: [OYBC.Task] = []
    /// Separate, UNFILTERED pool used only for the counter-link suggestion
    /// (`updateLinkSuggestion`). Goal-less hub-born counters are excluded
    /// from the browsable set, so the wizard's suggestion would never fire
    /// against them if it reused `taskLibrary`. Defaults to `nil`, which
    /// falls back to `taskLibrary` — so the Tasks-tab call site (which
    /// already passes the full, unfiltered library as `taskLibrary`) is
    /// unaffected.
    var suggestionPool: [OYBC.Task]? = nil
    let onTaskCreated: (_ taskId: String, _ title: String, _ type: String) -> Void
    let onCompositeCreated: (OYBC.Task) -> Void
    let onPendingCreated: ((_ payload: PendingTaskPayload) -> Void)?
    let onLibraryReloadRequested: () -> Void

    @State private var isExpanded: Bool = false
    @State private var selectedType: SpecialType = .counting
    @State private var form = CreateFormViewModel()

    // Achievement board/template pickers
    @State private var boards: [Board] = []
    @State private var templates: [RecurringBoardTemplate] = []
    @State private var isLoadingAchievementData: Bool = false

    enum SpecialType: String, CaseIterable {
        case counting = "Counting"
        case compound = "Compound"
        case achievement = "Achievement"

        var risoKind: RisoTaskKind {
            switch self {
            case .counting: return .counting
            case .compound: return .compound
            case .achievement: return .achievement
            }
        }
    }

    // MARK: - Body

    var body: some View {
        if !isExpanded {
            collapsedButton
        } else {
            expandedPanel
        }
    }

    // MARK: - Collapsed button

    private var collapsedButton: some View {
        Button {
            isExpanded = true
        } label: {
            HStack(spacing: 8) {
                Text("＋")
                    .font(.risoHead(15, .extraBold))
                    .foregroundStyle(Color.risoBlue)
                Text("Add a counting, compound or achievement task")
                    .font(.risoHead(13, .bold))
                    .foregroundStyle(Color.risoInk)
                    .multilineTextAlignment(.leading)
                Spacer(minLength: 0)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color.clear)
            .overlay(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .strokeBorder(style: StrokeStyle(lineWidth: Riso.Keyline.container, dash: [5, 4]))
                    .foregroundStyle(Color.risoInk)
            )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Expanded panel

    private var expandedPanel: some View {
        VStack(alignment: .leading, spacing: 11) {
            // Header row with "Special task" label + dismiss X
            HStack {
                Text("Special task")
                    .risoSectionLabel()
                Spacer()
                Button {
                    collapse()
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 13, weight: .bold))
                        .foregroundStyle(Color.risoMuted)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
            }

            // Type chips row
            HStack(spacing: 6) {
                ForEach(SpecialType.allCases, id: \.self) { type in
                    typeChip(type)
                }
            }

            // Fields for selected type
            switch selectedType {
            case .counting:
                countingFields
            case .compound:
                compoundFields
            case .achievement:
                achievementFields
            }
        }
        .padding(12)
        .risoCard(fill: .risoPaper2)
        .risoHardShadow(Riso.Shadow.small)
    }

    // MARK: - Type chip

    private func typeChip(_ type: SpecialType) -> some View {
        let isOn = selectedType == type
        let kind = type.risoKind
        return Button {
            selectedType = type
            if type == .achievement && boards.isEmpty && templates.isEmpty {
                loadAchievementData()
            }
        } label: {
            Text(type.rawValue)
                .font(.risoHead(12, .bold))
                .foregroundStyle(isOn ? Color.risoPaper : Color.risoInk)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 7)
                .background(
                    RoundedRectangle(cornerRadius: Riso.cardRadius)
                        .fill(isOn ? kind.fill : Color.risoPaper)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Riso.cardRadius)
                        .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
                )
        }
        .buttonStyle(.plain)
    }

    // MARK: - Counting fields

    @State private var countingActionText: String = ""
    @State private var countingGoalText: String = ""
    @State private var countingUnitText: String = ""

    // Counter-link suggestion state (R1 counters refresh — auto-link default
    // ON). Updated whenever the (verb, noun) pair changes.
    @State private var linkSuggestion: LinkableCounterSuggestion? = nil
    /// True when the user tapped "Don't link" to opt out of the (default-on)
    /// suggested link for this create. Reset to `false` whenever the typed
    /// (verb, noun) pair changes — an edited pair re-offers linking by
    /// default (web parity).
    @State private var linkDisabled: Bool = false

    /// R1: counting-fields title preview — "Title: {derived title}",
    /// matching web's `CountingStepFields` (Verb → Goal → Counting).
    private var countingTitle: String {
        let a = countingActionText.trimmingCharacters(in: .whitespacesAndNewlines)
        let g = countingGoalText.trimmingCharacters(in: .whitespacesAndNewlines)
        let u = countingUnitText.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !a.isEmpty, !u.isEmpty, let goal = Int(g), goal > 0 else { return "" }
        return TaskTitle.generateCounterTaskTitle(action: a, maxCount: goal, unit: u)
    }

    /// The typed goal as a positive Int, or nil when blank/invalid. Also
    /// gates the counter-link hint (only shown once a valid goal exists —
    /// mirrors web's `CounterLinkHint` doc contract).
    private var countingGoal: Int? {
        guard let g = Int(countingGoalText.trimmingCharacters(in: .whitespacesAndNewlines)), g > 0 else { return nil }
        return g
    }

    private var canSubmitCounting: Bool {
        !countingActionText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        !countingUnitText.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty &&
        countingGoal != nil
    }

    private var countingFields: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Verb
            fieldRow(label: "Verb", required: true) {
                RisoTextField(placeholder: "Do", text: $countingActionText)
            }

            // Goal + Counting (side by side)
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel("Goal", required: true)
                    RisoNumberField(placeholder: "100", text: $countingGoalText)
                }
                VStack(alignment: .leading, spacing: 5) {
                    fieldLabel("Counting", required: true)
                    RisoTextField(placeholder: "push-ups", text: $countingUnitText)
                }
            }

            // Live title preview — "Title: {derived title}" (web parity).
            if !countingTitle.isEmpty {
                (Text("Title: ")
                    .font(.risoBody(11, .semibold))
                    .foregroundStyle(Color.risoMuted)
                + Text(countingTitle)
                    .font(.risoBody(11, .extraBold))
                    .foregroundStyle(Color.risoInk))
            }

            // Counter-link hint (only when a match exists AND a valid goal
            // is entered — R1: auto-link default ON, "Don't link" opts out).
            counterLinkBanner

            // Add button
            RisoButton(title: "Add to board ✦", kind: .blue, fullWidth: true) {
                submitCounting()
            }
            .opacity(canSubmitCounting ? 1 : 0.45)
            .allowsHitTesting(canSubmitCounting)
        }
        .onChange(of: countingActionText) { _, _ in updateLinkSuggestion() }
        .onChange(of: countingUnitText) { _, _ in updateLinkSuggestion() }
    }

    // MARK: Counter-link suggestion banner

    /// Recomputes the link suggestion whenever the (verb, noun) pair
    /// changes. Resets the opt-out flag so an edited pair re-offers linking
    /// by default (web parity).
    private func updateLinkSuggestion() {
        linkSuggestion = findLinkableCounter(
            action: countingActionText,
            unit: countingUnitText,
            tasks: suggestionPool ?? taskLibrary
        )
        linkDisabled = false
    }

    /// Hint shown in the counting create panel when an existing counter
    /// matches the typed (verb, noun) pair AND a valid goal is entered. R1
    /// counters refresh: linking is ON by default (no fuzzy matching, no
    /// confirm step) — the hint explains what will happen; the "Don't link"
    /// pill opts out for this create (tapping again re-enables). Baseline is
    /// always "start fresh" (`suggestion.lifetime`) — the manual baseline
    /// picker was retired.
    @ViewBuilder
    private var counterLinkBanner: some View {
        if let suggestion = linkSuggestion, let goal = countingGoal {
            RisoCounterLinkHintView(
                counterName: suggestion.name,
                lifetime: suggestion.lifetime,
                goal: goal,
                linked: !linkDisabled,
                onToggle: { linkDisabled.toggle() }
            )
        }
    }

    private func submitCounting() {
        guard canSubmitCounting else { return }
        form.taskType = .counting
        form.countingAction = countingActionText.trimmingCharacters(in: .whitespacesAndNewlines)
        form.countingUnit = countingUnitText.trimmingCharacters(in: .whitespacesAndNewlines)
        form.countingMaxCount = countingGoalText.trimmingCharacters(in: .whitespacesAndNewlines)
        form.title = ""

        // R1: auto-link default ON — apply the suggestion unless opted out
        // via "Don't link". Baseline is always "start fresh": this task's
        // displayed count starts at 0 while the source's all-time keeps
        // climbing.
        if let suggestion = linkSuggestion, !linkDisabled, countingGoal != nil {
            form.countingSharedCounterId = suggestion.counterId
            form.countingBaseline = suggestion.lifetime
        } else {
            form.countingSharedCounterId = nil
            form.countingBaseline = nil
        }

        form.handleCreateAndAddToPool(
            userId: userId,
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
        countingActionText = ""
        countingGoalText = ""
        countingUnitText = ""
        linkSuggestion = nil
        linkDisabled = false
        form = CreateFormViewModel()
        collapse()
    }

    // MARK: - Compound fields

    /// The compound builder is fully owned by `RisoCompoundFieldsView` —
    /// the panel just forwards its dependencies and a collapse callback.
    private var compoundFields: some View {
        RisoCompoundFieldsView(
            taskLibrary: taskLibrary,
            suggestionPool: suggestionPool,
            userId: userId,
            defaultTimeframe: defaultTimeframe,
            defaultStartDate: defaultStartDate,
            defaultEndDate: defaultEndDate,
            onTaskCreated: onTaskCreated,
            onPendingCreated: onPendingCreated,
            onLibraryReloadRequested: onLibraryReloadRequested,
            onSubmitted: { collapse() }
        )
    }

    // MARK: - Achievement fields

    @State private var achievementTitle: String = ""
    @State private var achievementMode: AchievementMode = .specificBoard
    @State private var achievementBoardId: String? = nil
    @State private var achievementTemplateId: String? = nil
    @State private var achievementTrigger: AchievementTrigger = .greenlog
    @State private var achievementRequiredCount: Int = 3

    private var canSubmitAchievement: Bool {
        let titleOk = !achievementTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
        let refOk: Bool
        switch achievementMode {
        case .specificBoard: refOk = achievementBoardId != nil
        case .recurringTemplate: refOk = achievementTemplateId != nil && achievementRequiredCount > 0
        }
        return titleOk && refOk
    }

    private var achievementFields: some View {
        VStack(alignment: .leading, spacing: 9) {
            // Title
            fieldRow(label: "Title") {
                RisoTextField(placeholder: "Finish the reading challenge", text: $achievementTitle)
            }

            // Watch a…
            VStack(alignment: .leading, spacing: 5) {
                fieldLabel("Watch a…")
                HStack(spacing: 6) {
                    ruleChip("Specific board", isOn: achievementMode == .specificBoard) {
                        achievementMode = .specificBoard
                    }
                    ruleChip("Recurring template", isOn: achievementMode == .recurringTemplate) {
                        achievementMode = .recurringTemplate
                    }
                }
            }

            // Target picker
            VStack(alignment: .leading, spacing: 5) {
                fieldLabel(achievementMode == .specificBoard ? "Which board" : "Which template")
                if isLoadingAchievementData {
                    ProgressView()
                        .frame(maxWidth: .infinity, alignment: .leading)
                } else {
                    targetPicker
                }
            }

            // Completes on
            VStack(alignment: .leading, spacing: 5) {
                fieldLabel("Completes on")
                HStack(spacing: 6) {
                    ruleChip("GREENLOG", isOn: achievementTrigger == .greenlog) {
                        achievementTrigger = .greenlog
                    }
                    ruleChip("First Bingo", isOn: achievementTrigger == .bingo) {
                        achievementTrigger = .bingo
                    }
                }
            }

            // Required count (template mode only)
            if achievementMode == .recurringTemplate {
                HStack(alignment: .center, spacing: 9) {
                    fieldLabel("How many times?")
                    Spacer()
                    RisoInlineStepperView(value: $achievementRequiredCount, min: 1, max: 99)
                    Text("spawns must hit it")
                        .font(.risoBody(11, .semibold))
                        .foregroundStyle(Color.risoMuted)
                }
            }

            RisoButton(title: "Add to board ✦", kind: .blue, fullWidth: true) {
                submitAchievement()
            }
            .opacity(canSubmitAchievement ? 1 : 0.45)
            .allowsHitTesting(canSubmitAchievement)
        }
    }

    @ViewBuilder
    private var targetPicker: some View {
        switch achievementMode {
        case .specificBoard:
            if boards.isEmpty {
                Text("No boards found.")
                    .font(.risoBody(12, .semibold))
                    .foregroundStyle(Color.risoMuted)
            } else {
                risoTargetMenu(
                    title: boards.first(where: { $0.id == achievementBoardId })?.name ?? "Pick a board…",
                    items: boards.map { ($0.id, $0.name) },
                    selectedId: $achievementBoardId
                )
            }
        case .recurringTemplate:
            if templates.isEmpty {
                Text("No recurring templates found.")
                    .font(.risoBody(12, .semibold))
                    .foregroundStyle(Color.risoMuted)
            } else {
                risoTargetMenu(
                    title: templates.first(where: { $0.id == achievementTemplateId })?.name ?? "Pick a template…",
                    items: templates.map { ($0.id, $0.name) },
                    selectedId: $achievementTemplateId
                )
            }
        }
    }

    private func risoTargetMenu(title: String, items: [(String, String)], selectedId: Binding<String?>) -> some View {
        Menu {
            ForEach(items, id: \.0) { id, name in
                Button(name) { selectedId.wrappedValue = id }
            }
        } label: {
            HStack {
                Text(title)
                    .font(.risoHead(14, .bold))
                    .foregroundStyle(Color.risoInk)
                    .lineLimit(1)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.risoMuted)
            }
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

    private func submitAchievement() {
        guard canSubmitAchievement else { return }
        form.taskType = .achievement
        form.title = achievementTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        form.achievementMode = achievementMode
        form.achievementTrigger = achievementTrigger
        switch achievementMode {
        case .specificBoard:
            form.achievementReferenceId = achievementBoardId
        case .recurringTemplate:
            form.achievementReferenceId = achievementTemplateId
            form.achievementRequiredCountStr = "\(achievementRequiredCount)"
        }

        form.handleCreateAndAddToPool(
            userId: userId,
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
        achievementTitle = ""
        achievementBoardId = nil
        achievementTemplateId = nil
        form = CreateFormViewModel()
        collapse()
    }

    // MARK: - Achievement data load

    private func loadAchievementData() {
        guard !isLoadingAchievementData else { return }
        isLoadingAchievementData = true
        let uid = userId
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let b = try AppDatabase.shared.fetchBoards(userId: uid)
                let t = try AppDatabase.shared.fetchRecurringBoardTemplates(userId: uid)
                DispatchQueue.main.async {
                    self.boards = b.filter { !$0.isDeleted }
                    self.templates = t.filter { !$0.isDeleted && $0.isActive }
                    self.isLoadingAchievementData = false
                }
            } catch {
                DispatchQueue.main.async { self.isLoadingAchievementData = false }
            }
        }
    }

    // MARK: - Helpers

    /// Collapses the panel and resets all field state so the next
    /// expansion starts fresh. Mirrors `ComposerA`'s reset pattern.
    ///
    /// Compound fields are owned by `RisoCompoundFieldsView` — its state
    /// is scoped to its view lifetime, so no explicit reset is needed here.
    private func collapse() {
        isExpanded = false
        // Counting
        countingActionText = ""
        countingGoalText = ""
        countingUnitText = ""
        // Counter-link suggestion
        linkSuggestion = nil
        linkDisabled = false
        // Achievement
        achievementTitle = ""
        achievementBoardId = nil
        achievementTemplateId = nil
        form = CreateFormViewModel()
    }

    @ViewBuilder
    private func fieldRow<Content: View>(label: String, required: Bool = false, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            fieldLabel(label, required: required)
            content()
        }
    }

    /// - Parameter required: Appends a red "*" (matches
    ///   `RisoBoardSetupForm`'s required-field convention) — web's
    ///   `CountingStepFields` marks Verb/Goal/Counting required-starred.
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

    /// Pill rule chip for achievement fields (blue fill when on).
    private func ruleChip(_ label: String, isOn: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Text(label)
                .font(.risoHead(12, .bold))
                .foregroundStyle(isOn ? Color.risoPaper : Color.risoInk)
                .padding(.vertical, 6)
                .padding(.horizontal, 11)
                .background(
                    Capsule().fill(isOn ? Color.risoBlue : Color.risoPaper)
                )
                .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Inline stepper

/// Minimal inline stepper for the achievement required-count field and
/// the compound At-least-N threshold.
struct RisoInlineStepperView: View {
    @Binding var value: Int
    let min: Int
    let max: Int

    var body: some View {
        HStack(spacing: 0) {
            Button { value = Swift.max(min, value - 1) } label: {
                Text("−")
                    .font(.risoHead(18, .extraBold))
                    .foregroundStyle(Color.risoInk)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)

            Text("\(value)")
                .font(.risoHead(14, .extraBold))
                .foregroundStyle(Color.risoInk)
                .frame(minWidth: 30)
                .multilineTextAlignment(.center)
                .padding(.vertical, 2)
                .overlay(
                    HStack {
                        Rectangle()
                            .fill(Color.risoInk)
                            .frame(width: Riso.Keyline.container)
                        Spacer()
                        Rectangle()
                            .fill(Color.risoInk)
                            .frame(width: Riso.Keyline.container)
                    }
                )

            Button { value = Swift.min(max, value + 1) } label: {
                Text("＋")
                    .font(.risoHead(18, .extraBold))
                    .foregroundStyle(Color.risoInk)
                    .frame(width: 44, height: 44)
            }
            .buttonStyle(.plain)
        }
        .background(Color.risoPaper)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
    }
}
