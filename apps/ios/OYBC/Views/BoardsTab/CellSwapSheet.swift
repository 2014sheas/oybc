import SwiftUI

// MARK: - CellSwapSheet

/// Task-picker sheet for the live-edit cell swap (M3).
///
/// Displays the user's full task library filtered to types eligible for a
/// non-center square (NORMAL / COUNTING / COMPOUND / ACHIEVEMENT), excluding
/// the Task currently occupying the square being swapped.
///
/// UX mirrors the web `CellSwapModal`:
///   - Search field filters by title (case-insensitive substring).
///   - Single-select list row; selected row gets a checkmark.
///   - "Swap" button is disabled until a task is chosen.
///   - Tapping the same row again deselects (no forced selection).
///
/// The caller is responsible for:
///   - Providing `candidateTasks` filtered to non-deleted tasks for the user.
///   - Calling `onConfirm(newTaskId:)` to write the swap (the sheet does NOT
///     write to the database itself).
///
/// - Parameters:
///   - currentTaskId: The Task currently in the square (excluded from the list).
///   - candidateTasks: All non-deleted tasks in the user's library.
///   - onDismiss: Called when the user cancels without selecting.
///   - onConfirm: Called with the chosen Task's id.
struct CellSwapSheet: View {

    // MARK: - Parameters

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
            guard task.id != currentTaskId else { return false }
            guard eligibleTypes.contains(task.type) else { return false }
            if query.trimmingCharacters(in: .whitespaces).isEmpty { return true }
            return task.title.localizedCaseInsensitiveContains(query)
        }
        .sorted { $0.title.localizedCompare($1.title) == .orderedAscending }
    }

    // MARK: - Body

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                // ── Search ──
                searchBar
                    .padding(.horizontal)
                    .padding(.top, 8)
                    .padding(.bottom, 4)

                Divider()

                // ── Task list ──
                if filtered.isEmpty {
                    Spacer()
                    Text(query.trimmingCharacters(in: .whitespaces).isEmpty
                         ? "No eligible tasks found."
                         : "No tasks match your search.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                        .multilineTextAlignment(.center)
                        .padding()
                    Spacer()
                } else {
                    List(filtered, id: \.id) { task in
                        taskRow(task)
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Swap with another task…")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onDismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Swap") {
                        if let id = selectedTaskId {
                            onConfirm(id)
                        }
                    }
                    .disabled(selectedTaskId == nil)
                    .fontWeight(.semibold)
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    // MARK: - Subviews

    private var searchBar: some View {
        HStack {
            Image(systemName: "magnifyingglass")
                .foregroundColor(.secondary)
            TextField("Search tasks…", text: $query)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundColor(.secondary)
                }
                .buttonStyle(.plain)
            }
        }
        .padding(8)
        .background(Color(.secondarySystemBackground))
        .cornerRadius(10)
    }

    @ViewBuilder
    private func taskRow(_ task: Task) -> some View {
        let isSelected = task.id == selectedTaskId
        Button {
            selectedTaskId = isSelected ? nil : task.id
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .foregroundColor(.primary)
                        .font(.body)
                    Text(taskTypeLabel(task.type))
                        .foregroundColor(.secondary)
                        .font(.caption)
                }
                Spacer()
                if isSelected {
                    Image(systemName: "checkmark")
                        .foregroundColor(.accentColor)
                        .fontWeight(.semibold)
                }
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }

    // MARK: - Helpers

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
