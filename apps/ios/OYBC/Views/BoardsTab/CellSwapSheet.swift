import SwiftUI

// MARK: - CellSwapMode

/// Controls CellSwapSheet behavior and labeling.
///
/// - `swap`: Excludes `currentTaskId` from the list and labels the CTA "Swap" (M3).
/// - `add`: Shows all eligible tasks with no exclusion; labels the CTA "Add" (M4).
enum CellSwapMode {
    case swap
    case add
}

// MARK: - CellSwapSheet

/// Task-picker sheet for the live-edit cell swap (M3) and empty-cell add (M4).
///
/// Displays the user's full task library filtered to types eligible for a
/// non-center square (NORMAL / COUNTING / COMPOUND / ACHIEVEMENT). In swap
/// mode the Task currently occupying the square is excluded; in add mode all
/// eligible tasks are shown.
///
/// Rendered in the Riso design language: `RisoPaperBackground`, `RisoTextField`
/// search bar, `RisoTypeBadge` per-row type indicators, `RisoButton` CTA.
///
/// UX mirrors the web `CellSwapModal`:
///   - Search field filters by title (case-insensitive substring).
///   - Single-select list row; selected row gets a gold checkmark.
///   - CTA button ("Swap" or "Add") is disabled until a task is chosen.
///   - Tapping the same row again deselects (no forced selection).
///
/// The caller is responsible for:
///   - Providing `candidateTasks` filtered to non-deleted tasks for the user.
///   - Calling `onConfirm(newTaskId:)` to write the change (the sheet does NOT
///     write to the database itself).
///
/// - Parameters:
///   - mode: `.swap` (default) or `.add`. Controls exclusion + CTA label.
///   - currentTaskId: The Task currently in the square (excluded in swap mode).
///   - candidateTasks: All non-deleted tasks in the user's library.
///   - onDismiss: Called when the user cancels without selecting.
///   - onConfirm: Called with the chosen Task's id.
struct CellSwapSheet: View {

    // MARK: - Parameters

    var mode: CellSwapMode = .swap
    let currentTaskId: String
    let candidateTasks: [Task]
    let onDismiss: () -> Void
    let onConfirm: (String) -> Void

    // MARK: - State

    @State private var query: String = ""
    @State private var selectedTaskId: String? = nil

    // MARK: - Eligible task types

    private let eligibleTypes: Set<TaskType> = [.normal, .counting, .compound, .achievement]

    // MARK: - Filtering

    private var filtered: [Task] {
        candidateTasks.filter { task in
            guard !task.isDeleted else { return false }
            // In swap mode, exclude the task currently occupying the square.
            if mode == .swap, task.id == currentTaskId { return false }
            guard eligibleTypes.contains(task.type) else { return false }
            if query.trimmingCharacters(in: .whitespaces).isEmpty { return true }
            return task.title.localizedCaseInsensitiveContains(query)
        }
        .sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
    }

    /// CTA button label — "Swap" for M3, "Add" for M4.
    private var ctaLabel: String {
        mode == .add ? "Add" : "Swap"
    }

    /// Navigation / sheet kicker label — differs by mode.
    private var sheetKicker: String {
        mode == .add ? "Add to cell" : "Swap task"
    }

    /// Sheet heading — differs by mode.
    private var sheetTitle: String {
        mode == .add ? "Add a task to this cell" : "Swap with another task"
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            ZStack {
                RisoPaperBackground()
                VStack(spacing: 0) {
                    // ── Header ──
                    sheetHeader
                        .padding(.horizontal, Riso.gutter)
                        .padding(.top, 20)
                        .padding(.bottom, 14)

                    // ── Search ──
                    searchBar
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 10)

                    // ── Divider ──
                    Rectangle()
                        .fill(Color.risoInk.opacity(0.12))
                        .frame(height: 1)

                    // ── Task list or empty state ──
                    if filtered.isEmpty {
                        emptyState
                    } else {
                        taskList
                    }

                    // ── CTA ──
                    ctaBar
                }
            }
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                        .font(.risoBody(14, .semibold))
                        .foregroundStyle(Color.risoInk)
                }
            }
        }
        .presentationDetents([.medium, .large])
        .presentationBackground(Color.risoPaper)
    }

    // MARK: - Sheet header

    private var sheetHeader: some View {
        HStack(alignment: .bottom, spacing: 12) {
            VStack(alignment: .leading, spacing: 2) {
                Text(sheetKicker.uppercased())
                    .risoKicker()
                Text(sheetTitle)
                    .risoH2()
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - Search bar

    private var searchBar: some View {
        HStack(spacing: 8) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(Color.risoMuted)
            TextField("Search tasks…", text: $query)
                .font(.risoHead(14, .bold))
                .foregroundStyle(Color.risoInk)
                .tint(Color.risoBlue)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.risoMuted)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.risoPaper2)
        .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
        )
    }

    // MARK: - Task list

    private var taskList: some View {
        ScrollView {
            LazyVStack(spacing: 0) {
                ForEach(filtered, id: \.id) { task in
                    taskRow(task)
                    if task.id != filtered.last?.id {
                        Rectangle()
                            .fill(Color.risoInk.opacity(0.08))
                            .frame(height: 1)
                            .padding(.horizontal, Riso.gutter)
                    }
                }
            }
            .padding(.bottom, 8)
        }
    }

    @ViewBuilder
    private func taskRow(_ task: Task) -> some View {
        let isSelected = task.id == selectedTaskId
        Button {
            selectedTaskId = isSelected ? nil : task.id
        } label: {
            HStack(spacing: 12) {
                // Type letter badge
                RisoTypeBadge(kind: risoKind(for: task.type), style: .letterSquare)

                // Title + subtitle
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(.risoHead(14, .bold))
                        .foregroundStyle(Color.risoInk)
                        .lineLimit(1)
                        .truncationMode(.tail)
                    Text(taskTypeLabel(task.type))
                        .font(.risoBody(11.5, .semibold))
                        .foregroundStyle(Color.risoMuted)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                // Gold checkmark when selected
                if isSelected {
                    Image(systemName: "checkmark")
                        .font(.system(size: 14, weight: .bold))
                        .foregroundStyle(Color.risoGold)
                        .overlay(
                            Image(systemName: "checkmark")
                                .font(.system(size: 14, weight: .bold))
                                .foregroundStyle(Color.risoInk)
                                .blendMode(.multiply)
                                .opacity(0.2)
                        )
                }
            }
            .contentShape(Rectangle())
            .padding(.horizontal, Riso.gutter)
            .padding(.vertical, 13)
        }
        .buttonStyle(.plain)
        .background(isSelected ? Color.risoPaper2 : Color.clear)
    }

    // MARK: - Empty state

    private var emptyState: some View {
        VStack(spacing: 12) {
            Spacer()
            Text(query.trimmingCharacters(in: .whitespaces).isEmpty
                 ? "No eligible tasks found."
                 : "No tasks match your search.")
                .risoH2()
                .multilineTextAlignment(.center)
            if !query.trimmingCharacters(in: .whitespaces).isEmpty {
                Text("Try a different search term.")
                    .risoSub()
                    .multilineTextAlignment(.center)
            }
            Spacer()
        }
        .padding(Riso.gutter)
    }

    // MARK: - CTA bar

    private var ctaBar: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.risoInk.opacity(0.12))
                .frame(height: 1)

            HStack {
                RisoButton(
                    title: ctaLabel,
                    kind: selectedTaskId != nil ? .primary : .neutral,
                    fullWidth: true,
                    action: {
                        if let id = selectedTaskId {
                            onConfirm(id)
                        }
                    }
                )
                .disabled(selectedTaskId == nil)
                .opacity(selectedTaskId == nil ? 0.5 : 1.0)
            }
            .padding(Riso.gutter)
        }
    }

    // MARK: - Helpers

    /// Maps the data model `TaskType` onto `RisoTaskKind` for badge rendering.
    private func risoKind(for type: TaskType) -> RisoTaskKind {
        switch type {
        case .normal:      return .normal
        case .counting:    return .counting
        case .compound:    return .compound
        case .achievement: return .achievement
        }
    }

    private func taskTypeLabel(_ type: TaskType) -> String {
        switch type {
        case .normal:      return "Normal"
        case .counting:    return "Counting"
        case .compound:    return "Compound"
        case .achievement: return "Achievement"
        }
    }
}

// MARK: - Preview

#Preview {
    CellSwapSheet(
        currentTaskId: "task-1",
        candidateTasks: [
            Task(
                id: "task-2", userId: "u1", title: "Read 10 pages",
                type: .counting,
                unit: "pages", maxCount: 10,
                totalCompletions: 0, totalInstances: 0,
                createdAt: "2024-01-01T00:00:00.000Z",
                updatedAt: "2024-01-01T00:00:00.000Z",
                version: 1, isDeleted: false
            ),
            Task(
                id: "task-3", userId: "u1", title: "Go for a walk",
                type: .normal,
                totalCompletions: 0, totalInstances: 0,
                createdAt: "2024-01-01T00:00:00.000Z",
                updatedAt: "2024-01-01T00:00:00.000Z",
                version: 1, isDeleted: false
            ),
        ],
        onDismiss: {},
        onConfirm: { _ in }
    )
}
