import SwiftUI
import GRDB

/// Task detail page — full per-task surface with stats, an inline edit
/// sheet, and a cascade delete action. iOS twin of web's
/// `TaskDetailPage.tsx`.
///
/// V1 edit scope: title + description + scalar type-specific fields
/// (counting: action/unit/maxCount; achievement: trigger/requiredCount).
/// Compound subtasks are edited from the board-creation wizard.
struct TaskDetailView: View {
    let taskId: String
    let userId: String
    let onChanged: () -> Void
    let onDeleted: () -> Void

    @State private var task: Task?
    @State private var placements: [BoardTask] = []
    @State private var affectedBoards: [Board] = []
    @State private var loadError: String?
    @State private var saveError: String?

    @State private var showEditSheet: Bool = false
    @State private var showDeleteConfirm: Bool = false
    @State private var deleteImpact: AppDatabase.TaskDeletionImpact?

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                if let loadError {
                    Text(loadError)
                        .foregroundColor(.red)
                } else if let task {
                    titleSection(task)
                    typeSpecificSection(task)
                    usageSection(task)
                    timestampSection(task)
                    if let saveError {
                        Text(saveError)
                            .font(.system(size: 13))
                            .foregroundColor(.red)
                    }
                    actions
                } else {
                    Text("Loading…").foregroundColor(.secondary)
                }
            }
            .padding(16)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .navigationTitle("")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            // Reads off the main thread so a task with many placements
            // doesn't hitch the UI. The `await MainActor.run` inside
            // `reload()` republishes the resulting state back on the
            // main thread before SwiftUI observes the change.
            _Concurrency.Task { await reload() }
        }
        .sheet(isPresented: $showEditSheet) {
            if let task {
                editSheet(task)
            }
        }
        .alert("Delete task?", isPresented: $showDeleteConfirm, presenting: deleteImpact) { _ in
            Button("Cancel", role: .cancel) {
                deleteImpact = nil
            }
            Button("Delete", role: .destructive) {
                performDelete()
            }
        } message: { impact in
            Text(deleteConfirmMessage(impact: impact))
        }
    }

    // MARK: - Reload

    private func reload() async {
        do {
            // GRDB reads block their calling thread; keep them off the
            // main thread so SwiftUI doesn't hitch when a task has
            // many placements. The hop back to the main actor below
            // republishes state before the view observes it.
            let snapshot = try await _Concurrency.Task.detached(priority: .userInitiated) {
                let loaded = try AppDatabase.shared.fetchTask(id: taskId)
                var bts: [BoardTask] = []
                var boards: [Board] = []
                if let loaded = loaded, !loaded.isDeleted {
                    bts = try AppDatabase.shared.fetchBoardTasksForTask(taskId: taskId)
                    let boardIds = Array(Set(bts.map { $0.boardId }))
                    boards = try AppDatabase.shared.fetchBoards(ids: boardIds)
                }
                return (loaded, bts, boards)
            }.value
            await MainActor.run {
                self.task = snapshot.0
                self.placements = snapshot.1
                self.affectedBoards = snapshot.2
                self.loadError = nil
            }
        } catch {
            let message = "Failed to load task: \(error.localizedDescription)"
            await MainActor.run { self.loadError = message }
        }
    }

    // MARK: - Sections

    @ViewBuilder
    private func titleSection(_ task: Task) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(task.title.isEmpty ? "(untitled task)" : task.title)
                .font(.largeTitle)
                .fontWeight(.bold)
            HStack(spacing: 8) {
                TypeBadgeView(type: typeLabel(task))
                statusPill(task)
            }
            if let desc = task.description, !desc.isEmpty {
                Text(desc)
                    .font(.system(size: 15))
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private func typeSpecificSection(_ task: Task) -> some View {
        switch task.type {
        case .counting:
            section(title: "COUNTING") {
                if let action = task.action, let unit = task.unit, let max = task.maxCount {
                    let current = task.currentCount ?? 0
                    Text("\(action) · \(current) / \(max) \(unit)")
                        .font(.system(size: 14))
                    if max > 0 {
                        ProgressView(value: Double(min(current, max)), total: Double(max))
                    }
                } else {
                    Text("Incomplete counting fields.")
                        .foregroundColor(.secondary)
                }
            }
        case .achievement:
            section(title: "ACHIEVEMENT") {
                let trigger = task.achievementTrigger ?? .greenlog
                Text("Trigger: \(trigger == .bingo ? "Bingo" : "Greenlog")")
                    .font(.system(size: 14))
                if let boardId = task.referencedBoardId {
                    Text("Watches board: \(boardId)")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                }
                if let tplId = task.referencedTemplateId {
                    Text("Watches template: \(tplId)")
                        .font(.system(size: 13))
                        .foregroundColor(.secondary)
                    if let req = task.requiredCount {
                        Text("Required spawns: \(req)")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                }
            }
        case .compound, .normal:
            EmptyView()
        }
    }

    @ViewBuilder
    private func usageSection(_ task: Task) -> some View {
        section(title: "USAGE") {
            Text("Total completions: \(task.totalCompletions)")
                .font(.system(size: 14))
            if affectedBoards.isEmpty {
                Text("Not placed on any board yet.")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            } else {
                ForEach(affectedBoards, id: \.id) { board in
                    NavigationLink(value: board.id) {
                        HStack(spacing: 6) {
                            Text(board.name)
                                .foregroundColor(.blue)
                            Text(board.status.rawValue.uppercased())
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundColor(.secondary)
                        }
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }

    @ViewBuilder
    private func timestampSection(_ task: Task) -> some View {
        section(title: "TIMESTAMPS") {
            Text("Created: \(formatDate(task.createdAt))")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            Text("Updated: \(formatDate(task.updatedAt))")
                .font(.system(size: 13))
                .foregroundColor(.secondary)
            if let completedAt = task.completedAt {
                Text("Completed: \(formatDate(completedAt))")
                    .font(.system(size: 13))
                    .foregroundColor(.secondary)
            }
        }
    }

    @ViewBuilder
    private var actions: some View {
        HStack(spacing: 12) {
            Button {
                showEditSheet = true
            } label: {
                Text("Edit")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.blue)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
            Button {
                prepareDelete()
            } label: {
                Text("Delete")
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 10)
                    .background(Color.red)
                    .foregroundColor(.white)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            }
        }
        .padding(.top, 8)
    }

    // MARK: - Helpers

    private func typeLabel(_ task: Task) -> String {
        if task.type == .compound {
            return task.isOrdered == true ? "progress" : "composite"
        }
        return task.type.rawValue
    }

    @ViewBuilder
    private func section<Content: View>(title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title)
                .font(.system(size: 11, weight: .bold))
                .foregroundColor(.secondary)
            content()
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color(.secondarySystemBackground))
        .clipShape(RoundedRectangle(cornerRadius: 8))
    }

    @ViewBuilder
    private func statusPill(_ task: Task) -> some View {
        if task.isCompleted {
            pillView(text: "Completed", color: .green)
        } else if task.type == .counting, (task.currentCount ?? 0) > 0 {
            pillView(text: "In progress", color: .orange)
        } else {
            pillView(text: "Never started", color: .gray)
        }
    }

    @ViewBuilder
    private func pillView(text: String, color: Color) -> some View {
        Text(text)
            .font(.system(size: 12, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(color)
            .clipShape(Capsule())
    }

    private func formatDate(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        if let date = formatter.date(from: iso) {
            let display = DateFormatter()
            display.dateStyle = .medium
            display.timeStyle = .short
            return display.string(from: date)
        }
        return iso
    }

    // MARK: - Edit sheet

    @ViewBuilder
    private func editSheet(_ task: Task) -> some View {
        EditTaskSheet(
            task: task,
            onSubmit: { patch in
                saveEdits(patch: patch)
            },
            onCancel: {
                showEditSheet = false
            }
        )
    }

    private func saveEdits(patch: EditTaskSheet.Patch) {
        guard var t = task else { return }
        t.title = patch.title.trimmingCharacters(in: .whitespacesAndNewlines)
        t.description = patch.description.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            ? nil
            : patch.description.trimmingCharacters(in: .whitespacesAndNewlines)
        if t.type == .counting {
            if !patch.action.isEmpty { t.action = patch.action }
            if !patch.unit.isEmpty { t.unit = patch.unit }
            if let max = Int(patch.maxCountStr), max > 0 { t.maxCount = max }
        }
        if t.type == .achievement {
            t.achievementTrigger = patch.trigger
            if t.referencedTemplateId != nil {
                if let req = Int(patch.requiredCountStr), req > 0 { t.requiredCount = req }
            }
        }
        t.updatedAt = AppDatabase.currentTimestamp()
        t.version += 1

        do {
            // Atomic: save + enqueue in one transaction so a crash
            // between can't leave local state out of sync with the
            // sync queue (CLAUDE.md "atomic pull-path multi-writes").
            try AppDatabase.shared.saveTaskAndEnqueueUpdate(t)
            task = t
            saveError = nil
            showEditSheet = false
            onChanged()
        } catch {
            saveError = "Failed to save: \(error.localizedDescription)"
        }
    }

    // MARK: - Delete cascade

    private func prepareDelete() {
        do {
            let impact = try AppDatabase.shared.computeTaskDeletionImpact(taskId: taskId)
            deleteImpact = impact
            showDeleteConfirm = true
        } catch {
            saveError = "Failed to compute delete impact: \(error.localizedDescription)"
        }
    }

    private func performDelete() {
        do {
            try AppDatabase.shared.deleteTaskWithCascade(taskId: taskId)
            onDeleted()
        } catch {
            saveError = "Failed to delete: \(error.localizedDescription)"
        }
    }

    private func deleteConfirmMessage(impact: AppDatabase.TaskDeletionImpact) -> String {
        var lines: [String] = ["This can’t be undone."]
        if impact.boardTaskCount > 0 {
            lines.append(
                "Removes from \(impact.boardTaskCount) board square\(impact.boardTaskCount == 1 ? "" : "s") across \(impact.affectedBoardIds.count) board\(impact.affectedBoardIds.count == 1 ? "" : "s").",
            )
        }
        if impact.childLinkCount > 0 {
            lines.append(
                "Detaches from \(impact.childLinkCount) compound parent\(impact.childLinkCount == 1 ? "" : "s").",
            )
        }
        if impact.parentLinkCount > 0 {
            lines.append(
                "Releases \(impact.parentLinkCount) subtask\(impact.parentLinkCount == 1 ? "" : "s") (subtasks stay in your library).",
            )
        }
        return lines.joined(separator: "\n")
    }
}

/// Inline edit form for the detail page. Kept private to the file
/// because its shape is specific to the V1 edit scope; it's not a
/// general-purpose component.
private struct EditTaskSheet: View {
    let task: Task
    let onSubmit: (Patch) -> Void
    let onCancel: () -> Void

    struct Patch {
        var title: String
        var description: String
        var action: String
        var unit: String
        var maxCountStr: String
        var trigger: AchievementTrigger
        var requiredCountStr: String
    }

    @State private var title: String
    @State private var description: String
    @State private var action: String
    @State private var unit: String
    @State private var maxCountStr: String
    @State private var trigger: AchievementTrigger
    @State private var requiredCountStr: String

    init(task: Task, onSubmit: @escaping (Patch) -> Void, onCancel: @escaping () -> Void) {
        self.task = task
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _title = State(initialValue: task.title)
        _description = State(initialValue: task.description ?? "")
        _action = State(initialValue: task.action ?? "")
        _unit = State(initialValue: task.unit ?? "")
        _maxCountStr = State(initialValue: task.maxCount.map { String($0) } ?? "")
        _trigger = State(initialValue: task.achievementTrigger ?? .greenlog)
        _requiredCountStr = State(initialValue: task.requiredCount.map { String($0) } ?? "")
    }

    var body: some View {
        NavigationStack {
            Form {
                Section("Title") {
                    TextField("Title", text: $title)
                }
                Section("Description") {
                    TextField("Description", text: $description, axis: .vertical)
                        .lineLimit(3, reservesSpace: true)
                }
                if task.type == .counting {
                    Section("Counting") {
                        TextField("Action (e.g. Run)", text: $action)
                        TextField("Max count", text: $maxCountStr)
                            .keyboardType(.numberPad)
                        TextField("Unit (e.g. miles)", text: $unit)
                    }
                }
                if task.type == .achievement {
                    Section("Achievement") {
                        Picker("Trigger", selection: $trigger) {
                            Text("Greenlog").tag(AchievementTrigger.greenlog)
                            Text("Bingo").tag(AchievementTrigger.bingo)
                        }
                        if task.referencedTemplateId != nil {
                            TextField("Required count", text: $requiredCountStr)
                                .keyboardType(.numberPad)
                        }
                    }
                }
                if task.type == .compound {
                    Section {
                        Text("Compound subtasks are edited from the board-creation wizard. The title and description can still be changed here.")
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                    }
                }
            }
            .navigationTitle("Edit task")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { onCancel() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Save") {
                        onSubmit(
                            Patch(
                                title: title,
                                description: description,
                                action: action,
                                unit: unit,
                                maxCountStr: maxCountStr,
                                trigger: trigger,
                                requiredCountStr: requiredCountStr,
                            )
                        )
                    }
                    .disabled(title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                }
            }
        }
    }
}
