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

    private var placeholder: String { placeholders[placeholderIndex % placeholders.count] }
    private var trimmedText: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var canSubmit: Bool { !trimmedText.isEmpty }

    /// Library-poll matches — up to 4 browsable tasks whose title contains
    /// the trimmed, lowercased input, excluding already-selected ids.
    /// Mirrors `RisoCompoundFieldsView.subAutocompleteMatches` (cap 4 here,
    /// not 3 — per the quick-add spec). Always empty when the host hasn't
    /// opted in (`onExistingTaskPicked == nil`), which keeps existing
    /// create-only call sites byte-identical to today.
    private var libraryMatches: [OYBC.Task] {
        guard onExistingTaskPicked != nil, !trimmedText.isEmpty else { return [] }
        let q = trimmedText.lowercased()
        return libraryTasks
            .filter { !selectedIds.contains($0.id) }
            .filter { $0.title.lowercased().contains(q) }
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
        seedText: String = ""
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
        _text = State(initialValue: seedText)
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
                Button {
                    onExistingTaskPicked?(task)
                    text = ""
                } label: {
                    HStack(spacing: 10) {
                        RisoTypeBadge(kind: task.type.risoQuickAddKind, style: .letterSquare)
                        Text(task.title.isEmpty ? "(untitled task)" : task.title)
                            .font(.risoBody(13.5, .semibold))
                            .foregroundStyle(Color.risoInk)
                            .lineLimit(1)
                        Spacer(minLength: 0)
                        Image(systemName: "plus")
                            .font(.system(size: 13, weight: .bold))
                            .foregroundStyle(Color.risoMuted)
                    }
                    .padding(.vertical, 9)
                    .padding(.horizontal, 12)
                }
                .buttonStyle(.plain)

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
        guard !trimmed.isEmpty else { return }

        // Configure the form for a Normal task
        form.taskType = .normal
        form.title = trimmed

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

        // Reset immediately — the model's async path handles DB work
        text = ""
        form = CreateFormViewModel()
        placeholderIndex += 1
        focused = true
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
