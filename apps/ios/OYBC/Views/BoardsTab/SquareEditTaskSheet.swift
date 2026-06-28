import SwiftUI

// MARK: - SquareEditTaskSheet

/// Bottom sheet for staged in-place editing of a **global Task** from board-edit
/// mode (Phase 2 — Edit tasks sub-mode).
///
/// This sheet edits **only** the subset of task fields exposed in the board-edit
/// flow: name, type (Simple / Counting / Compound), and type-specific counters.
/// Nothing is written to the database on Done — the parent (`BoardPlayView`)
/// stages a `StagedTaskOverride` and commits on "Save changes".
///
/// Key invariants:
///   - Achievement tasks are never surfaced here (the tap-menu skips them).
///   - The "Free" type chip is Phase 2b (center conversion) — omitted here.
///   - Compound → Simple/Counting type switches are staged but DO NOT cascade-
///     delete `compound_children` rows — that cleanup is deferred and safe
///     (orphaned rows with a changed parent type are inert).
///   - The "everywhere" hint is always visible so the user understands they are
///     editing the task globally, not cloning it per-square.
///
/// Design language: Riso vocabulary (risoHead/risoBody fonts, risoCard sections,
/// RisoTextField / RisoNumberField / RisoSegmented / RisoToolbarPill). Mirrors
/// `EditTaskSheet` in layout rhythm but scoped to this simpler field set.
struct SquareEditTaskSheet: View {

    // MARK: - Props

    /// Task to edit. Caller pre-applies any existing `StagedTaskOverride` so
    /// the sheet opens with the most recent staged state.
    let task: Task
    let onDone: (Patch) -> Void
    let onCancel: () -> Void

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
        var maxCount: Int?
    }

    // MARK: - Local state

    @State private var title: String
    @State private var type: TaskType
    @State private var action: String
    @State private var unit: String
    @State private var maxCountStr: String

    // MARK: - Init

    init(
        task: Task,
        onDone: @escaping (Patch) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.task = task
        self.onDone = onDone
        self.onCancel = onCancel

        // Achievement tasks are never surfaced from the board-edit tap menu,
        // but clamp defensively to .normal so state is always valid.
        let seedType: TaskType = task.type == .achievement ? .normal : task.type
        _title       = State(initialValue: task.title)
        _type        = State(initialValue: seedType)
        _action      = State(initialValue: task.action ?? "")
        _unit        = State(initialValue: task.unit ?? "")
        _maxCountStr = State(initialValue: task.maxCount.map { String($0) } ?? "")
    }

    // MARK: - Validation

    /// Done is enabled iff:
    ///   - title is non-empty (all types).
    ///   - counting: goal is a positive integer AND unit is non-empty.
    private var isValid: Bool {
        let trimTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimTitle.isEmpty else { return false }
        if type == .counting {
            let goalOK = (Int(maxCountStr.trimmingCharacters(in: .whitespaces)) ?? 0) > 0
            let unitOK = !unit.trimmingCharacters(in: .whitespaces).isEmpty
            return goalOK && unitOK
        }
        return true
    }

    // MARK: - Counting preview

    /// "Reads as: Run — 5 — km" — shown under the counting fields.
    private var countingPreview: String? {
        guard type == .counting else { return nil }
        let a = action.trimmingCharacters(in: .whitespaces)
        let g = maxCountStr.trimmingCharacters(in: .whitespaces)
        let u = unit.trimmingCharacters(in: .whitespaces)
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
                    typeSection
                    if type == .counting { countingSection }
                    if type == .compound { compoundSection }
                    everywhereHint
                }
                .padding(16)
            }
            .background(Color.risoPaper.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Edit task")
                        .font(.risoHead(17, .extraBold))
                        .foregroundStyle(Color.risoInk)
                }
                ToolbarItem(placement: .confirmationAction) {
                    RisoToolbarPill(title: "Done") { submit() }
                        .disabled(!isValid)
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
                HStack(alignment: .top, spacing: 10) {
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Goal")
                            .risoSectionLabel()
                        RisoNumberField(placeholder: "5", text: $maxCountStr)
                    }
                    VStack(alignment: .leading, spacing: 5) {
                        Text("Unit")
                            .risoSectionLabel()
                        RisoTextField(placeholder: "e.g. miles", text: $unit)
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
    }

    /// Read-only notice for compound tasks. Subtasks are not editable from
    /// the board-edit flow — direct the user to the wizard.
    private var compoundSection: some View {
        editSection(label: "Compound") {
            Text("Compound subtasks are edited from the board-creation wizard. The title can still be changed here.")
                .font(.risoBody(13, .semibold))
                .foregroundStyle(Color.risoMuted)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// Subtle full-width hint reminding the user that this edits the task
    /// globally (not a per-square clone).
    private var everywhereHint: some View {
        HStack(spacing: 6) {
            Image(systemName: "globe")
                .font(.system(size: 12, weight: .semibold))
                .foregroundStyle(Color.risoMuted)
            Text("Editing this task changes it everywhere it's used.")
                .font(.risoBody(12, .regular))
                .foregroundStyle(Color.risoMuted)
        }
        .padding(.top, 4)
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

    private func submit() {
        onDone(
            Patch(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                type: type,
                action: action.trimmingCharacters(in: .whitespaces),
                unit: unit.trimmingCharacters(in: .whitespaces),
                maxCount: Int(maxCountStr.trimmingCharacters(in: .whitespaces))
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
