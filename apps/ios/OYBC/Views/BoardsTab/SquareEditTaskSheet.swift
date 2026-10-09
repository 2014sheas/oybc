import SwiftUI

// MARK: - SquareEditTaskSheet

/// Bottom sheet for staged in-place editing of a **global Task** from board-edit
/// mode (Phase 2 — Edit tasks sub-mode).
///
/// This sheet edits **only** the subset of task fields exposed in the board-edit
/// flow: name, type (Simple / Counting / Compound), type-specific counters and,
/// for a compound, its rule + sub-tasks (the shared `RisoCompoundEditFieldsView`).
/// Nothing is written to the database on Done — the parent (`BoardPlayView`)
/// stages a `StagedTaskOverride` and commits on "Save changes".
///
/// Key invariants:
///   - An achievement's type is immutable here: the sheet seeds its real
///     type, hides the type picker, and edits the title only (its trigger
///     and target are edited from Task Detail). The commit path ignores any
///     override into or out of Achievement too
///     (`BoardPlayViewModel.boardEditAllowsTypeSwitch`).
///   - The "Free" type chip is Phase 2b (center conversion) — omitted here.
///   - Switching INTO Compound is allowed from Simple / Counting (the
///     picker's third segment opens the compound editor); never OUT of it:
///     a compound's type is fixed (no picker) and its editor is always open.
///     The commit path enforces the same rule
///     (`BoardPlayViewModel.boardEditAllowsTypeSwitch`).
///   - A Counting task picks its kind (a linked counter shows it as a tag);
///     the switch is STAGED on the patch and applied inside the Save
///     transaction (`BoardPlayViewModel.applyStagedOverrides`).
///
/// Design language: Riso vocabulary (risoHead/risoBody fonts, risoCard sections,
/// RisoTextField / RisoNumberField / RisoSegmented / RisoToolbarPill). Mirrors
/// `EditTaskSheet` in layout rhythm but scoped to this simpler field set.
struct SquareEditTaskSheet: View {

    // MARK: - Props

    /// Task to edit. Caller pre-applies any existing `StagedTaskOverride` so
    /// the sheet opens with the most recent staged state.
    let task: Task
    /// The task as STORED (or as its pending payload holds it) — before any
    /// staged override. Decides whether the type picker shows and what
    /// "Compound" means (a conversion vs an edit), and supplies the counting
    /// fields when the user switches back to Counting. nil ⇒ `task` itself.
    var original: Task? = nil
    /// The compound rule + sub-tasks already STAGED for this task (its
    /// `StagedTaskOverride.compound`). When set the editor reopens on it, so
    /// reopen-then-Done re-stages the same structure instead of dropping it.
    var stagedCompound: TaskEditPatch? = nil
    /// An existing compound's ordered sub-tasks, when the caller already holds
    /// them (snapshot fixtures; a still-pending compound whose children are
    /// not in the DB yet). nil ⇒ `loadInputs` supplies them.
    var compoundChildren: [Task]? = nil
    /// Sub-task quick-add inputs (browsable library + every live link).
    var libraryTasks: [Task] = []
    var allLinks: [CompoundChild] = []
    var libraryInputsState: RisoCompoundEditFieldsView.LibraryInputsState = .loaded
    /// Optional async loader the presenter supplies (reads through the
    /// injected database); results replace the props above on appear.
    var loadInputs: (() async -> CompoundInputs)? = nil
    /// Read-only: how many linked squares a Continuous → Discrete switch
    /// would also write (the confirm's "Follows on" line).
    var database: AppDatabase = .shared
    /// Ids (this task, its sub-tasks) the Save would FORK for the board being
    /// edited — placed on another board (docs/BOARD_SCOPED_TASK_EDITS.md).
    /// Done reads "Save for this board" when the task forks, or when the
    /// compound editor changes a forking sub-task. From
    /// `AppDatabase.boardScopedForkCheck`.
    var forkingTaskIds: Set<String> = []
    /// Stored rows of the sub-tasks — the baseline a step is compared to.
    var forkBaselineRows: [String: Task] = [:]
    /// This board's edit session already confirmed a fork (§8: ask once).
    var forkConfirmed: Bool = false
    /// Records the first-fork confirm for the rest of the edit session.
    var onForkConfirmed: (() -> Void)? = nil
    let onDone: (Patch) -> Void
    let onCancel: () -> Void

    /// Done's label when the Save would fork (web `FORK_DONE_LABEL`).
    static let forkDoneLabel = "Save for this board"
    /// The first-fork confirm body (spec §1, verbatim; web `FORK_CONFIRM_BODY`).
    static let forkConfirmBody = "Applies to this board only. Other boards keep the original."

    /// Done's label for a sheet whose Save would (or would not) fork.
    static func doneLabel(wouldFork: Bool) -> String { wouldFork ? forkDoneLabel : "Done" }

    /// Whether the sheet's Save would fork anything: the task itself, or a
    /// sub-task the compound editor changes that is placed on another board.
    /// Twin of web `sheetWouldFork`.
    static func wouldFork(
        taskId: String, draft: TaskEditPatch?, forkingTaskIds: Set<String>, rows: [String: Task]
    ) -> Bool {
        if forkingTaskIds.contains(taskId) { return true }
        return (draft?.children ?? []).contains { step in
            guard let id = step.childTaskId, forkingTaskIds.contains(id) else { return false }
            return AppDatabase.childStepChanged(rows[id], step: step)
        }
    }

    /// The live fork flag for this sheet's current draft.
    private var wouldFork: Bool {
        Self.wouldFork(
            taskId: task.id, draft: type == .compound ? compoundDraft : nil,
            forkingTaskIds: forkingTaskIds, rows: forkBaselineRows
        )
    }

    /// Whether Done must first ask — a fork this edit session hasn't confirmed.
    static func needsForkConfirm(wouldFork: Bool, confirmed: Bool) -> Bool { wouldFork && !confirmed }

    /// What `loadInputs` returns.
    struct CompoundInputs {
        /// The compound's ordered live sub-tasks; nil keeps the current seed.
        var children: [Task]?
        var libraryTasks: [Task]
        var allLinks: [CompoundChild]
        /// False ⇒ the library inputs failed to load (editor still usable).
        var libraryLoaded: Bool = true
        /// Non-nil ⇒ the sub-tasks failed to load (shown, Done stays blocked).
        var childrenError: String? = nil
    }

    // MARK: - Patch

    /// Staged overrides returned on Done. Caller stores this in
    /// `editTaskOverrides[taskId]` without touching the database.
    struct Patch {
        var title: String
        var type: TaskType
        /// Empty string = field left blank / unchanged for non-counting types.
        var action: String
        var unit: String
        /// nil = no valid goal entered (non-counting or blank).
        var maxCount: CountValue?
        /// Compound rule + sub-tasks — non-nil for a conversion INTO Compound
        /// and for an EDITED existing compound (an untouched one stays nil so
        /// a stored-invalid compound can still be renamed). Title is the
        /// sheet's Title field.
        var compound: TaskEditPatch? = nil
        /// The kind chosen for a Counting task (nil for every other type).
        /// Staged; a stored root switches inside the Save transaction.
        var countKind: CountKind? = nil
    }

    // MARK: - Local state

    @State private var title: String
    @State private var type: TaskType
    @State private var action: String
    @State private var unit: String
    @State private var maxCountStr: String
    @State private var countKind: CountKind
    @State private var pendingSwitch: KindSwitchPreview?
    // Compound editor draft (rule + sub-tasks). nil only while an EXISTING
    // compound's sub-tasks are still loading. The draft's own `title` is
    // ignored — the Title field is the single source.
    @State private var compoundDraft: TaskEditPatch?
    /// What the editor opened with — an existing compound submits only an
    /// edited structure.
    @State private var compoundBaseline: TaskEditPatch?
    /// True when the editor was seeded from a STAGED compound — Done then
    /// always re-stages the draft (never overwrites the override with nil).
    @State private var seededFromStaged = false
    @State private var compoundLoadError: String?
    @State private var pickerLibraryTasks: [Task]
    @State private var pickerLinks: [CompoundChild]
    @State private var pickerInputsState: RisoCompoundEditFieldsView.LibraryInputsState
    @State private var confirmingFork = false

    // MARK: - Init

    init(
        task: Task,
        original: Task? = nil,
        stagedCompound: TaskEditPatch? = nil,
        compoundChildren: [Task]? = nil,
        libraryTasks: [Task] = [],
        allLinks: [CompoundChild] = [],
        libraryInputsState: RisoCompoundEditFieldsView.LibraryInputsState = .loaded,
        loadInputs: (() async -> CompoundInputs)? = nil,
        startingType: TaskType? = nil,
        database: AppDatabase = .shared,
        forkingTaskIds: Set<String> = [],
        forkBaselineRows: [String: Task] = [:],
        forkConfirmed: Bool = false,
        onForkConfirmed: (() -> Void)? = nil,
        onDone: @escaping (Patch) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.task = task
        self.original = original
        self.stagedCompound = stagedCompound
        self.compoundChildren = compoundChildren
        self.libraryTasks = libraryTasks
        self.allLinks = allLinks
        self.libraryInputsState = libraryInputsState
        self.loadInputs = loadInputs
        self.database = database
        self.forkingTaskIds = forkingTaskIds
        self.forkBaselineRows = forkBaselineRows
        self.forkConfirmed = forkConfirmed
        self.onForkConfirmed = onForkConfirmed
        self.onDone = onDone
        self.onCancel = onCancel

        // Blank for an auto-titled Counting task so the title re-derives
        // from Action/Goal/Unit (see `seededTitle(for:)`).
        _title       = State(initialValue: Self.seededTitle(for: task))
        // `startingType` pre-selects a segment (snapshot fixtures render the
        // converted-Compound state without driving a tap); production leaves nil.
        _type        = State(initialValue: startingType ?? Self.initialType(for: task))
        // Counting fields seed from the merged task while it is Counting (it
        // carries any staged edit), else from the ORIGINAL — so switching back
        // to Counting offers the stored values, not blanks.
        let countingSource = task.type == .counting ? task : (original ?? task)
        _action      = State(initialValue: countingSource.action ?? "")
        _unit        = State(initialValue: countingSource.unit ?? "")
        _maxCountStr = State(initialValue: countingSource.maxCount.map { formatCountForInput($0, kind: resolveCountKind(countingSource.countKind)) } ?? "")
        _countKind   = State(initialValue: resolveCountKind(countingSource.countKind))
        _pickerLibraryTasks = State(initialValue: libraryTasks)
        _pickerLinks = State(initialValue: allLinks)
        _pickerInputsState = State(initialValue: libraryInputsState)
        let seed = Self.compoundSeed(task: task, original: original, staged: stagedCompound, children: compoundChildren)
        _compoundDraft = State(initialValue: seed.draft)
        _compoundBaseline = State(initialValue: seed.baseline)
        _seededFromStaged = State(initialValue: seed.fromStaged)
    }

    /// What the compound editor opens with.
    struct CompoundSeed {
        /// nil only while an EXISTING compound's sub-tasks are still loading.
        var draft: TaskEditPatch?
        /// The stored structure an unedited existing compound is compared to.
        var baseline: TaskEditPatch?
        /// True ⇒ seeded from a STAGED compound (Done always re-stages it).
        var fromStaged: Bool
    }

    /// The editor's initial structure. A STAGED compound (a conversion or an
    /// edited existing compound being reopened) wins over the stored / pending
    /// task, so reopen shows — and Done re-stages — what was staged; else an
    /// existing compound seeds from its children (nil until loaded), and a
    /// Simple / Counting task starts from the default empty "all" rule.
    ///
    /// - Parameters:
    ///   - task: The override-merged task.
    ///   - original: The task as stored / pending (nil ⇒ `task`).
    ///   - staged: The override's staged compound, if any.
    ///   - children: An existing compound's ordered sub-tasks, if held.
    static func compoundSeed(task: Task, original: Task?, staged: TaskEditPatch?, children: [Task]?) -> CompoundSeed {
        if let staged { return CompoundSeed(draft: staged, baseline: nil, fromStaged: true) }
        if (original ?? task).type == .compound {
            guard let children else { return CompoundSeed(draft: nil, baseline: nil, fromStaged: false) }
            let seeded = EditTaskSheet.seedCompoundDraft(task: task, children: children)
            return CompoundSeed(draft: seeded, baseline: seeded, fromStaged: false)
        }
        return CompoundSeed(draft: newCompoundDraft(for: task), baseline: nil, fromStaged: false)
    }

    /// The compound structure Done submits for the chosen `type`, or nil.
    /// A conversion INTO Compound, or an editor reopened on a staged compound,
    /// always submits the draft; an existing compound submits only an edited
    /// structure (so a stored-invalid one can still be renamed).
    static func compoundSubmission(
        type: TaskType, originalType: TaskType, seededFromStaged: Bool,
        baseline: TaskEditPatch?, draft: TaskEditPatch?, title: String
    ) -> TaskEditPatch? {
        guard type == .compound else { return nil }
        if originalType != .compound || seededFromStaged {
            guard var d = draft else { return nil }
            d.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
            return d
        }
        return EditTaskSheet.compoundSubmission(baseline: baseline, draft: draft, title: title)
    }

    /// Whether the Simple / Counting / Compound picker shows: only for a task
    /// that may still switch type (never a compound, an achievement or a
    /// linked counter).
    static func showsTypePicker(task: Task, original: Task?) -> Bool {
        let t = (original ?? task).type
        return (t == .normal || t == .counting) && task.sharedCounterId == nil
    }

    /// The empty compound structure a Simple / Counting task starts from when
    /// the user picks Compound (default "all" rule, no sub-tasks).
    static func newCompoundDraft(for task: Task) -> TaskEditPatch {
        var draft = TaskEditPatch(title: task.title)
        draft.operatorType = .and
        return draft
    }

    /// What the Title field opens with. A Counting task whose stored title is
    /// still its AUTO one (`TaskTitle.isAutoCounterTitle`) seeds BLANK so the
    /// title keeps re-deriving as Action/Goal/Unit change — seeded as text it
    /// would read as a chosen name and `applyingOverride` would carry the
    /// stale "Run 10 miles" onto a goal of 5. A custom title (and any other
    /// type) seeds verbatim. Mirrors `TaskEditPatch.seededForEditor(from:)`
    /// and web `seedSheetTitle`.
    ///
    /// - Parameter task: The task being edited (any staged override merged).
    /// - Returns: The initial Title field text.
    static func seededTitle(for task: Task) -> String {
        guard task.type == .counting else { return task.title }
        let isAuto = TaskTitle.isAutoCounterTitle(
            title: task.title, action: task.action ?? "", maxCount: task.maxCount, unit: task.unit ?? "",
            countKind: resolveCountKind(task.countKind)
        )
        return isAuto ? "" : task.title
    }

    /// The type the sheet's local state is seeded with (and therefore the
    /// `Patch.type` Done returns when the type segment is left untouched).
    ///
    /// Always the task's REAL type — never clamped. (It used to seed an
    /// achievement as `.normal`, so a plain rename on an achievement square
    /// rewrote the task into a Simple task on Save — the P0 in
    /// docs/BOARD_EDIT_REDESIGN.md.)
    static func initialType(for task: Task) -> TaskType {
        task.type
    }

    /// Whether the Simple / Counting / Compound type picker is shown — only
    /// for a task that may still switch type (never a compound or an
    /// achievement).
    private var showsTypePicker: Bool { Self.showsTypePicker(task: task, original: original) }

    /// The task's stored (pre-override) type.
    private var originalType: TaskType { (original ?? task).type }

    // MARK: - Validation

    /// Done is enabled iff:
    ///   - title is non-empty (every type but Counting — a blank Counting
    ///     title is auto-generated from Action/Goal/Unit at Save, matching
    ///     `TaskEditPatch.validate` and the web sheet).
    ///   - counting: goal parses at the sheet's kind AND (unless Duration)
    ///     unit is non-empty.
    ///   - compound: the editor has loaded and, for a conversion (or an EDITED
    ///     existing compound), `TaskEditPatch.validate(type: .compound)` passes.
    ///     The link guard (self / duplicate / loop) runs at Save; the editor
    ///     only offers eligible library tasks.
    private var isValid: Bool {
        if type == .counting {
            let goalOK = parseCountInput(maxCountStr, kind: countKind) != nil
            let unitOK = !countKindNeedsUnit(countKind) || !unit.trimmingCharacters(in: .whitespaces).isEmpty
            return goalOK && unitOK
        }
        let trimTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimTitle.isEmpty else { return false }
        if type == .compound { return !isCompoundBlocked }
        return true
    }

    // MARK: - Compound state

    /// The edited structure titled from the Title field, or nil while loading.
    private var titledDraft: TaskEditPatch? {
        guard var d = compoundDraft else { return nil }
        d.title = title
        return d
    }

    /// Whether a conversion is in progress (picked Compound on a non-compound).
    private var isConverting: Bool { originalType != .compound && type == .compound }

    /// The blocking validation message for the compound structure, or nil.
    /// An UNEDITED existing compound is never blocked (a stored-invalid one
    /// can still be renamed), mirroring `EditTaskSheet`.
    private var compoundValidation: String? {
        guard type == .compound, let d = titledDraft else { return nil }
        if !isConverting && !seededFromStaged
            && !EditTaskSheet.compoundStructureChanged(baseline: compoundBaseline, draft: compoundDraft) {
            return nil
        }
        return d.validate(type: .compound)
    }

    private var isCompoundBlocked: Bool {
        compoundDraft == nil || compoundValidation != nil
    }

    /// The compound structure Done submits, or nil (non-compound; untouched
    /// existing compound).
    private var compoundSubmission: TaskEditPatch? {
        Self.compoundSubmission(
            type: type, originalType: originalType, seededFromStaged: seededFromStaged,
            baseline: compoundBaseline, draft: compoundDraft, title: title
        )
    }

    /// Pulls the presenter's loaded inputs into the sheet state.
    private func applyLoaded(_ inputs: CompoundInputs) {
        if originalType == .compound, compoundDraft == nil, let kids = inputs.children {
            let seeded = EditTaskSheet.seedCompoundDraft(task: task, children: kids)
            compoundBaseline = seeded
            compoundDraft = seeded
        }
        compoundLoadError = inputs.childrenError
        pickerLibraryTasks = inputs.libraryTasks
        pickerLinks = inputs.allLinks
        pickerInputsState = inputs.libraryLoaded ? .loaded : .failed
    }

    // MARK: - Counting preview

    /// "Reads as: Run — 5 — km" — shown under the counting fields.
    private var countingPreview: String? {
        guard type == .counting else { return nil }
        let a = action.trimmingCharacters(in: .whitespaces)
        let g = maxCountStr.trimmingCharacters(in: .whitespaces)
        let u = countKindNeedsUnit(countKind) ? unit.trimmingCharacters(in: .whitespaces) : ""
        guard !a.isEmpty || !g.isEmpty || !u.isEmpty else { return nil }
        return "Reads as: \([a, g, u].filter { !$0.isEmpty }.joined(separator: " — "))"
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    headerBadge
                    nameSection
                    if showsTypePicker { typeSection }
                    if type == .counting { countingSection }
                    if type == .compound { compoundSection }
                }
                .padding(16)
            }
            .background(Color.risoPaper.ignoresSafeArea())
            .task(id: task.id) {
                guard let loadInputs else { return }
                applyLoaded(await loadInputs())
            }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Edit task")
                        .font(.risoHead(17, .extraBold))
                        .foregroundStyle(Color.risoInk)
                }
                ToolbarItem(placement: .confirmationAction) {
                    RisoToolbarPill(title: Self.doneLabel(wouldFork: wouldFork)) { requestSubmit() }
                        .disabled(!isValid)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                        .font(.risoBody(15, .semibold))
                        .foregroundStyle(Color.risoMuted)
                }
            }
            .alert("\(Self.forkDoneLabel)?", isPresented: $confirmingFork) {
                Button("Cancel", role: .cancel) {}
                Button(Self.forkDoneLabel) {
                    onForkConfirmed?()
                    submit()
                }
            } message: {
                Text(Self.forkConfirmBody)
            }
        }
    }

    // MARK: - Header

    /// Type pill + truncated original task title — quick context for what is
    /// being edited, matching the `EditTaskSheet` header pattern.
    private var headerBadge: some View {
        HStack(spacing: 8) {
            RisoTypeBadge(kind: task.type.squareEditKind, style: .pill)
            Text(task.title)
                .font(.risoHead(14, .bold))
                .foregroundStyle(Color.risoMuted)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Sections

    private var nameSection: some View {
        editSection(label: "Details") {
            editFieldRow(label: "Title") {
                RisoTextField(placeholder: "Task title", text: $title)
            }
        }
    }

    private var typeSection: some View {
        editSection(label: "Type") {
            RisoSegmented(
                options: [
                    (.normal,   "Simple"),
                    (.counting, "Counting"),
                    (.compound, "Compound"),
                ],
                selection: $type
            )
        }
    }

    private var countingSection: some View {
        editSection(label: "Counting") {
            VStack(alignment: .leading, spacing: 11) {
                editFieldRow(label: "Action") {
                    RisoTextField(placeholder: "e.g. Run", text: $action)
                }
                editFieldRow(label: "Kind") {
                    if task.sharedCounterId != nil {
                        KindTagView(linkedTask: task, root: database.linkedCounterRoot(of: task))
                    } else {
                        KindPickerView(
                            selection: $countKind,
                            lock: kindPickerLock(mode: originalType == .counting ? .edit : .create, kind: stagedKind),
                            onRequest: requestKind
                        )
                    }
                }
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Goal")
                            .risoSectionLabel()
                        GoalEntryView(kind: countKind, text: $maxCountStr, placeholder: "5")
                    }
                    if countKindNeedsUnit(countKind) {
                        VStack(alignment: .leading, spacing: 5) {
                            Text("Unit")
                                .risoSectionLabel()
                            RisoTextField(placeholder: "e.g. miles", text: $unit)
                        }
                    }
                }
                if let preview = countingPreview {
                    Text(preview)
                        .font(.risoBody(12, .semibold))
                        .foregroundStyle(Color.risoBlue)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
        }
        .kindSwitchConfirm(pending: $pendingSwitch) { p in
            applyConfirmedSwitch(p)
        }
    }

    // MARK: - Kind

    /// The kind the sheet opened with (stored, or a staged one merged into
    /// `task`) — the picker's locks follow it.
    private var stagedKind: CountKind {
        resolveCountKind((task.type == .counting ? task : (original ?? task)).countKind)
    }

    /// Continuous → Discrete opens the confirm (previewing the DRAFT — title /
    /// goal typed in this sheet); any other permitted change applies at once.
    private func requestKind(_ next: CountKind) {
        guard KindSwitchCopy.needsConfirm(from: countKind, to: next) else { countKind = next; return }
        let linked = (try? database.previewCounterKindSwitch(rootTaskId: task.id, to: next))?.linkedCount ?? 0
        pendingSwitch = KindSwitchPreview.planned(task: draftTask, to: next, linkedCount: linked)
    }

    /// The task overlaid with this sheet's unsaved counting fields; a blank
    /// Title reads as the title it would generate.
    private var draftTask: Task {
        var t = task
        t.type = .counting
        t.action = action
        t.unit = countKindNeedsUnit(countKind) ? unit : ""
        t.countKind = countKind
        if let goal = parseCountInput(maxCountStr, kind: countKind) { t.maxCount = goal }
        let trimmed = title.trimmingCharacters(in: .whitespacesAndNewlines)
        t.title = trimmed.isEmpty
            ? TaskTitle.generateCounterTaskTitle(
                action: action, maxCount: t.maxCount, unit: t.unit ?? "", countKind: countKind
            )
            : trimmed
        return t
    }

    /// Applies a confirmed switch to the sheet's fields. A blank (auto) title
    /// keeps re-deriving; a typed title that reads as the auto one follows.
    private func applyConfirmedSwitch(_ p: KindSwitchPreview) {
        if !title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty,
           let titleAfter = KindSwitchPreview.planned(task: draftTask, to: p.to, linkedCount: 0)?.titleAfter {
            title = titleAfter
        }
        maxCountStr = KindSwitchCopy.switchedGoalText(maxCountStr, from: p.from, to: p.to)
        countKind = p.to
    }

    /// The compound structure editor — the shared `RisoCompoundEditFieldsView`
    /// (rule + sub-task cards + quick-add row) over a `TaskEditPatch` draft.
    private var compoundSection: some View {
        editSection(label: "Sub-tasks & rule") {
            VStack(alignment: .leading, spacing: 8) {
                if let draft = compoundDraft {
                    RisoCompoundEditFieldsView(
                        draft: Binding(
                            get: { compoundDraft ?? draft },
                            set: { compoundDraft = $0 }
                        ),
                        parentId: task.id,
                        libraryTasks: pickerLibraryTasks,
                        allLinks: pickerLinks,
                        libraryInputsState: pickerInputsState
                    )
                    if let problem = compoundValidation {
                        Text(problem)
                            .font(.risoBody(11.5, .extraBold))
                            .foregroundStyle(Color.risoRed)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                } else if let error = compoundLoadError {
                    Text(error)
                        .font(.risoBody(12, .semibold))
                        .foregroundStyle(Color.risoRed)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Loading sub-tasks…")
                        .font(.risoBody(12, .semibold))
                        .foregroundStyle(Color.risoMuted)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Riso layout helpers

    @ViewBuilder
    private func editSection<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label)
                .risoSectionLabel()
            content()
                .padding(12)
                .risoCard(fill: .risoPaper2)
                .risoHardShadow(Riso.Shadow.small)
        }
    }

    @ViewBuilder
    private func editFieldRow<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            Text(label)
                .risoSectionLabel()
            content()
        }
    }

    // MARK: - Submit

    /// Done: asks once per edit session before the first fork, else submits.
    private func requestSubmit() {
        if Self.needsForkConfirm(wouldFork: wouldFork, confirmed: forkConfirmed) {
            confirmingFork = true
        } else {
            submit()
        }
    }

    private func submit() {
        onDone(
            Patch(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                type: type,
                action: action.trimmingCharacters(in: .whitespaces),
                unit: countKindNeedsUnit(countKind) ? unit.trimmingCharacters(in: .whitespaces) : "",
                maxCount: parseCountInput(maxCountStr, kind: countKind),
                compound: compoundSubmission,
                countKind: type == .counting ? countKind : nil
            )
        )
    }
}

// MARK: - TaskType extension

private extension TaskType {
    /// Maps to a `RisoTaskKind` for the header badge in `SquareEditTaskSheet`.
    var squareEditKind: RisoTaskKind {
        switch self {
        case .normal:      return .normal
        case .counting:    return .counting
        case .compound:    return .compound
        case .achievement: return .achievement
        }
    }
}

// MARK: - Preview

#Preview("Normal — light") {
    let json = """
    {"id":"t-normal","userId":"u1","title":"Morning workout","type":"normal","totalCompletions":0,
     "totalInstances":0,"isCompleted":false,"createdAt":"2026-01-01T00:00:00Z",
     "updatedAt":"2026-01-01T00:00:00Z","version":1,"isDeleted":false,"createdInWizard":false}
    """
    let task = try! JSONDecoder().decode(Task.self, from: json.data(using: .utf8)!)
    return SquareEditTaskSheet(task: task, onDone: { _ in }, onCancel: {})
}

#Preview("Counting — light") {
    let json = """
    {"id":"t-count","userId":"u1","title":"Run daily","type":"counting","action":"Run",
     "unit":"km","maxCount":5,"totalCompletions":0,"totalInstances":0,"isCompleted":false,
     "createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z",
     "version":1,"isDeleted":false,"createdInWizard":false}
    """
    let task = try! JSONDecoder().decode(Task.self, from: json.data(using: .utf8)!)
    return SquareEditTaskSheet(task: task, onDone: { _ in }, onCancel: {})
}

#Preview("Compound — light") {
    let json = """
    {"id":"t-comp","userId":"u1","title":"Morning routine","type":"compound",
     "totalCompletions":0,"totalInstances":0,"isCompleted":false,
     "createdAt":"2026-01-01T00:00:00Z","updatedAt":"2026-01-01T00:00:00Z",
     "version":1,"isDeleted":false,"createdInWizard":false}
    """
    let task = try! JSONDecoder().decode(Task.self, from: json.data(using: .utf8)!)
    return SquareEditTaskSheet(task: task, onDone: { _ in }, onCancel: {})
}
