import SwiftUI
import GRDB

// MARK: - Filter Type

/// Filter options for the parent task selector in the Subtask Derivation Engine.
private enum DerivationFilter: String, CaseIterable {
    case all = "All"
    case counting = "Counting"
    case progress = "Progress"
    case composite = "Composite"
}

// MARK: - Subtask Derivation Playground

/// Subtask Derivation Engine Playground.
///
/// Lets users select a parent task from the task library and inspect what subtasks
/// can be derived from it. Counting tasks support partial-count allocation and
/// one-tap subtask creation. Progress tasks support per-step extraction into the
/// task library. Composite tasks are displayed read-only.
///
/// - Normal tasks: Shown as not subdivisible.
/// - Counting tasks: Uses `CountingDerivationPanelView` for partial count allocation with a
///   live title preview and a "Create Subtask" button that writes the new task to the database.
/// - Progress tasks: Uses `ProgressDerivationPanelView` listing each TaskStep with type,
///   linked-task badge, counting detail, and an "Extract as Task" button for unlinked steps.
/// - Composite tasks: Uses `CompositeDerivationPanelView` showing operator type and leaf nodes.
struct SubtaskDerivationPlayground: View {
    // MARK: - State

    @State private var tasks: [Task] = []
    @State private var compositeTasks: [CompositeTask] = []
    @State private var selectedTaskId: String? = nil
    @State private var selectedCompositeTaskId: String? = nil
    @State private var filterType: DerivationFilter = .all
    @State private var partialCountStr: String = ""

    // Derived state for the selected task's steps / nodes
    @State private var taskSteps: [TaskStep] = []
    @State private var compositeNodes: [CompositeNode] = []

    // Error / success state
    @State private var loadError: String? = nil
    @State private var creationSuccess: String? = nil
    @State private var isCreating: Bool = false

    // Board Task Pool
    @State private var boardPool: [(taskId: String, title: String, type: String)] = []

    // MARK: - Computed

    /// The currently selected regular task (nil when a composite is selected or nothing is selected).
    private var selectedTask: Task? {
        guard let id = selectedTaskId else { return nil }
        return tasks.first(where: { $0.id == id })
    }

    /// The currently selected composite task (nil when a regular task is selected or nothing is selected).
    private var selectedCompositeTask: CompositeTask? {
        guard let id = selectedCompositeTaskId else { return nil }
        return compositeTasks.first(where: { $0.id == id })
    }

    /// Tasks visible after applying the current filter, excluding composite (those appear separately).
    private var filteredTasks: [Task] {
        switch filterType {
        case .all:       return tasks
        case .counting:  return tasks.filter { $0.type == .counting }
        case .progress:  return tasks.filter { $0.type == .progress }
        case .composite: return []
        }
    }

    /// Composite tasks visible after applying the current filter.
    private var filteredCompositeTasks: [CompositeTask] {
        switch filterType {
        case .all, .composite: return compositeTasks
        case .counting, .progress: return []
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // ── Success banner ──
            if let success = creationSuccess {
                Text(success)
                    .font(.subheadline)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.15))
                    .foregroundColor(.green)
                    .cornerRadius(8)
            }

            // ── Section: Parent Task Selector ──
            VStack(alignment: .leading, spacing: 10) {
                Text("Select Parent Task")
                    .font(.headline)

                // Filter picker
                Picker("Filter", selection: $filterType) {
                    ForEach(DerivationFilter.allCases, id: \.self) { f in
                        Text(f.rawValue).tag(f)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: filterType) {
                    // Clear selection when filter changes to avoid stale state
                    clearSelection()
                }

                if let error = loadError {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }

                if filteredTasks.isEmpty && filteredCompositeTasks.isEmpty {
                    Text("No tasks found — create some in the Task Creation playground first.")
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                } else {
                    // Regular tasks — derivation panel appears inline below selected task
                    ForEach(filteredTasks, id: \.id) { task in
                        taskSelectorRow(task)
                        if selectedTaskId == task.id {
                            derivationPanel
                                .padding(.leading, 8)
                                .transition(.opacity)
                        }
                    }

                    // Composite tasks — derivation panel appears inline below selected composite
                    ForEach(filteredCompositeTasks, id: \.id) { ct in
                        compositeSelectorRow(ct)
                        if selectedCompositeTaskId == ct.id {
                            CompositeDerivationPanelView(
                                compositeTask: ct,
                                compositeNodes: compositeNodes,
                                tasks: tasks,
                                compositeTasks: compositeTasks,
                                boardPool: boardPool,
                                onAddLeafToPool: { taskId, title, type in
                                    addToPool(taskId: taskId, title: title, type: type)
                                    showSuccess("Added to board pool: \"\(title)\"")
                                }
                            )
                            .padding(.leading, 8)
                            .transition(.opacity)
                        }
                    }
                }
            }

            // ── Board Task Pool ──
            Divider()
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("Board Task Pool")
                        .font(.headline)
                    if !boardPool.isEmpty {
                        Text("\(boardPool.count)")
                            .font(.caption)
                            .fontWeight(.bold)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.accentColor)
                            .foregroundColor(.white)
                            .cornerRadius(10)
                    }
                }

                if boardPool.isEmpty {
                    Text("No tasks in the pool yet. Use the buttons above to add subtasks.")
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                } else {
                    ForEach(boardPool, id: \.taskId) { entry in
                        HStack(spacing: 8) {
                            Text(entry.title)
                                .font(.system(size: 13))
                                .lineLimit(1)
                                .frame(maxWidth: .infinity, alignment: .leading)
                            TypeBadgeView(type: entry.type, size: .small)
                            Button {
                                boardPool.removeAll { $0.taskId == entry.taskId }
                            } label: {
                                Image(systemName: "xmark")
                                    .font(.system(size: 11, weight: .semibold))
                                    .foregroundColor(.secondary)
                                    .frame(width: 24, height: 24)
                                    .background(Color(.systemGray5))
                                    .clipShape(Circle())
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Remove \(entry.title) from pool")
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 8)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                    }

                    Button("Clear Pool") {
                        boardPool.removeAll()
                    }
                    .font(.caption)
                    .foregroundColor(.red)
                }
            }
        }
        .onAppear {
            ensurePlaygroundUser()
            loadTasks()
        }
    }

    // MARK: - Selector Rows

    /// A tappable row for selecting a regular task as the parent.
    ///
    /// - Parameter task: The Task to display.
    @ViewBuilder
    private func taskSelectorRow(_ task: Task) -> some View {
        let isSelected = selectedTaskId == task.id
        Button {
            selectTask(task)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(.subheadline)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundColor(.primary)
                    if let desc = task.description, !desc.isEmpty {
                        Text(desc)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                TypeBadgeView(type: task.type.rawValue, size: .small)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                        .font(.subheadline)
                }
            }
            .padding(10)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color(.systemGray5))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    /// A tappable row for selecting a composite task as the parent.
    ///
    /// - Parameter ct: The CompositeTask to display.
    @ViewBuilder
    private func compositeSelectorRow(_ ct: CompositeTask) -> some View {
        let isSelected = selectedCompositeTaskId == ct.id
        Button {
            selectCompositeTask(ct)
        } label: {
            HStack {
                VStack(alignment: .leading, spacing: 2) {
                    Text(ct.title)
                        .font(.subheadline)
                        .fontWeight(isSelected ? .semibold : .regular)
                        .foregroundColor(.primary)
                    if let desc = ct.description, !desc.isEmpty {
                        Text(desc)
                            .font(.caption)
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer()
                TypeBadgeView(type: "composite", size: .small)
                if isSelected {
                    Image(systemName: "checkmark.circle.fill")
                        .foregroundColor(.accentColor)
                        .font(.subheadline)
                }
            }
            .padding(10)
            .background(isSelected ? Color.accentColor.opacity(0.1) : Color(.systemGray5))
            .cornerRadius(8)
        }
        .buttonStyle(.plain)
    }

    // MARK: - Derivation Panel

    /// The derivation panel, rendered differently based on the selected task type.
    @ViewBuilder
    private var derivationPanel: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Derivation Panel")
                .font(.headline)

            if let task = selectedTask {
                switch task.type {
                case .normal:
                    normalDerivationPanel(task)
                case .counting:
                    CountingDerivationPanelView(
                        task: task,
                        partialCountStr: $partialCountStr,
                        isCreating: isCreating,
                        onCreateSubtask: { parentTask, count in
                            createCountingSubtask(from: parentTask, count: count)
                        }
                    )
                case .progress:
                    ProgressDerivationPanelView(
                        task: task,
                        taskSteps: taskSteps,
                        allTasks: tasks,
                        boardPool: boardPool,
                        isCreating: isCreating,
                        onExtractStep: { step, parentTask in
                            extractStepAsTask(step: step, parentTask: parentTask)
                        },
                        onAddStepToPool: { linkedTask in
                            addToPool(taskId: linkedTask.id, title: linkedTask.title, type: linkedTask.type.rawValue)
                            showSuccess("Added to board pool: \"\(linkedTask.title)\"")
                        }
                    )
                case .compound:
                    // Compound task derivation lives in a dedicated Phase 5
                    // playground (CompoundTaskPlayground). This legacy
                    // playground predates the unification — stays focused on
                    // primitives.
                    Text("Compound tasks aren't handled by this playground — use CompoundTaskPlayground.")
                        .font(.footnote)
                        .foregroundColor(.secondary)
                }
            }
        }
    }

    /// Panel shown for normal tasks — not subdivisible.
    ///
    /// - Parameter task: The selected normal Task.
    @ViewBuilder
    private func normalDerivationPanel(_ task: Task) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text(task.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                TypeBadgeView(type: task.type.rawValue, size: .small)
            }

            Text("Normal tasks cannot be subdivided.")
                .font(.body)
                .foregroundColor(.secondary)
                .padding(.vertical, 4)
        }
        .padding(12)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }

    // MARK: - Actions

    /// Sets the selected task and clears any composite selection, then loads its steps.
    ///
    /// - Parameter task: The Task the user tapped.
    private func selectTask(_ task: Task) {
        selectedTaskId = task.id
        selectedCompositeTaskId = nil
        partialCountStr = ""
        compositeNodes = []
        taskSteps = []

        if task.type == .progress {
            loadSteps(for: task.id)
        }
    }

    /// Sets the selected composite task and clears any regular task selection, then loads its nodes.
    ///
    /// - Parameter ct: The CompositeTask the user tapped.
    private func selectCompositeTask(_ ct: CompositeTask) {
        selectedCompositeTaskId = ct.id
        selectedTaskId = nil
        partialCountStr = ""
        taskSteps = []
        compositeNodes = []
        loadNodes(for: ct.id)
    }

    /// Clears both selection states and all derived data.
    private func clearSelection() {
        selectedTaskId = nil
        selectedCompositeTaskId = nil
        partialCountStr = ""
        taskSteps = []
        compositeNodes = []
    }

    /// Loads all non-deleted tasks and composite tasks for the playground user.
    private func loadTasks() {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let fetched = try AppDatabase.shared.fetchTasks(userId: playgroundUserId)
                let composites = try AppDatabase.shared.read { db in
                    try CompositeTask
                        .filter(Column("userId") == playgroundUserId && Column("isDeleted") == false)
                        .order(Column("title"))
                        .fetchAll(db)
                }
                DispatchQueue.main.async {
                    self.tasks = fetched
                    self.compositeTasks = composites
                    self.loadError = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.loadError = "Failed to load tasks: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Loads TaskStep records for a given progress task, ordered by stepIndex.
    ///
    /// - Parameter taskId: The parent task ID.
    private func loadSteps(for taskId: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let steps = try AppDatabase.shared.fetchTaskSteps(taskId: taskId)
                DispatchQueue.main.async {
                    self.taskSteps = steps
                    self.loadError = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.loadError = "Failed to load steps: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Loads CompositeNode records for a given composite task.
    ///
    /// - Parameter compositeTaskId: The composite task ID.
    private func loadNodes(for compositeTaskId: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let nodes = try AppDatabase.shared.read { db in
                    try CompositeNode
                        .filter(Column("compositeTaskId") == compositeTaskId && Column("isDeleted") == false)
                        .fetchAll(db)
                }
                DispatchQueue.main.async {
                    self.compositeNodes = nodes
                    self.loadError = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.loadError = "Failed to load composite nodes: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Creation Actions

    /// Creates a new counting subtask in the task library derived from the selected parent task.
    ///
    /// Uses `count` as the `maxCount` for the new task. The title is auto-generated
    /// following the `generateCounterTaskTitle` convention: "\(action) \(count) \(unit)".
    /// Clears the partial count field and refreshes the task library on success.
    ///
    /// - Parameters:
    ///   - parentTask: The counting Task from which the subtask is derived.
    ///   - count: The validated partial count provided by `CountingDerivationPanelView`.
    private func createCountingSubtask(from parentTask: Task, count: Int) {
        guard let action = parentTask.action,
              let unit = parentTask.unit else { return }

        isCreating = true
        let title = "\(action) \(count) \(unit)"
        let now = ISO8601DateFormatter().string(from: Date())

        let newTask = Task(
            id: UUID().uuidString,
            userId: playgroundUserId,
            title: title,
            description: "Subtask of \"\(parentTask.title)\"",
            type: .counting,
            action: action,
            unit: unit,
            maxCount: count,
            totalCompletions: 0,
            totalInstances: 0,
            createdAt: now,
            updatedAt: now,
            version: 1,
            isDeleted: false
        )

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try AppDatabase.shared.saveTask(newTask)
                DispatchQueue.main.async {
                    self.isCreating = false
                    self.addToPool(taskId: newTask.id, title: title, type: TaskType.counting.rawValue)
                    self.showSuccess("Added to board pool: \"\(title)\"")
                    self.partialCountStr = ""
                    self.loadTasks()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isCreating = false
                    self.loadError = "Failed to create subtask: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Extracts a progress task step into a standalone task in the library and links them.
    ///
    /// Creates a new Task whose type, action, unit, and maxCount mirror the step, then
    /// updates the step's `linkedTaskId` to point at the new task in a single transaction.
    /// Refreshes both the task library and the step list for the parent task on success.
    ///
    /// - Parameters:
    ///   - step: The TaskStep to extract.
    ///   - parentTask: The progress Task that owns the step (used for the description and
    ///     for refreshing steps after the write).
    private func extractStepAsTask(step: TaskStep, parentTask: Task) {
        isCreating = true
        let now = ISO8601DateFormatter().string(from: Date())

        let newTask = Task(
            id: UUID().uuidString,
            userId: playgroundUserId,
            title: step.title,
            description: "Step from \"\(parentTask.title)\"",
            type: step.type,
            action: step.action,
            unit: step.unit,
            maxCount: step.maxCount,
            totalCompletions: 0,
            totalInstances: 0,
            createdAt: now,
            updatedAt: now,
            version: 1,
            isDeleted: false
        )

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try AppDatabase.shared.write { db in
                    try newTask.save(db)
                    // Link the step to the newly created task in the same transaction
                    try db.execute(
                        sql: "UPDATE \(TaskStep.databaseTableName) SET linkedTaskId = ?, updatedAt = ? WHERE id = ?",
                        arguments: [newTask.id, now, step.id]
                    )
                }
                DispatchQueue.main.async {
                    self.isCreating = false
                    self.addToPool(taskId: newTask.id, title: newTask.title, type: newTask.type.rawValue)
                    self.showSuccess("Added to board pool: \"\(newTask.title)\"")
                    self.loadTasks()
                    self.loadSteps(for: parentTask.id)
                }
            } catch {
                DispatchQueue.main.async {
                    self.isCreating = false
                    self.loadError = "Failed to extract step: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Shows a success banner that auto-dismisses after `successDismissSeconds`.
    ///
    /// If a newer message replaces this one before the timer fires, the old dismiss
    /// closure is a no-op (guarded by message equality).
    ///
    /// - Parameter message: The success string to display.
    private func showSuccess(_ message: String) {
        creationSuccess = message
        DispatchQueue.main.asyncAfter(deadline: .now() + successDismissSeconds) {
            if self.creationSuccess == message {
                self.creationSuccess = nil
            }
        }
    }

    /// Adds a task to the board pool. Skips duplicates.
    private func addToPool(taskId: String, title: String, type: String) {
        guard !boardPool.contains(where: { $0.taskId == taskId }) else { return }
        boardPool.append((taskId: taskId, title: title, type: type))
    }
}
