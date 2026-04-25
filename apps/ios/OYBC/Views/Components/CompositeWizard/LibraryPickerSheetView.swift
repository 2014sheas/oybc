import SwiftUI

/// Preview payload for a composite: first few leaf titles + total.
/// Mirrors web's `CompositeLeafPreview`.
struct CompositeLeafPreview: Equatable {
    let titles: [String]
    let totalLeaves: Int
}

/// Add/remove diff produced when the user commits the sheet.
struct LibraryDiff {
    struct AddEntry {
        let id: String
        let kind: SubtaskItem.SelectionType
    }
    let add: [AddEntry]
    let remove: Set<String>
}

/// LibraryPickerSheetView — Sheet for picking multiple existing library
/// items as subtasks of a composite. iOS twin of web's
/// `LibraryPickerSheet`. Each row carries a checkbox whose initial state
/// reflects current composite membership; committing applies the
/// add/remove diff upstream. Cancel discards the pending toggles.
struct LibraryPickerSheetView: View {

    let libraryTasks: [OYBC.Task]
    /// Compound tasks (type=.compound && !isOrdered) available as nested children.
    let libraryCompositeTasks: [OYBC.Task]
    /// Ids currently members of this composite (existing-mode subtasks).
    /// Drives the initial checkbox state.
    let initialCheckedIds: Set<String>
    let taskBoardCounts: [String: Int]
    let taskStepCounts: [String: Int]
    let compositeSubtaskCounts: [String: Int]
    let compositeLeafPreviews: [String: CompositeLeafPreview]
    /// User tapped Done — parent applies the diff to the wizard's subtasks.
    let onCommit: (LibraryDiff) -> Void
    /// User tapped Cancel or swiped the sheet down.
    let onCancel: () -> Void

    @State private var checkedIds: Set<String>
    @State private var query: String = ""
    @State private var filter: SheetFilter = .all

    enum SheetFilter: String, CaseIterable, Identifiable {
        case all, normal, counting, progress, composite
        var id: String { rawValue }
        var displayName: String {
            switch self {
            case .all: return "All"
            case .normal: return "Normal"
            case .counting: return "Counting"
            case .progress: return "Progress"
            case .composite: return "Composite"
            }
        }
    }

    init(
        libraryTasks: [OYBC.Task],
        libraryCompositeTasks: [OYBC.Task],
        initialCheckedIds: Set<String>,
        taskBoardCounts: [String: Int],
        taskStepCounts: [String: Int],
        compositeSubtaskCounts: [String: Int],
        compositeLeafPreviews: [String: CompositeLeafPreview],
        onCommit: @escaping (LibraryDiff) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.libraryTasks = libraryTasks
        self.libraryCompositeTasks = libraryCompositeTasks
        self.initialCheckedIds = initialCheckedIds
        self.taskBoardCounts = taskBoardCounts
        self.taskStepCounts = taskStepCounts
        self.compositeSubtaskCounts = compositeSubtaskCounts
        self.compositeLeafPreviews = compositeLeafPreviews
        self.onCommit = onCommit
        self.onCancel = onCancel
        _checkedIds = State(initialValue: initialCheckedIds)
    }

    // MARK: - Row model

    private struct SheetRow: Identifiable {
        let id: String
        let title: String
        /// "normal" / "counting" / "progress" / "composite" — matches
        /// the TypeBadgeView input.
        let typeLabel: String
        let subtitle: String
        let usageHint: String
        let kind: SubtaskItem.SelectionType
    }

    private var allRows: [SheetRow] {
        let taskRows: [SheetRow] = libraryTasks.map { task in
            let boards = taskBoardCounts[task.id] ?? 0
            let usage = boards == 0
                ? "not on any board"
                : "on \(boards) board\(boards == 1 ? "" : "s")"
            return SheetRow(
                id: task.id,
                title: task.title,
                typeLabel: task.type.rawValue,
                subtitle: Self.buildTaskSubtitle(for: task, stepCounts: taskStepCounts),
                usageHint: usage,
                kind: .task
            )
        }
        let compositeRows: [SheetRow] = libraryCompositeTasks.map { ct in
            let leaves = compositeSubtaskCounts[ct.id] ?? 0
            return SheetRow(
                id: ct.id,
                title: ct.title,
                typeLabel: "composite",
                subtitle: Self.buildCompositeSubtitle(for: ct.id, previews: compositeLeafPreviews),
                usageHint: "\(leaves) subtask\(leaves == 1 ? "" : "s")",
                kind: .composite
            )
        }
        return (taskRows + compositeRows).sorted {
            $0.title.localizedCompare($1.title) == .orderedAscending
        }
    }

    private var visibleRows: [SheetRow] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allRows.filter { row in
            if filter != .all && row.typeLabel != filter.rawValue { return false }
            if q.isEmpty { return true }
            return row.title.lowercased().contains(q)
                || row.subtitle.lowercased().contains(q)
        }
    }

    private var addCount: Int {
        checkedIds.filter { !initialCheckedIds.contains($0) }.count
    }
    private var removeCount: Int {
        initialCheckedIds.filter { !checkedIds.contains($0) }.count
    }
    private var hasChanges: Bool { addCount > 0 || removeCount > 0 }

    private var doneLabel: String {
        guard hasChanges else { return "Done" }
        var parts: [String] = []
        if addCount > 0 { parts.append("+\(addCount)") }
        if removeCount > 0 { parts.append("−\(removeCount)") }
        return "Done (\(parts.joined(separator: ", ")))"
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: 10) {
                Text("Check tasks to include them. Uncheck to remove.")
                    .font(.footnote)
                    .foregroundColor(.secondary)

                searchField
                filterTabs
                listContainer
            }
            .padding(14)
            .navigationTitle("Tasks in this composite")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel", action: onCancel)
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(doneLabel, action: handleDone)
                        .disabled(!hasChanges)
                }
            }
        }
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("Search your tasks…", text: $query)
                .textFieldStyle(.plain)
            if !query.isEmpty {
                Button { query = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }

    private var filterTabs: some View {
        Picker("Filter", selection: $filter) {
            ForEach(SheetFilter.allCases) { f in
                Text(f.displayName).tag(f)
            }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var listContainer: some View {
        let rows = visibleRows
        if allRows.isEmpty {
            emptyMessage("Your library is empty — tap + Create new task in the wizard to add one.")
        } else if rows.isEmpty {
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let msg = !q.isEmpty
                ? "No matches for \"\(q)\" in \(filter.displayName)."
                : "No \(filter.rawValue) tasks available — try a different filter."
            emptyMessage(msg)
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(rows) { row in
                        rowButton(row: row)
                    }
                }
                .padding(2)
            }
            .frame(maxHeight: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(.systemGray4), lineWidth: 1)
            )
        }
    }

    private func emptyMessage(_ text: String) -> some View {
        Text(text)
            .font(.subheadline)
            .italic()
            .foregroundColor(.secondary)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(.systemGray4), style: StrokeStyle(lineWidth: 1, dash: [4]))
            )
    }

    @ViewBuilder
    private func rowButton(row: SheetRow) -> some View {
        let checked = checkedIds.contains(row.id)
        Button {
            toggle(row.id)
        } label: {
            HStack(spacing: 10) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 18, weight: .semibold))
                    .foregroundColor(checked ? .blue : .secondary)
                TypeBadgeView(type: row.typeLabel, size: .small, letterOnly: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(row.title)
                        .font(.system(size: 15, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if !row.subtitle.isEmpty {
                        Text(row.subtitle)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text(row.usageHint)
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 8)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(checked
                          ? Color.blue.opacity(0.12)
                          : Color(.systemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(checked ? Color.blue : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(checked ? [.isSelected] : [])
    }

    // MARK: - Toggle + commit

    private func toggle(_ id: String) {
        if checkedIds.contains(id) {
            checkedIds.remove(id)
        } else {
            checkedIds.insert(id)
        }
    }

    private func handleDone() {
        var add: [LibraryDiff.AddEntry] = []
        for row in allRows where checkedIds.contains(row.id) && !initialCheckedIds.contains(row.id) {
            add.append(LibraryDiff.AddEntry(id: row.id, kind: row.kind))
        }
        let remove = initialCheckedIds.subtracting(checkedIds)
        onCommit(LibraryDiff(add: add, remove: remove))
    }

    // MARK: - Subtitle helpers (mirror web)

    private static func buildTaskSubtitle(
        for task: OYBC.Task,
        stepCounts: [String: Int]
    ) -> String {
        switch task.type {
        case .counting:
            guard let action = task.action,
                  let unit = task.unit,
                  let max = task.maxCount,
                  !action.isEmpty,
                  !unit.isEmpty else {
                return ""
            }
            let derived = "\(action) \(max) \(unit)"
            if derived.lowercased() == task.title.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() {
                return ""
            }
            return derived
        case .progress:
            let n = stepCounts[task.id] ?? 0
            if n == 0 { return "" }
            return "\(n) step\(n == 1 ? "" : "s")"
        default:
            return ""
        }
    }

    private static func buildCompositeSubtitle(
        for compositeId: String,
        previews: [String: CompositeLeafPreview]
    ) -> String {
        guard let preview = previews[compositeId], !preview.titles.isEmpty else {
            return ""
        }
        let visible = preview.titles.joined(separator: ", ")
        let hidden = preview.totalLeaves - preview.titles.count
        return hidden > 0 ? "\(visible), +\(hidden) more" : visible
    }
}
