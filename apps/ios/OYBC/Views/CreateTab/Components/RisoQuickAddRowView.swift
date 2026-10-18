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
    /// The FULL (unfiltered) task set the row tag / counter-name search resolves
    /// counter roots against — never the browse- or candidate-filtered
    /// `libraryTasks`, which drops linked members. `libraryTasks` is merged
    /// in so hosts that pass nothing keep resolving what they can.
    var counterRootTasks: [OYBC.Task] = []
    /// Ids to exclude from matches (already-selected/added tasks).
    var selectedIds: Set<String> = []
    /// Fired when the user taps a matched library row — the host appends
    /// the EXISTING task's id (reuse, no create). `nil` (default) disables
    /// polling entirely, matching today's create-only hosts.
    var onExistingTaskPicked: ((OYBC.Task) -> Void)? = nil
    /// After a pick, the text the field should hold next instead of clearing
    /// (the compound editor primes a hub counter's verb); the dropdown then
    /// stays closed until the text changes. nil / returning nil clears, as
    /// before. Web twin: `onExistingTaskPicked` returning a string.
    var textAfterPick: ((OYBC.Task) -> String?)? = nil
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
    /// The board's timeframe a counter match row resolves its placement goal
    /// against (a root with no goal for it gets an inline Goal entry). nil
    /// falls back to `defaultTimeframe`. Kept separate from `defaultTimeframe`
    /// so a host (Board Edit's picker) can resolve the goal without changing
    /// the timeframe its created tasks carry.
    var placementTimeframe: Timeframe? = nil
    /// The window `placementTimeframe` belongs to (a CUSTOM board's default
    /// scales to it). nil falls back to `defaultStartDate` / `defaultEndDate`.
    var placementStartDate: String? = nil
    var placementEndDate: String? = nil
    /// Drop counters with no goal of their own (every counter created from the
    /// Counters hub) from the matches — for a compound sub-task, which can't
    /// take one. Default false: every other host places them (placement mints
    /// the copy at the window's default). Web twin:
    /// `WizardQuickAddRow.excludeGoalLessCounters`.
    var excludeGoalLessCounters: Bool = false

    /// Counter Detail's "+ New" preset: the create counts toward this counter.
    var presetCountsTowardCounterId: String? = nil
    /// A one-off board wizard: picking a counter places the root itself and
    /// reports the window's default goal (`placementGoalSource`) through
    /// `onCounterGoalPicked`, so the row shows that goal and an edit to it
    /// stays on this board's placement. Default false (a repeating board keeps
    /// the plain root: each spawn plans its own window's default). Web twin:
    /// `WizardQuickAddRow.linksCounterPicks`.
    var linksCounterPicks: Bool = false
    /// A counter ROOT was picked at `goal` (the board window's default, or one
    /// the row asked for): the host sets the cell's placement parameter. Nil
    /// hosts place the root plainly.
    /// `typed` is true when the person entered the goal (a root nothing resolves
    /// for); false for the board window's automatic default.
    var onCounterGoalPicked: ((_ root: OYBC.Task, _ goal: CountValue, _ typed: Bool) -> Void)? = nil

    @State private var text: String = ""
    /// The text a pick left in the field — the dropdown hides while it is unchanged.
    @State private var heldText: String? = nil
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
    private func libraryMatches(roots: [String: OYBC.Task]) -> [OYBC.Task] {
        guard onExistingTaskPicked != nil, !trimmedText.isEmpty else { return [] }
        // The shared match set (docs/SHARED_COUNTER_SETTINGS.md §2) plus the
        // counter's name / noun for its unit tasks and copies; direct hits first.
        // Hub counters (no goal of their own) are browsable and place at the
        // window's default; only a compound sub-task host drops them.
        let pool = excludeGoalLessCounters
            ? libraryTasks.filter { !BrowsableTasks.isGoalLessCounter($0) }
            : libraryTasks
        // A counter already on this board — itself, or a linked copy of it —
        // is not offered again (owner rule 2026-10-13: one per scope).
        let linkedOnBoard = Set(selectedIds.compactMap { roots[$0]?.sharedCounterId })
        let candidates = pool.filter { !selectedIds.contains($0.id) && !linkedOnBoard.contains($0.id) }
        return Array(CounterPlacement.rankedTaskMatches(candidates, query: trimmedText, rootsById: roots).prefix(4))
    }

    /// The pool indexed by id, so each match row's counter tag is a lookup, not a scan.
    private var rootsById: [String: OYBC.Task] {
        Dictionary((counterRootTasks + libraryTasks).map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Dropdown shows whenever matches exist — purely text-driven, mirroring
    /// `RisoCompoundFieldsView.subAutocompleteVisible`'s actual behavior
    /// (also text-driven, not focus-driven). This alone satisfies "hides
    /// when empty/on selection": both submit and a match tap clear `text`,
    /// which empties the matches on the next render.

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
        counterRootTasks: [OYBC.Task] = [],
        selectedIds: Set<String> = [],
        onExistingTaskPicked: ((OYBC.Task) -> Void)? = nil,
        textAfterPick: ((OYBC.Task) -> String?)? = nil,
        onSubmitText: ((String) -> Void)? = nil,
        submitTextEnabled: Bool = true,
        onTextChange: ((String) -> Void)? = nil,
        placeholderOverride: String? = nil,
        placementTimeframe: Timeframe? = nil,
        placementStartDate: String? = nil,
        placementEndDate: String? = nil,
        excludeGoalLessCounters: Bool = false,
        seedText: String = "",
        presetCountsTowardCounterId: String? = nil,
        linksCounterPicks: Bool = false,
        onCounterGoalPicked: ((_ root: OYBC.Task, _ goal: CountValue, _ typed: Bool) -> Void)? = nil
    ) {
        self.userId = userId
        self.defaultTimeframe = defaultTimeframe
        self.defaultStartDate = defaultStartDate
        self.defaultEndDate = defaultEndDate
        self.onTaskCreated = onTaskCreated
        self.onPendingCreated = onPendingCreated
        self.onLibraryReloadRequested = onLibraryReloadRequested
        self.libraryTasks = libraryTasks
        self.counterRootTasks = counterRootTasks
        self.selectedIds = selectedIds
        self.onExistingTaskPicked = onExistingTaskPicked
        self.textAfterPick = textAfterPick
        self.onSubmitText = onSubmitText
        self.submitTextEnabled = submitTextEnabled
        self.onTextChange = onTextChange
        self.placeholderOverride = placeholderOverride
        self.placementTimeframe = placementTimeframe
        self.placementStartDate = placementStartDate
        self.placementEndDate = placementEndDate
        self.excludeGoalLessCounters = excludeGoalLessCounters
        _text = State(initialValue: seedText)
        self.presetCountsTowardCounterId = presetCountsTowardCounterId
        self.linksCounterPicks = linksCounterPicks
        self.onCounterGoalPicked = onCounterGoalPicked
    }

    /// The preset applies to an immediate Normal create only.
    private var presetActive: Bool {
        presetCountsTowardCounterId != nil && onSubmitText == nil && onPendingCreated == nil
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
                    .onChange(of: text) { _, newValue in
                        // The dropdown hold lasts only while the picked text is untouched.
                        if newValue != heldText { heldText = nil }
                        onTextChange?(newValue)
                    }
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

            // Resolved once per render: the roots index, then the ranked matches.
            let roots = trimmedText.isEmpty ? [:] : rootsById
            let matches = libraryMatches(roots: roots)
            if !matches.isEmpty, heldText != text {
                libraryMatchesDropdown(
                    matches, roots: roots,
                    counterRootIds: QuickAddCounterPlacement.counterRootIds(in: Array(roots.values))
                )
                    .padding(.top, 8)
            }

            if presetActive {
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
    private func libraryMatchesDropdown(
        _ matches: [OYBC.Task], roots: [String: OYBC.Task], counterRootIds: Set<String>
    ) -> some View {
        VStack(alignment: .leading, spacing: 0) {
            ForEach(matches) { task in
                QuickAddMatchRow(
                    task: task,
                    isRoot: QuickAddCounterPlacement.isSharedCounterRoot(task, linkedRootIds: counterRootIds),
                    counterTagName: rowCounterTagName(task: task, rootsById: roots),
                    timeframe: placementTimeframe ?? defaultTimeframe,
                    startDate: placementTimeframe != nil ? placementStartDate : defaultStartDate,
                    endDate: placementTimeframe != nil ? placementEndDate : defaultEndDate,
                    canCreatePending: onCounterGoalPicked != nil,
                    linksCounterPick: linksCounterPicks && onCounterGoalPicked != nil,
                    onPick: {
                        onExistingTaskPicked?(task)
                        if let next = textAfterPick?(task) {
                            heldText = next
                            text = next
                        } else {
                            text = ""
                        }
                    },
                    onPickWithGoal: { goal, typed in
                        // The root is placed as itself; the goal rides as a
                        // placement parameter (slice 3b) — no copy is created.
                        // Goal first: a host that confirms on the pick (Board Edit's
                        // picker) needs it already buffered.
                        onCounterGoalPicked?(task, goal, typed)
                        onExistingTaskPicked?(task)
                        text = ""
                    }
                )

                if task.id != matches.last?.id {
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
        form.countsToward = presetActive ? CountsTowardSelection(counterId: presetCountsTowardCounterId) : CountsTowardSelection()

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
        form = CreateFormViewModel()
        placeholderIndex += 1
        focused = true
    }
}

// MARK: - Match row

/// One dropdown row. A plain task shows badge · title · plus. A shared counter
/// ROOT shows badge · counter name · a dense kind tag · plus — no goal text
/// (owner ruling 2026-10-12: redundant on the row). In a board context
/// (`timeframe` set), a goal-less root with no default for the board instead
/// shows an inline Goal entry that gates the plus (the row then places the root
/// with that goal as a placement parameter). Web twin: `WizardQuickAddRow`'s
/// match row.
private struct QuickAddMatchRow: View {
    let task: OYBC.Task
    /// A shared counter root (`QuickAddCounterPlacement.isSharedCounterRoot`):
    /// the row is the COUNTER — its name and kind tag.
    let isRoot: Bool
    /// The counter a unit task / linked copy belongs to (`rowCounterTagName`):
    /// a dense `UnitTagView` inline after the title. nil for everything else.
    var counterTagName: String? = nil
    let timeframe: Timeframe?
    /// The board's window (CUSTOM only).
    var startDate: String? = nil
    var endDate: String? = nil
    /// A host that can take a pending task (the wizard, Board Edit's picker).
    let canCreatePending: Bool
    /// A root with a resolved goal is added as a linked copy at that goal
    /// (`RisoQuickAddRowView.linksCounterPicks`).
    var linksCounterPick: Bool = false
    /// Place the existing task (a plain row, or a root with a goal source).
    let onPick: () -> Void
    /// Place the root at the entered goal (a placement parameter).
    let onPickWithGoal: (_ goal: CountValue, _ typed: Bool) -> Void

    @State private var goalText = ""

    private var kind: CountKind { resolveCountKind(task.countKind) }
    private var title: String {
        isRoot ? CounterSettings.counterDisplayName(task) : (task.title.isEmpty ? "(untitled task)" : task.title)
    }
    private var source: CounterPlacement.PlacementGoalSource? {
        guard isRoot, let timeframe else { return nil }
        return CounterPlacement.placementGoalSource(
            CounterSettings.Fields(task: task), timeframe: timeframe, startDate: startDate, endDate: endDate
        )
    }
    /// A root nothing resolves for (a CUSTOM board without dates, for a counter
    /// with no goal at all): the row asks for a goal.
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
            Button(action: pick) {
                HStack(spacing: 10) {
                    rowLead
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

    /// A plain pick — or, for a counter on a one-off board, its linked copy at the default.
    private func pick() {
        if linksCounterPick, isRoot, let source { onPickWithGoal(source.goal, false) } else { onPick() }
    }

    private func pickWithGoal() {
        guard let goal = enteredGoal else { return }
        onPickWithGoal(goal, true)
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
                .layoutPriority(1)
            if isRoot { KindTagView(kind: kind, dense: true) }
            else if let counterTagName {
                UnitTagView(name: counterTagName, dense: true)
                // A Counting unit task / copy keeps its muted auto title after the tag (nothing when it restates the title).
                if task.type == .counting, let goal = TaskCountDisplay.counterRowSubtitle(for: task) {
                    Text(goal)
                        .font(.risoBody(12, .regular))
                        .foregroundStyle(Color.risoMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 0)
        }
        .contentShape(Rectangle())
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
