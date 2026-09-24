import SwiftUI

/// The compound editor's "+ Existing task…" sheet: a Riso search bar over
/// the eligible library tasks and one row per task (type letter badge +
/// title). Tapping a row hands the task to `onPick`; the host appends it as
/// a linked sub-task (`ChildPatch(from:)`) and dismisses.
///
/// Presented from `RisoCompoundEditFieldsView`, so both the wizard's inline
/// row editor and the Task Detail `EditTaskSheet` get it. `tasks` is the
/// ELIGIBLE list already (`CompoundChildEligibility.pickerCandidates`) —
/// this view only searches and lists. Web twin: `ExistingTaskPicker.tsx`.
struct RisoExistingTaskPickerSheet: View {

    /// Whether the caller's candidate list has arrived (Task Detail loads it
    /// on open; the wizard already holds it). Twin of web `PickerInputsState`.
    enum InputsState: Equatable {
        case loading, loaded, failed
    }

    let tasks: [Task]
    let status: InputsState
    let onPick: (Task) -> Void
    let onCancel: () -> Void

    @State private var searchQuery: String

    /// - Parameters:
    ///   - tasks: The eligible candidates.
    ///   - status: Candidate-list load state; rows show only once `.loaded`.
    ///   - initialQuery: Seeds the search field (snapshot fixtures).
    ///   - onPick: A row was chosen.
    ///   - onCancel: The sheet was cancelled.
    init(
        tasks: [Task],
        status: InputsState = .loaded,
        initialQuery: String = "",
        onPick: @escaping (Task) -> Void,
        onCancel: @escaping () -> Void
    ) {
        self.tasks = tasks
        self.status = status
        self.onPick = onPick
        self.onCancel = onCancel
        _searchQuery = State(initialValue: initialQuery)
    }

    private var visibleTasks: [Task] {
        CompoundChildEligibility.searchCandidates(tasks, query: searchQuery)
    }

    var body: some View {
        NavigationStack {
            VStack(spacing: 0) {
                searchBar
                ScrollView {
                    LazyVStack(spacing: 7) {
                        let rows = visibleTasks
                        if status == .loading {
                            statusLine("Loading your tasks…", color: .risoMuted)
                        } else if status == .failed {
                            statusLine("Couldn't load your tasks. Close and reopen the editor to try again.", color: .risoRed)
                        } else if rows.isEmpty {
                            statusLine(tasks.isEmpty ? "No tasks can be added to this compound." : "No matching tasks.", color: .risoMuted)
                        } else {
                            ForEach(rows, id: \.id) { task in row(task) }
                        }
                    }
                    .padding(16)
                }
                .background(Color.risoPaper)
            }
            .background(Color.risoPaper.ignoresSafeArea())
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Text("Add an existing task")
                        .font(.risoHead(17, .extraBold))
                        .foregroundStyle(Color.risoInk)
                }
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                        .font(.risoBody(15, .semibold))
                        .foregroundStyle(Color.risoMuted)
                }
            }
        }
    }

    private func statusLine(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.risoBody(13, .semibold))
            .foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 8)
    }

    private var searchBar: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 15, weight: .medium))
                .foregroundStyle(Color.risoMuted)
            TextField("Search your tasks", text: $searchQuery)
                .font(.risoHead(15, .bold))
                .foregroundStyle(Color.risoInk)
                .tint(Color.risoBlue)
                .accessibilityLabel("Search tasks")
            if !searchQuery.isEmpty {
                Button { searchQuery = "" } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(Color.risoMuted)
                        .risoHitSlop(6)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear search")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(Color.risoPaper2)
        .overlay(
            Rectangle().fill(Color.risoInk).frame(height: Riso.Keyline.container),
            alignment: .bottom
        )
    }

    private func row(_ task: Task) -> some View {
        Button { onPick(task) } label: {
            HStack(spacing: 9) {
                RisoTypeBadge(kind: RisoTaskKind(taskType: task.type), style: .letterSquare)
                Text(task.title)
                    .font(.risoHead(14, .bold))
                    .foregroundStyle(Color.risoInk)
                    .lineLimit(1)
                    .truncationMode(.tail)
                Spacer(minLength: 4)
                Text("＋")
                    .font(.risoHead(15, .extraBold))
                    .foregroundStyle(Color.risoInk)
            }
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .frame(maxWidth: .infinity, minHeight: 44, alignment: .leading)
            .risoCard(fill: .risoPaper2)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Add \(task.title)")
    }
}
