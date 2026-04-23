import SwiftUI

/// Preview payload for a composite: first few leaf titles + total.
/// Mirrors web's `CompositeLeafPreview`. Lifted here from the
/// retired `LibraryPickerSheetView.swift` so the row subtitle helper
/// has a stable home.
struct CompositeLeafPreview: Equatable {
    let titles: [String]
    let totalLeaves: Int
}

/// Library row model — internal to the inline picker section.
private struct CompositeLibraryRow: Identifiable {
    let id: String
    let title: String
    /// "normal" / "counting" / "progress" / "composite" — matches
    /// `TypeBadgeView` input.
    let typeLabel: String
    let subtitle: String
    let usageHint: String
    let kind: SubtaskItem.SelectionType
}

private enum CompositeLibraryFilter: String, CaseIterable, Identifiable {
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

/// CompositeWizardBuildStepView — Step 2 of the composite-task mini-wizard.
/// iOS twin of web's `BuildStep`. Hosts the subtask list (selected
/// subtasks render as flat rows; inline-created ones keep their card
/// frame), the M_OF_N threshold stepper, the `+ Create new task`
/// button, and an always-visible library section. Tapping a library
/// row toggles membership immediately — no modal sheet, matching the
/// board wizard's Tasks-step pattern.
struct CompositeWizardBuildStepView: View {
    /// Wrapped subtask array. Observing the wrapper (not a plain
    /// binding) is what keeps `readyCount` / `canAdvance` / the
    /// Next-button state in sync when any child `SubtaskItem`'s
    /// `@Published` properties change — the wrapper re-broadcasts
    /// each child's `objectWillChange` upward.
    @ObservedObject var subtaskList: CompositeSubtaskList
    /// Operator chosen on Setup. Threshold only surfaces when M_OF_N.
    let operatorType: OperatorType
    /// Required-N — picked on this step (not Setup) so the user sees
    /// the subtask list while choosing. Clamped down silently when the
    /// list shrinks below it; both are on-screen so no toast needed.
    @Binding var threshold: Int
    let libraryTasks: [OYBC.Task]
    let libraryCompositeTasks: [CompositeTask]
    let taskBoardCounts: [String: Int]
    let taskStepCounts: [String: Int]
    let compositeSubtaskCounts: [String: Int]
    let compositeLeafPreviews: [String: CompositeLeafPreview]
    let onRemove: (SubtaskItem) -> Void
    /// Toggle a library item in/out of the composite. Add (not
    /// already a subtask) or remove (already an existing-mode subtask)
    /// is decided by the parent.
    let onToggleLibraryItem: (_ id: String, _ kind: SubtaskItem.SelectionType) -> Void
    let onAddInline: () -> Void
    let onBack: () -> Void
    let onNext: () -> Void

    @State private var query: String = ""
    @State private var filter: CompositeLibraryFilter = .all

    // MARK: - Derived state

    private func isReady(_ item: SubtaskItem) -> Bool {
        switch item.mode {
        case .existing:
            // Existing rows only exist when a concrete library id is
            // attached.
            if item.selectionType == .task { return !item.selectedTaskId.isEmpty }
            return !item.selectedCompositeId.isEmpty
        case .inline_:
            let t = item.inlineTitle.trimmingCharacters(in: .whitespacesAndNewlines)
            switch item.inlineType {
            case .normal:
                return !t.isEmpty
            case .counting:
                let a = item.inlineAction.trimmingCharacters(in: .whitespacesAndNewlines)
                let u = item.inlineUnit.trimmingCharacters(in: .whitespacesAndNewlines)
                let max = Int(item.inlineMaxCountStr) ?? 0
                return !a.isEmpty && !u.isEmpty && max >= 1
            case .progress:
                if t.isEmpty { return false }
                if item.inlineSteps.isEmpty { return false }
                for step in item.inlineSteps {
                    switch step.type {
                    case .normal:
                        if step.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
                    case .counting:
                        if step.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
                        if step.unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { return false }
                        if (Int(step.maxCount) ?? 0) < 1 { return false }
                    default:
                        return false
                    }
                }
                return true
            }
        }
    }

    private var readyCount: Int {
        subtaskList.items.filter { isReady($0) }.count
    }

    private var canAdvance: Bool {
        subtaskList.items.count >= 2
            && readyCount == subtaskList.items.count
    }

    private var statusText: String {
        let count = subtaskList.items.count
        if count < 2 {
            return "Add at least 2 subtasks (\(count) so far)."
        }
        let incomplete = count - readyCount
        if incomplete > 0 {
            return "\(incomplete) card\(incomplete == 1 ? "" : "s") still need attention."
        }
        return "\(readyCount) subtask\(readyCount == 1 ? "" : "s") ready."
    }

    /// Stepper upper bound tracks the actual subtask count; we fall
    /// back to 1 so the display never collapses when the list is
    /// empty. The stepper is disabled at count == 0.
    private var stepperMax: Int {
        max(1, subtaskList.items.count)
    }

    /// Ids currently included as existing-mode subtasks — drives the
    /// library row's checked state and the toggle semantics.
    private var checkedIds: Set<String> {
        var ids = Set<String>()
        for s in subtaskList.items where s.mode == .existing {
            if s.selectionType == .task, !s.selectedTaskId.isEmpty {
                ids.insert(s.selectedTaskId)
            } else if s.selectionType == .composite, !s.selectedCompositeId.isEmpty {
                ids.insert(s.selectedCompositeId)
            }
        }
        return ids
    }

    // MARK: - Library rows

    private var libraryRows: [CompositeLibraryRow] {
        let taskRows: [CompositeLibraryRow] = libraryTasks.map { task in
            let boards = taskBoardCounts[task.id] ?? 0
            // Short hint — long forms ("not on any board", "on 3 boards")
            // eat enough horizontal space on iPhone to truncate the
            // title and subtitle. Keep it concise.
            let usage = boards == 0
                ? "unused"
                : "\(boards) board\(boards == 1 ? "" : "s")"
            return CompositeLibraryRow(
                id: task.id,
                title: task.title,
                typeLabel: task.type.rawValue,
                subtitle: Self.buildTaskSubtitle(for: task, stepCounts: taskStepCounts),
                usageHint: usage,
                kind: .task
            )
        }
        let compositeRows: [CompositeLibraryRow] = libraryCompositeTasks.map { ct in
            let leaves = compositeSubtaskCounts[ct.id] ?? 0
            return CompositeLibraryRow(
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

    private var visibleRows: [CompositeLibraryRow] {
        let q = query.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return libraryRows.filter { row in
            if filter != .all && row.typeLabel != filter.rawValue { return false }
            if q.isEmpty { return true }
            return row.title.lowercased().contains(q)
                || row.subtitle.lowercased().contains(q)
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            statusBanner

            if operatorType == .mOfN {
                thresholdStepper
            }

            // Top section — what the user has committed to. Labelled
            // to match the library section below so the two lists
            // feel balanced, even when there's nothing selected yet.
            selectionsSection

            librarySection

            Divider()

            HStack {
                Button("‹ Back", action: onBack)
                    .buttonStyle(.bordered)
                Spacer()
                Button("Next ›", action: onNext)
                    .buttonStyle(.borderedProminent)
                    .disabled(!canAdvance)
            }
        }
        .padding(14)
        .background(Color(.systemBackground))
        .cornerRadius(10)
        .overlay(
            RoundedRectangle(cornerRadius: 10)
                .stroke(Color(.systemGray4), lineWidth: 1)
        )
        // Clamp threshold silently when the list shrinks below it —
        // both stepper and list are on-screen so no toast needed.
        .onChange(of: subtaskList.items.count) { newCount in
            if operatorType == .mOfN && threshold > max(1, newCount) {
                threshold = max(1, newCount)
            }
        }
    }

    // MARK: - Status banner
    // Prominent strip at the top so the gate message (`Add at least 2…`,
    // `X cards still need attention`) can't be missed — previous caption
    // in the top-right corner was easy to overlook on narrow screens.

    @ViewBuilder
    private var statusBanner: some View {
        HStack(spacing: 8) {
            Image(systemName: canAdvance ? "checkmark.circle.fill" : "info.circle")
                .foregroundColor(canAdvance ? .green : .orange)
            Text(statusText)
                .font(.subheadline)
                .fontWeight(canAdvance ? .semibold : .regular)
                .foregroundColor(canAdvance ? .green : .primary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(canAdvance
                      ? Color.green.opacity(0.12)
                      : Color.orange.opacity(0.08))
        )
    }

    // MARK: - Selections section

    @ViewBuilder
    private var selectionsSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("IN THIS COMPOSITE")
                .font(.caption)
                .fontWeight(.bold)
                .foregroundColor(.secondary)
                .tracking(0.5)

            if subtaskList.items.isEmpty {
                emptyState
            } else {
                VStack(spacing: 10) {
                    ForEach(subtaskList.items) { item in
                        CompositeSubtaskCardView(
                            item: item,
                            libraryTasks: libraryTasks,
                            libraryCompositeTasks: libraryCompositeTasks,
                            taskBoardCounts: taskBoardCounts,
                            taskStepCounts: taskStepCounts,
                            compositeSubtaskCounts: compositeSubtaskCounts,
                            compositeLeafPreviews: compositeLeafPreviews,
                            onRemove: { onRemove(item) }
                        )
                    }
                }
            }
        }
    }

    @ViewBuilder
    private var thresholdStepper: some View {
        let count = subtaskList.items.count
        HStack(spacing: 10) {
            Text("Required to complete:")
                .font(.subheadline)
                .fontWeight(.medium)
            Button("−") {
                if threshold > 1 { threshold -= 1 }
            }
            .buttonStyle(.bordered)
            .disabled(threshold <= 1 || count == 0)
            Text("\(threshold)")
                .frame(minWidth: 30)
                .fontWeight(.semibold)
            Button("+") {
                if threshold < stepperMax { threshold += 1 }
            }
            .buttonStyle(.bordered)
            .disabled(threshold >= stepperMax || count == 0)
            Text(count > 0 ? "of \(count)" : "of your subtasks")
                .font(.subheadline)
                .foregroundColor(.secondary)
            Spacer()
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 8)
                .fill(Color(.systemGray6))
        )
    }

    // MARK: - Library section
    // Flat — no outer box. The step container already frames this
    // area; stacking another background + stroke turned the library
    // into a box-in-a-box that felt cramped on iPhone. Separated now
    // by whitespace + an all-caps section label (matches iOS norms).

    @ViewBuilder
    private var librarySection: some View {
        VStack(alignment: .leading, spacing: 10) {
            // Heading row with inline "+ Create new task" CTA on the
            // right — mirrors the board wizard's Tasks step so the
            // "or make your own" affordance lives with the library,
            // not floating between selections and the library.
            HStack(alignment: .firstTextBaseline) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("PICK FROM YOUR LIBRARY")
                        .font(.caption)
                        .fontWeight(.bold)
                        .foregroundColor(.secondary)
                        .tracking(0.5)
                    Text("Tap a task to add or remove it.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
                Spacer()
                Button("+ New task", action: onAddInline)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
            }

            searchField
            filterTabs
            libraryListContainer
        }
    }

    private var searchField: some View {
        HStack(spacing: 8) {
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
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }

    private var filterTabs: some View {
        // Scrollable pill row instead of a segmented Picker — on iPhone
        // the segmented style was truncating "Composite" to "Compos…"
        // because five even-width segments don't fit the phone's width.
        // `FilterTabsView` scrolls horizontally and matches the web
        // FilterTabs affordance exactly.
        FilterTabsView(
            tabs: CompositeLibraryFilter.allCases.map { f in
                FilterTab(value: f.rawValue, label: f.displayName)
            },
            activeTab: Binding(
                get: { filter.rawValue },
                set: { newValue in
                    if let next = CompositeLibraryFilter(rawValue: newValue) {
                        filter = next
                    }
                }
            ),
            onTabChange: { _ in }
        )
    }

    @ViewBuilder
    private var libraryListContainer: some View {
        let rows = visibleRows
        if libraryRows.isEmpty {
            emptyMessage("Your library is empty — tap + Create new task above to make one.")
        } else if rows.isEmpty {
            let q = query.trimmingCharacters(in: .whitespacesAndNewlines)
            let msg = !q.isEmpty
                ? "No matches for \"\(q)\" in \(filter.displayName)."
                : "No \(filter.rawValue) tasks in your library — try a different filter."
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
            .frame(maxHeight: 280)
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
            .padding(.vertical, 18)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(.systemGray4), style: StrokeStyle(lineWidth: 1, dash: [4]))
            )
    }

    @ViewBuilder
    private func rowButton(row: CompositeLibraryRow) -> some View {
        let checked = checkedIds.contains(row.id)
        Button {
            onToggleLibraryItem(row.id, row.kind)
        } label: {
            HStack(spacing: 12) {
                Image(systemName: checked ? "checkmark.square.fill" : "square")
                    .font(.system(size: 20, weight: .semibold))
                    .foregroundColor(checked ? .blue : .secondary)
                TypeBadgeView(type: row.typeLabel, size: .small, letterOnly: true)
                VStack(alignment: .leading, spacing: 3) {
                    Text(row.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if !row.subtitle.isEmpty {
                        Text(row.subtitle)
                            .font(.footnote)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                Text(row.usageHint)
                    .font(.footnote)
                    .foregroundColor(.secondary)
                    .fixedSize(horizontal: true, vertical: false)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 12)
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

    private var emptyState: some View {
        Text("No subtasks yet. Tap a row from your library below, or create one inline.")
            .font(.subheadline)
            .italic()
            .foregroundColor(.secondary)
            .multilineTextAlignment(.center)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 24)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .strokeBorder(Color(.systemGray4), style: StrokeStyle(lineWidth: 1, dash: [4]))
            )
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
