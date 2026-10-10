import SwiftUI

/// Quick-add row for the Riso wizard Tasks step.
///
/// Text input + red "Add" button (full Riso keyline + hard-shadow).
/// Return key submits (no visible hint, per README §3 locked decisions).
/// Creates a Normal task via the existing deferred-persist creation path
/// (fires `onTaskCreated` + `onPendingCreated`) and auto-selects the
/// new task into the pool.
///
/// The row lives in the "ADD TASKS" card alongside the special-type button.
/// It owns a lightweight local `CreateFormViewModel` so it can reuse the
/// existing production validation + deferred-persist pipeline without
/// duplicating logic.
///
/// OPTIONAL library-poll (owner decision 2026-07-21): when a host also
/// supplies `libraryTasks` + `onExistingTaskPicked`, typing shows an inline
/// dropdown of up to 4 matching browsable library tasks — tapping one
/// reuses the EXISTING task instead of creating a duplicate. The Add
/// button/Enter path is unchanged (always creates a new Normal task).
/// Mirrors `RisoCompoundFieldsView`'s `subAutocompleteMatches` /
/// `subAutocompleteDropdown` pattern — same shape, different callback.
/// Hosts that don't pass the new inputs (default `[]`/nil) see exactly
/// today's create-only behavior — no dropdown ever renders.
struct RisoQuickAddRowView: View {

    let userId: String
    /// Optional timeframe — nil produces an indefinite task (Tasks-tab quick-add).
    /// Wizard callers pass a real `Timeframe` value; the optional param is
    /// backward-compatible with existing call sites.
    var defaultTimeframe: Timeframe? = nil
    let defaultStartDate: String?
    let defaultEndDate: String?
    let onTaskCreated: (_ taskId: String, _ title: String, _ type: String) -> Void
    let onPendingCreated: ((_ payload: PendingTaskPayload) -> Void)?
    let onLibraryReloadRequested: () -> Void

    /// The browsable candidate pool to poll while typing. Empty (default)
    /// disables polling entirely — see `libraryMatches`.
    var libraryTasks: [OYBC.Task] = []
    /// Ids to exclude from matches (already-selected/added tasks).
    var selectedIds: Set<String> = []
    /// Fired when the user taps a matched library row — the host appends
    /// the EXISTING task's id (reuse, no create). `nil` (default) disables
    /// polling entirely, matching today's create-only hosts.
    var onExistingTaskPicked: ((OYBC.Task) -> Void)? = nil
    /// Draft-only submit. When set, Return / Add hands the trimmed text to
    /// this closure (then clears the field) INSTEAD of creating a task — no
    /// `handleCreateAndAddToPool`, and `onTaskCreated` / `onPendingCreated`
    /// never fire. Used by the compound sub-task editor, which appends a
    /// draft sub-task written only when the edit is saved. `nil` (default)
    /// keeps every existing host's create path. Web twin:
    /// `WizardQuickAddRow.onSubmitText`.
    var onSubmitText: ((String) -> Void)? = nil
    /// Draft-only submit gate (default `true`). `false` dims Add and ignores
    /// Return (the text stays put) while the host's own inputs are
    /// incomplete — the compound editor's new Counting sub-task needs a goal
    /// and a unit beside the text. Web twin: `WizardQuickAddRow.canSubmitText`.
    var submitTextEnabled: Bool = true
    /// Mirrors every text change (typing, clears) to the host — a draft-only
    /// host previews / gates on the text. Web twin: `onTextChange`.
    var onTextChange: ((String) -> Void)? = nil
    /// Fixed placeholder instead of the rotating pool (the compound editor's
    /// Counting mode names the field the action: "Do").
    var placeholderOverride: String? = nil
    /// The board's timeframe for a counter match row's goal slot (what a placed
    /// copy would get). nil falls back to `defaultTimeframe`; both nil = no
    /// goal slot (the pool editor / core-defaults hosts). Kept separate from
    /// `defaultTimeframe` so a host (Board Edit's picker) can show the slot
    /// without changing the timeframe its created tasks carry.
    var placementTimeframe: Timeframe? = nil

    /// The user's live tasks — supplied only by an immediate-create host (the
    /// New task sheet), which shows the "Counts toward" row. nil hides it.
    var countsTowardTasks: [OYBC.Task]? = nil
    /// Counter Detail's "+ New" preset.
    var presetCountsTowardCounterId: String? = nil
    @State private var countsToward = CountsTowardSelection()

    @State private var text: String = ""
    @State private var form = CreateFormViewModel()
    @FocusState private var focused: Bool

    private let placeholders = [
        "e.g. Meditate 10 min",
        "e.g. Drink water",
        "e.g. Read 30 min",
        "e.g. Walk the dog",
        "e.g. Stretch",
    ]
    @State private var placeholderIndex: Int = 0

    private var placeholder: String { placeholderOverride ?? placeholders[placeholderIndex % placeholders.count] }
    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSubmit: Bool { !trimmedText.isEmpty && submitTextEnabled }

    /// Library-poll matches — up to 4 browsable tasks whose title contains
    /// the trimmed, lowercased input, excluding already-selected ids.
    /// Mirrors `RisoCompoundFieldsView.subAutocompleteMatches` (cap 4 here,
    /// not 3 — per the quick-add spec). Always empty when the host hasn't
    /// opted in (`onExistingTaskPicked == nil`), which keeps existing
    /// create-only call sites byte-identical to today.
    private var libraryMatches: [OYBC.Task] {
        guard onExistingTaskPicked != nil, !trimmedText.isEmpty else { return [] }
        // The shared match set (docs/SHARED_COUNTER_SETTINGS.md §2): title, plus a
        // counter's name / noun / verb / plural template; case- and diacritic-insensitive.
        return libraryTasks
            .filter { !selectedIds.contains($0.id) }
            .filter { CounterPlacement.taskSearchMatches(trimmedText, task: $0) }
            .prefix(4)
            .map { $0 }
    }

    /// Dropdown shows whenever matches exist — purely text-driven, mirroring
    /// `RisoCompoundFieldsView.subAutocompleteVisible`'s actual behavior
    /// (also text-driven, not focus-driven). This alone satisfies "hides
    /// when empty/on selection": both submit and a match tap clear `text`,
    /// which empties `libraryMatches` on the next render.
    private var showLibraryDropdown: Bool { !libraryMatches.isEmpty }

    // MARK: - Init

    /// Production initialiser — mirrors the field's implicit memberwise
    /// init (all existing call sites are unaffected).
    init(
        userId: String,
        defaultTimeframe: Timeframe? = nil,
        defaultStartDate: String?,
        defaultEndDate: String?,
        onTaskCreated: @escaping (_ taskId: String, _ title: String, _ type: String) -> Void,
        onPendingCreated: ((_ payload: PendingTaskPayload) -> Void)?,
        onLibraryReloadRequested: @escaping () -> Void,
        libraryTasks: [OYBC.Task] = [],
        selectedIds: Set<String> = [],
        onExistingTaskPicked: ((OYBC.Task) -> Void)? = nil,
        onSubmitText: ((String) -> Void)? = nil,
        submitTextEnabled: Bool = true,
        onTextChange: ((String) -> Void)? = nil,
        placeholderOverride: String? = nil,
        placementTimeframe: Timeframe? = nil,
        seedText: String = "",
        countsTowardTasks: [OYBC.Task]? = nil,
        presetCountsTowardCounterId: String? = nil
    ) {
        self.userId = userId
        self.defaultTimeframe = defaultTimeframe
        self.defaultStartDate = defaultStartDate
        self.defaultEndDate = defaultEndDate
        self.onTaskCreated = onTaskCreated
        self.onPendingCreated = onPendingCreated
        self.onLibraryReloadRequested = onLibraryReloadRequested
        self.libraryTasks = libraryTasks
        self.selectedIds = selectedIds
        self.onExistingTaskPicked = onExistingTaskPicked
        self.onSubmitText = onSubmitText
        self.submitTextEnabled = submitTextEnabled
        self.onTextChange = onTextChange
        self.placeholderOverride = placeholderOverride
        self.placementTimeframe = placementTimeframe
        _text = State(initialValue: seedText)
        self.countsTowardTasks = countsTowardTasks
        self.presetCountsTowardCounterId = presetCountsTowardCounterId
        _countsToward = State(initialValue: CountsTowardSelection(counterId: presetCountsTowardCounterId))
    }

    /// Whether the "Counts toward" row shows (an immediate Normal create with a counter to pick).
    private var showsCountsToward: Bool {
        onSubmitText == nil && CountsTowardFieldView.showsOnCreate(tasks: countsTowardTasks, deferred: onPendingCreated != nil)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(spacing: 8) {
                // Text field — keyline, paper fill, Bricolage font
                TextField(placeholder, text: $text)
                    .font(.risoHead(15, .bold))
                    .foregroundStyle(Color.risoInk)
                    .tint(Color.risoBlue)
                    .focused($focused)
                    .submitLabel(.done)
                    .onSubmit { submit() }
                    .onChange(of: text) { _, newValue in onTextChange?(newValue) }
                    .padding(.horizontal, 12)
                    .padding(.vertical, 11)
                    .background(Color.risoPaper)
                    .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Riso.cardRadius)
                            .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
                    )

                // Add button
                RisoButton(title: "Add", kind: .primary, action: submit)
                    .opacity(canSubmit ? 1 : 0.45)
                    .allowsHitTesting(canSubmit)
            }

            if showLibraryDropdown {
                libraryMatchesDropdown
                    .padding(.top, 8)
            }

            if showsCountsToward, let all = countsTowardTasks {
                CountsTowardFieldView(tasks: all, editedTaskId: nil, storedCounterId: nil, selection: $countsToward)
                    .padding(.top, 10)
                if let message = form.errorMessage {
                    Text(message)
                        .font(.risoBody(11.5, .extraBold))
                        .foregroundStyle(Color.risoRed)
                        .padding(.top, 6)
                }
            }
        }
    }

    // MARK: - Library-poll dropdown

    /// Inline matches dropdown — mirrors `RisoCompoundFieldsView.subAutocompleteDropdown`'s
    /// shape (keylined paper card, divider-separated rows) but with the pool
    /// sheet's row style (`RisoTypeBadge` + title + "+" affordance) per the
    /// quick-add spec.
    private var libraryMatchesDropdown: some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(libraryMatches) { task in
                QuickAddMatchRow(
                    task: task,
                    timeframe: placementTimeframe ?? defaultTimeframe,
                    canCreatePending: onPendingCreated != nil,
                    onPick: {
                        onExistingTaskPicked?(task)
                        text = ""
                    },
                    onPickWithGoal: { goal in
                        let payload = QuickAddCounterPlacement.pendingLinkedTask(
                            root: task, goal: goal, userId: userId, now: AppDatabase.currentTimestamp(),
                            timeframe: defaultTimeframe, startDate: defaultStartDate, endDate: defaultEndDate
                        )
                        onTaskCreated(payload.task.id, payload.task.title, TaskType.counting.rawValue)
                        onPendingCreated?(payload)
                        text = ""
                    }
                )

                if task.id != libraryMatches.last?.id {
                    Divider().overlay(Color.risoInk.opacity(0.12))
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

    // MARK: - Submit

    private func submit() {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard canSubmit else { return }

        // Draft-only host: hand over the text, reset exactly like a create.
        if let onSubmitText {
            onSubmitText(trimmed)
            text = ""
            placeholderIndex += 1
            focused = true
            return
        }

        // Configure the form for a Normal task
        form.taskType = .normal
        form.title = trimmed
        form.countsToward = showsCountsToward ? countsToward : CountsTowardSelection()

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

        // A synchronous counts-toward refusal keeps the text and shows its error line.
        if form.countsToward.counterId != nil, form.errorMessage != nil { return }

        // Reset immediately — the model's async path handles DB work
        text = ""
        countsToward = CountsTowardSelection(counterId: presetCountsTowardCounterId)
        form = CreateFormViewModel()
        placeholderIndex += 1
        focused = true
    }
}

// MARK: - Match row

/// One dropdown row. A plain task shows badge · title · plus. A shared counter
/// ROOT shows badge · counter name · a dense kind tag, and — in a board context
/// (`timeframe` set) — a goal slot: the goal a placed copy would get ("Weekly ·
/// 2 books", or the root's own "12 books"), or, for a goal-less root with no
/// default, an inline Goal entry that gates the plus (the row then places a
/// pending linked counting task at that goal). Web twin: `WizardQuickAddRow`'s
/// match row.
private struct QuickAddMatchRow: View {
    let task: OYBC.Task
    let timeframe: Timeframe?
    /// A host that can take a pending task (the wizard, Board Edit's picker).
    let canCreatePending: Bool
    /// Place the existing task (a plain row, or a root with a goal source).
    let onPick: () -> Void
    /// Place a pending linked task at the entered goal.
    let onPickWithGoal: (CountValue) -> Void

    @State private var goalText = ""

    private var isRoot: Bool { QuickAddCounterPlacement.isSharedCounterRoot(task) }
    private var kind: CountKind { resolveCountKind(task.countKind) }
    private var title: String {
        isRoot ? CounterSettings.counterDisplayName(task) : (task.title.isEmpty ? "(untitled task)" : task.title)
    }
    private var source: CounterPlacement.PlacementGoalSource? {
        guard isRoot, let timeframe else { return nil }
        return CounterPlacement.placementGoalSource(CounterSettings.Fields(task: task), timeframe: timeframe)
    }
    /// A goal-less root with no default: the row asks for a goal.
    private var needsGoalEntry: Bool { isRoot && timeframe != nil && source == nil && canCreatePending }
    private var enteredGoal: CountValue? {
        parseCountInput(goalText, kind: kind).flatMap { $0 > 0 ? $0 : nil }
    }

    var body: some View {
        if needsGoalEntry {
            HStack(spacing: 10) {
                Button(action: pickWithGoal) { rowLead }
                    .buttonStyle(.plain)
                    .allowsHitTesting(enteredGoal != nil)
                GoalEntryView(
                    kind: kind, text: $goalText, placeholder: "Goal",
                    suffix: (task.unit ?? "").trimmingCharacters(in: .whitespaces)
                )
                .frame(width: 104)
                Button(action: pickWithGoal) { plus }
                    .buttonStyle(.plain)
                    .opacity(enteredGoal != nil ? 1 : 0.45)
                    .allowsHitTesting(enteredGoal != nil)
            }
            .padding(.vertical, 5)
            .padding(.horizontal, 12)
            .frame(minHeight: 44)
        } else {
            Button(action: onPick) {
                HStack(spacing: 10) {
                    rowLead
                    goalSlot
                    plus
                }
                .padding(.vertical, 9)
                .padding(.horizontal, 12)
                .frame(minHeight: isRoot ? 44 : 0)
                .contentShape(Rectangle()) // whole row is the tap target, not just the title/icon glyphs
            }
            .buttonStyle(.plain)
        }
    }

    private func pickWithGoal() {
        guard let goal = enteredGoal else { return }
        onPickWithGoal(goal)
        goalText = ""
    }

    /// Badge · title (· dense kind tag for a counter root), taking the free width.
    private var rowLead: some View {
        HStack(spacing: 10) {
            RisoTypeBadge(kind: task.type.risoQuickAddKind, style: .letterSquare)
            Text(title)
                .font(.risoBody(13.5, .semibold))
                .foregroundStyle(Color.risoInk)
                .lineLimit(1)
            if isRoot { KindTagView(kind: kind, dense: true) }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
    }

    /// "Weekly · 2 books" / "12 books" — the goal a placed copy would get.
    @ViewBuilder
    private var goalSlot: some View {
        if let source, let timeframe {
            let value = formatCount(source.goal, kind: kind) + countUnitSuffix(kind, unit: task.unit)
            (Text(source.fromTimeframe ? "\(timeframe.risoDisplayName) · " : "")
                .font(.risoBody(12, .semibold)).foregroundColor(Color.risoMuted)
                + Text(value).font(.risoBody(12, .bold)).foregroundColor(Color.risoInk))
                .lineLimit(1)
                .fixedSize()
        }
    }

    private var plus: some View {
        Image(systemName: "plus")
            .font(.system(size: 13, weight: .bold))
            .foregroundStyle(Color.risoMuted)
    }
}

// MARK: - TaskType + RisoTaskKind bridge

private extension TaskType {
    /// Maps a `TaskType` to the matching `RisoTaskKind` for the library-poll
    /// dropdown's badge — same mapping as every other Riso badge site
    /// (`EditTaskSheet`, `RisoLibrarySheetView`, etc.), redeclared
    /// file-locally per the existing convention (no shared cross-file
    /// extension exists yet).
    var risoQuickAddKind: RisoTaskKind {
        switch self {
        case .normal:      return .normal
        case .counting:    return .counting
        case .compound:    return .compound
        case .achievement: return .achievement
        }
    }
}
