import SwiftUI

/// Inline edit form for the Task detail surface. Extracted from
/// `TaskDetailView.swift` so both `TaskDetailView` (route-pushed) and
/// `TaskDetailSheetView` (sheet-over-board) can present it without
/// duplication.
///
/// A task's own window (`timeframe` / `startDate` / `endDate`) is NOT
/// editable here: it is set only at creation and by member-rules stamping
/// (where it is a window-stamped derived row's completion window), so no
/// `Patch` field carries it.
///
/// M1 additions:
///   - Achievement re-target: mode toggle (specific board vs recurring
///     template) + picker. Cycle detection runs in the caller's save handler
///     before the DB write.
///
/// Compound sub-tasks and the completion rule are edited here (Sub-tasks &
/// rule section) and saved through AppDatabase.applyTaskEditPatch. The
/// structure is attached to the `Patch` only when it was actually edited, so
/// a compound whose stored structure is already invalid can still be renamed.
///
/// Visual design: Riso vocabulary — ScrollView over `Color.risoPaper`,
/// NavigationStack toolbar with a gold pill Save button and a muted Cancel.
/// Each section is a `.risoCard(fill: .risoPaper2)` block with a
/// `.risoSectionLabel()` heading. Text fields use the kit's
/// `RisoTextField` / `RisoNumberField`; pickers use `RisoSegmented`
/// (2-option rows) or a Riso-styled `Menu`.
struct EditTaskSheet: View {
    let task: Task
    let onSubmit: (Patch) -> Void
    let onCancel: () -> Void

    // Available boards / templates loaded by the parent for the Achievement picker.
    var availableBoards: [Board] = []
    var availableTemplates: [RecurringBoardTemplate] = []

    /// Database the compound's sub-tasks are loaded from (DB-injection seam;
    /// defaulted so production call sites are unchanged).
    var database: AppDatabase = .shared

    // MARK: - Patch

    struct Patch {
        // Common
        var title: String
        var description: String
        // Counting
        var action: String
        var unit: String
        var maxCountStr: String
        // Achievement
        var trigger: AchievementTrigger
        var requiredCountStr: String
        // Achievement re-target
        var refMode: RefMode
        var selectedBoardId: String
        var selectedTemplateId: String
        /// Compound structure (operator / threshold / sub-tasks) — nil for
        /// non-compound tasks and for callers that only edit basic fields.
        /// Defaulted so every existing memberwise `Patch(...)` call compiles.
        var compound: TaskEditPatch? = nil

        enum RefMode {
            case board, template
        }
    }

    // MARK: - State

    @State private var title: String
    @State private var description: String
    @State private var action: String
    @State private var unit: String
    @State private var maxCountStr: String
    // Achievement
    @State private var trigger: AchievementTrigger
    @State private var requiredCountStr: String
    @State private var refMode: Patch.RefMode
    @State private var selectedBoardId: String
    @State private var selectedTemplateId: String
    // Compound structure (rule + sub-tasks). nil until the current sub-tasks
    // have loaded; the draft's own `title` is ignored — the Title field above
    // is the single source (merged in on validate + submit).
    @State private var compoundDraft: TaskEditPatch?
    /// What the editor opened with — only an edited structure is submitted.
    @State private var compoundBaseline: TaskEditPatch?
    @State private var compoundLoadError: String?
    /// Sub-task quick-add inputs — the browsable library (its matches) and
    /// every live link (the loop check), loaded with the sub-tasks.
    @State private var pickerLibraryTasks: [Task] = []
    @State private var pickerLinks: [CompoundChild] = []
    @State private var libraryInputsState: RisoCompoundEditFieldsView.LibraryInputsState = .loading

    // MARK: - Init

    init(
        task: Task,
        availableBoards: [Board] = [],
        availableTemplates: [RecurringBoardTemplate] = [],
        database: AppDatabase = .shared,
        seededCompoundChildren: [Task]? = nil,
        onSubmit: @escaping (Patch) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.task = task
        self.availableBoards = availableBoards
        self.availableTemplates = availableTemplates
        self.database = database
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _title = State(initialValue: task.title)
        _description = State(initialValue: task.description ?? "")
        _action = State(initialValue: task.action ?? "")
        _unit = State(initialValue: task.unit ?? "")
        _maxCountStr = State(initialValue: task.maxCount.map { String($0) } ?? "")
        // Achievement
        _trigger = State(initialValue: task.achievementTrigger ?? .greenlog)
        _requiredCountStr = State(initialValue: task.requiredCount.map { String($0) } ?? "")
        _refMode = State(initialValue: task.referencedTemplateId != nil ? .template : .board)
        _selectedBoardId = State(initialValue: task.referencedBoardId ?? "")
        _selectedTemplateId = State(initialValue: task.referencedTemplateId ?? "")
        // Compound: a caller already holding the ordered children (snapshot
        // fixtures) seeds synchronously; otherwise they load on appear.
        if task.type == .compound, let kids = seededCompoundChildren {
            let seeded = Self.seedCompoundDraft(task: task, children: kids)
            _compoundDraft = State(initialValue: seeded)
            _compoundBaseline = State(initialValue: seeded)
        }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    // ── Type badge + title context ──────────────────────────
                    headerBadge

                    // ── Common fields ───────────────────────────────────────
                    commonSection

                    // ── Counting ────────────────────────────────────────────
                    if task.type == .counting {
                        countingSection
                    }

                    // ── Achievement ─────────────────────────────────────────
                    if task.type == .achievement {
                        achievementSection
                    }

                    // ── Compound sub-tasks & rule ───────────────────────────
                    if task.type == .compound {
                        compoundSection
                    }
                }
                .padding(16)
            }
            .background(Color.risoPaper.ignoresSafeArea())
            .task(id: task.id) { await loadCompoundChildrenIfNeeded() }
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Edit task")
                        .font(.risoHead(17, .extraBold))
                        .foregroundStyle(Color.risoInk)
                }
                ToolbarItem(placement: .confirmationAction) {
                    RisoToolbarPill(title: "Save") { submit() }
                    .disabled(isSaveBlocked)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                        .font(.risoBody(15, .semibold))
                        .foregroundStyle(Color.risoMuted)
                }
            }
        }
    }

    // MARK: - Header

    /// A tasteful type badge + truncated task title at the top of the sheet,
    /// giving the user instant context about what they are editing.
    private var headerBadge: some View {
        HStack(spacing: 8) {
            RisoTypeBadge(kind: task.type.risoKind, style: .pill)
            Text(task.title)
                .font(.risoHead(14, .bold))
                .foregroundStyle(Color.risoMuted)
                .lineLimit(1)
            Spacer(minLength: 0)
        }
    }

    // MARK: - Sections

    /// Title + Description card.
    private var commonSection: some View {
        risoSection(label: "Details") {
            VStack(alignment: .leading, spacing: 11) {
                fieldRow(label: "Title") {
                    RisoTextField(placeholder: "Task title", text: $title)
                }
                fieldRow(label: "Description") {
                    RisoTextField(
                        placeholder: "Optional description",
                        text: $description,
                        axis: .vertical,
                        reservedLines: 3
                    )
                }
            }
        }
    }

    /// Counting-specific fields: Action / Goal / Unit.
    private var countingSection: some View {
        risoSection(label: "Counting") {
            VStack(alignment: .leading, spacing: 11) {
                fieldRow(label: "Action") {
                    RisoTextField(placeholder: "e.g. Run", text: $action)
                }
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        fieldLabel("Goal")
                        RisoNumberField(placeholder: "5", text: $maxCountStr)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        fieldLabel("Unit")
                        RisoTextField(placeholder: "e.g. miles", text: $unit)
                    }
                }
            }
        }
    }

    /// Achievement-specific fields: Trigger + Watches mode + picker + required count.
    private var achievementSection: some View {
        risoSection(label: "Achievement") {
            VStack(alignment: .leading, spacing: 11) {
                // Trigger — Greenlog / Bingo
                fieldRow(label: "Completes on") {
                    RisoSegmented(
                        options: [
                            (value: AchievementTrigger.greenlog, label: "Greenlog"),
                            (value: AchievementTrigger.bingo,    label: "Bingo"),
                        ],
                        selection: $trigger
                    )
                }

                // Watches mode — Specific board / Recurring template
                fieldRow(label: "Watches") {
                    RisoSegmented(
                        options: [
                            (value: Patch.RefMode.board,    label: "Specific board"),
                            (value: Patch.RefMode.template, label: "Repeating board"),
                        ],
                        selection: $refMode
                    )
                }

                // Target picker
                if refMode == .board {
                    fieldRow(label: "Board") {
                        risoMenuPicker(
                            placeholder: "— select a board —",
                            items: availableBoards.map { ($0.id, $0.name) },
                            selectedId: $selectedBoardId
                        )
                    }
                } else {
                    fieldRow(label: "Repeating board") {
                        risoMenuPicker(
                            placeholder: "— select a repeating board —",
                            items: availableTemplates.map { ($0.id, $0.name) },
                            selectedId: $selectedTemplateId
                        )
                    }
                    fieldRow(label: "Required count") {
                        RisoNumberField(placeholder: "e.g. 3", text: $requiredCountStr)
                    }
                }
            }
        }
    }

    /// Compound structure card — the shared `RisoCompoundEditFieldsView`
    /// (rule picker + sub-task cards + the quick-add row), a load/validation line.
    private var compoundSection: some View {
        risoSection(label: "Sub-tasks & rule") {
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
                        libraryInputsState: libraryInputsState
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

    // MARK: - Compound state

    /// Validation of the edited structure titled from the Title field, or nil.
    private var compoundValidation: String? {
        guard task.type == .compound, var draft = compoundDraft else { return nil }
        draft.title = title
        return draft.validate(type: .compound)
    }

    /// Save is blocked on an empty title; for a compound, also while the
    /// sub-tasks are loading, and — only when the structure was edited — on
    /// structure validation (an unedited, already-invalid stored structure
    /// still saves through the basic route).
    private var isSaveBlocked: Bool {
        if title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return true }
        guard task.type == .compound else { return false }
        guard compoundDraft != nil else { return true }
        return Self.compoundStructureChanged(baseline: compoundBaseline, draft: compoundDraft)
            && compoundValidation != nil
    }

    /// Load the compound's live sub-tasks (childIndex order) and the
    /// sub-task quick-add row's library inputs off the main actor. The sub-tasks
    /// seed the draft + baseline unless a caller already seeded them (Task
    /// Detail passes the children it holds); the library inputs always load,
    /// in their own `do` so a failure there never blocks the sub-task editor
    /// (it surfaces as `libraryInputsState == .failed`). No-op for
    /// non-compounds.
    private func loadCompoundChildrenIfNeeded() async {
        guard task.type == .compound else { return }
        let db = database
        let parentId = task.id
        let userId = task.userId
        if compoundDraft == nil {
            do {
                let kids = try await _Concurrency.Task.detached(priority: .userInitiated) {
                    try db.fetchCompoundChildrenTasks(parentTaskId: parentId)
                }.value
                if compoundDraft == nil {
                    let seeded = Self.seedCompoundDraft(task: task, children: kids)
                    compoundBaseline = seeded
                    compoundDraft = seeded
                }
            } catch {
                compoundLoadError = "Couldn't load sub-tasks: \(error.localizedDescription)"
            }
        }
        do {
            let library = try await _Concurrency.Task.detached(priority: .userInitiated) {
                try db.fetchCompoundPickerInputs(userId: userId)
            }.value
            pickerLibraryTasks = library.libraryTasks
            pickerLinks = library.allLinks
            libraryInputsState = .loaded
        } catch {
            #if DEBUG
            print("[EditTaskSheet] loading sub-task library inputs failed: \(error)")
            #endif
            libraryInputsState = .failed
        }
    }

    // MARK: - Shared Riso layout helpers

    /// A card section: `.risoSectionLabel()` heading above a `.risoCard` body.
    ///
    /// - Parameters:
    ///   - label: The uppercase section heading text.
    ///   - content: The card interior content.
    @ViewBuilder
    private func risoSection<Content: View>(
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

    /// Label + field stacked vertically.
    @ViewBuilder
    private func fieldRow<Content: View>(
        label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            fieldLabel(label)
            content()
        }
    }

    /// Muted uppercase field label matching the Riso spec's `fieldLabel` helper.
    private func fieldLabel(_ text: String) -> some View {
        Text(text)
            .risoSectionLabel()
    }

    /// Riso-styled Menu picker row for board / template selection.
    ///
    /// - Parameters:
    ///   - placeholder: Text shown when nothing is selected (empty string id).
    ///   - items: `(id, name)` pairs to populate the menu.
    ///   - selectedId: Binding to the currently selected id string.
    private func risoMenuPicker(
        placeholder: String,
        items: [(String, String)],
        selectedId: Binding<String>
    ) -> some View {
        Menu {
            Button(placeholder) { selectedId.wrappedValue = "" }
            Divider()
            ForEach(items, id: \.0) { id, name in
                Button(name) { selectedId.wrappedValue = id }
            }
        } label: {
            let currentName = items.first(where: { $0.0 == selectedId.wrappedValue })?.1
            HStack {
                Text(currentName ?? placeholder)
                    .font(.risoHead(14, .bold))
                    .foregroundStyle(currentName != nil ? Color.risoInk : Color.risoMuted)
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

    // MARK: - Submit

    private func submit() {
        onSubmit(
            Patch(
                title: title,
                description: description,
                action: action,
                unit: unit,
                maxCountStr: maxCountStr,
                trigger: trigger,
                requiredCountStr: requiredCountStr,
                refMode: refMode,
                selectedBoardId: selectedBoardId,
                selectedTemplateId: selectedTemplateId,
                compound: task.type == .compound
                    ? Self.compoundSubmission(baseline: compoundBaseline, draft: compoundDraft, title: title)
                    : nil
            )
        )
    }
}

// MARK: - Compound edit gate (pure — twin of web `pages/tasks/compoundEditGate.ts`)

extension EditTaskSheet {
    /// The editor seed for a compound: its rule + the given children
    /// (already in `childIndex` order) as `ChildPatch` rows.
    ///
    /// - Parameters:
    ///   - task: The compound being edited.
    ///   - children: Its live child tasks, ordered by `childIndex`.
    /// - Returns: The seeded structure draft.
    static func seedCompoundDraft(task: Task, children: [Task]) -> TaskEditPatch {
        var draft = TaskEditPatch.seededForEditor(from: task)
        draft.children = children.map { ChildPatch(from: $0) }
        return draft
    }

    /// Whether the compound's rule / sub-tasks differ from what the sheet
    /// opened with. The title is ignored — the Title field owns it and it
    /// saves through either route. `false` while either side is nil.
    ///
    /// - Parameters:
    ///   - baseline: The structure seeded on open (nil until loaded).
    ///   - draft: The current edited structure (nil until loaded).
    /// - Returns: `true` only when the structure itself was edited.
    static func compoundStructureChanged(baseline: TaskEditPatch?, draft: TaskEditPatch?) -> Bool {
        guard var b = baseline, var d = draft else { return false }
        b.title = ""
        d.title = ""
        return b != d
    }

    /// The compound structure to submit, or nil to save through the basic
    /// route. Only an edited structure is submitted, so a compound whose
    /// STORED structure already fails validation (one sub-task left, a stale
    /// threshold, zero sub-tasks) can still be renamed / re-described
    /// exactly as before.
    ///
    /// - Parameters:
    ///   - baseline: The structure seeded on open (nil until loaded).
    ///   - draft: The current edited structure (nil until loaded).
    ///   - title: The sheet's Title field (trimmed into the structure).
    /// - Returns: The structure patch titled from the sheet, or nil.
    static func compoundSubmission(baseline: TaskEditPatch?, draft: TaskEditPatch?, title: String) -> TaskEditPatch? {
        guard var d = draft, compoundStructureChanged(baseline: baseline, draft: d) else { return nil }
        d.title = title.trimmingCharacters(in: .whitespacesAndNewlines)
        return d
    }
}

// MARK: - TaskType + RisoTaskKind bridge

private extension TaskType {
    /// Maps a `TaskType` to the matching `RisoTaskKind` for badge rendering.
    var risoKind: RisoTaskKind {
        switch self {
        case .normal:      return .normal
        case .counting:    return .counting
        case .compound:    return .compound
        case .achievement: return .achievement
        }
    }
}
