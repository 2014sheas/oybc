import SwiftUI

/// Preview payload for a composite: first few leaf titles + total.
struct CompositeLeafPreview: Equatable {
    let titles: [String]
    let totalLeaves: Int
}

/// ExistingTaskPickerView — Inline expandable list used inside a
/// composite Build-step subtask card. iOS twin of web's
/// `ExistingTaskPicker`. Collapsed when the card already has a
/// selection; expanded (with search + filter + scrollable rows) when
/// the card is empty or the user tapped Change. Replaces the earlier
/// `.menu Picker` dropdown.
struct ExistingTaskPickerView: View {

    /// Currently selected id — empty string when nothing is picked.
    let selectedId: String

    /// Full library (already filtered at the card level to exclude ids
    /// picked by OTHER subtask cards; the picker uses the same exclusion
    /// set to filter its own rows too).
    let libraryTasks: [OYBC.Task]
    let libraryCompositeTasks: [CompositeTask]
    let excludedTaskIds: Set<String>
    let excludedCompositeIds: Set<String>

    /// Usage maps plumbed from the wizard orchestrator.
    let taskBoardCounts: [String: Int]
    let taskStepCounts: [String: Int]
    let compositeSubtaskCounts: [String: Int]
    let compositeLeafPreviews: [String: CompositeLeafPreview]

    /// Called when a row is tapped. `kind` routes the write into
    /// selectedTaskId vs selectedCompositeId upstream.
    let onSelect: (_ id: String, _ kind: SubtaskItem.SelectionType) -> Void

    // Auto-expanded when nothing is picked; collapsed after a selection.
    // Stored locally so each card manages its own picker state.
    @State private var isOpen: Bool
    @State private var query: String = ""
    @State private var filter: PickerFilter = .all

    init(
        selectedId: String,
        libraryTasks: [OYBC.Task],
        libraryCompositeTasks: [CompositeTask],
        excludedTaskIds: Set<String>,
        excludedCompositeIds: Set<String>,
        taskBoardCounts: [String: Int],
        taskStepCounts: [String: Int],
        compositeSubtaskCounts: [String: Int],
        compositeLeafPreviews: [String: CompositeLeafPreview],
        onSelect: @escaping (String, SubtaskItem.SelectionType) -> Void
    ) {
        self.selectedId = selectedId
        self.libraryTasks = libraryTasks
        self.libraryCompositeTasks = libraryCompositeTasks
        self.excludedTaskIds = excludedTaskIds
        self.excludedCompositeIds = excludedCompositeIds
        self.taskBoardCounts = taskBoardCounts
        self.taskStepCounts = taskStepCounts
        self.compositeSubtaskCounts = compositeSubtaskCounts
        self.compositeLeafPreviews = compositeLeafPreviews
        self.onSelect = onSelect
        _isOpen = State(initialValue: selectedId.isEmpty)
    }

    // MARK: - Filter enum + static tabs

    enum PickerFilter: String, CaseIterable, Identifiable {
        case all = "all"
        case normal = "normal"
        case counting = "counting"
        case progress = "progress"
        case composite = "composite"
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

    // MARK: - Row model

    private struct PickerRow: Identifiable {
        let id: String
        let title: String
        /// "normal" / "counting" / "progress" / "composite" — matches
        /// the TypeBadgeView input.
        let typeLabel: String
        /// Subtitle carrying what-it-does metadata; may be empty.
        let subtitle: String
        /// Trailing usage hint on the right.
        let usageHint: String
        let kind: SubtaskItem.SelectionType
    }

    private var allRows: [PickerRow] {
        let taskRows: [PickerRow] = libraryTasks
            .filter { !excludedTaskIds.contains($0.id) || $0.id == selectedId }
            .map { task in
                let boards = taskBoardCounts[task.id] ?? 0
                let usage = boards == 0
                    ? "not on any board"
                    : "on \(boards) board\(boards == 1 ? "" : "s")"
                return PickerRow(
                    id: task.id,
                    title: task.title,
                    typeLabel: task.type.rawValue,
                    subtitle: Self.buildTaskSubtitle(for: task, stepCounts: taskStepCounts),
                    usageHint: usage,
                    kind: .task
                )
            }
        let compositeRows: [PickerRow] = libraryCompositeTasks
            .filter { !excludedCompositeIds.contains($0.id) || $0.id == selectedId }
            .map { ct in
                let leaves = compositeSubtaskCounts[ct.id] ?? 0
                return PickerRow(
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

    private var visibleRows: [PickerRow] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return allRows.filter { row in
            if filter != .all && row.typeLabel != filter.rawValue { return false }
            if q.isEmpty { return true }
            return row.title.lowercased().contains(q)
                || row.subtitle.lowercased().contains(q)
        }
    }

    private var selectedRow: PickerRow? {
        guard !selectedId.isEmpty else { return nil }
        return allRows.first(where: { $0.id == selectedId })
    }

    // MARK: - Body

    var body: some View {
        if !isOpen, let row = selectedRow {
            collapsedSummary(row: row)
        } else {
            expandedList
        }
    }

    // MARK: - Collapsed (selection confirmed)

    private func collapsedSummary(row: PickerRow) -> some View {
        HStack(spacing: 10) {
            TypeBadgeView(type: row.typeLabel, size: .small)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.title)
                    .font(.system(size: 15, weight: .semibold))
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
            Button("Change") { isOpen = true }
                .buttonStyle(.bordered)
                .controlSize(.small)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemGray6))
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color(.systemGray4), lineWidth: 1)
        )
    }

    // MARK: - Expanded (picking)

    private var expandedList: some View {
        VStack(alignment: .leading, spacing: 10) {
            searchField
            filterTabs

            listContainer

            if selectedRow != nil {
                HStack {
                    Spacer()
                    Button("Keep selection") { isOpen = false }
                        .buttonStyle(.bordered)
                        .controlSize(.small)
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
            ForEach(PickerFilter.allCases) { f in
                Text(f.displayName).tag(f)
            }
        }
        .pickerStyle(.segmented)
    }

    @ViewBuilder
    private var listContainer: some View {
        let rows = visibleRows
        let allRowsEmpty = allRows.isEmpty
        if allRowsEmpty {
            Text("Your library is empty — tap + Create new task below to make one.")
                .font(.subheadline)
                .italic()
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color(.systemGray4), style: StrokeStyle(lineWidth: 1, dash: [4]))
                )
        } else if rows.isEmpty {
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let msg: String = {
                if !q.isEmpty {
                    return "No matches for \"\(q)\" in \(filter.displayName)."
                }
                if filter == .all {
                    return "All of your tasks are already picked by other cards."
                }
                return "No \(filter.rawValue) tasks available — try a different filter."
            }()
            Text(msg)
                .font(.subheadline)
                .italic()
                .foregroundColor(.secondary)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 20)
                .overlay(
                    RoundedRectangle(cornerRadius: 8)
                        .strokeBorder(Color(.systemGray4), style: StrokeStyle(lineWidth: 1, dash: [4]))
                )
        } else {
            ScrollView {
                LazyVStack(spacing: 4) {
                    ForEach(rows) { row in
                        rowButton(row: row)
                    }
                }
                .padding(2)
            }
            .frame(maxHeight: 280)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color(.systemGray4), lineWidth: 1)
            )
        }
    }

    @ViewBuilder
    private func rowButton(row: PickerRow) -> some View {
        let isSelected = row.id == selectedId
        Button {
            onSelect(row.id, row.kind)
            isOpen = false
        } label: {
            HStack(spacing: 10) {
                TypeBadgeView(type: row.typeLabel, size: .small)
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
                    .fill(isSelected
                          ? Color.blue.opacity(0.12)
                          : Color(.systemBackground))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
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
            // Suppress if the title already matches the derived form.
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
