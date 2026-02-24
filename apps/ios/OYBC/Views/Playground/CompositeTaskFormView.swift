import SwiftUI
import GRDB

// MARK: - Local Form Types

/// Whether a subtask slot references an existing task/composite or creates inline.
enum SubtaskMode {
    case existing
    case inline_
}

/// Type options for inline subtask creation (composite NOT included — must be created separately).
enum InlineSubtaskType: String, CaseIterable, Identifiable {
    case normal = "Normal"
    case counting = "Counting"
    case progress = "Progress"
    var id: String { rawValue }
}

/// A single mutable subtask slot in the flat list.
class SubtaskItem: ObservableObject, Identifiable {
    let id = UUID()

    // Mode
    @Published var mode: SubtaskMode

    // Existing mode — exactly one of these is set
    @Published var selectionType: SelectionType = .task
    @Published var selectedTaskId: String = ""
    @Published var selectedCompositeId: String = ""

    // Inline mode
    @Published var inlineType: InlineSubtaskType = .normal
    @Published var inlineTitle: String = ""
    // Counting fields
    @Published var inlineAction: String = ""
    @Published var inlineUnit: String = ""
    @Published var inlineMaxCountStr: String = ""
    // Progress steps
    @Published var inlineSteps: [ProgressStepFormState] = []

    enum SelectionType {
        case task
        case composite
    }

    /// Creates a new subtask slot with the given mode.
    ///
    /// - Parameter mode: Whether the slot references existing data or creates inline.
    init(mode: SubtaskMode = .existing) {
        self.mode = mode
    }
}

// MARK: - CompositeTaskFormView

/// Form view for creating composite tasks in the Playground.
///
/// Replaces the recursive tree builder with a flat, depth-1 subtask list.
/// Supports existing task/composite selection and inline task creation.
/// Also renders a read-only library of existing composite tasks below the form.
struct CompositeTaskFormView: View {
    // MARK: - Form State

    @State private var compositeTitle = ""
    @State private var operatorType: OperatorType = .and
    @State private var threshold: Int = 2
    @State private var subtasks: [SubtaskItem] = []

    // MARK: - Validation State

    @State private var titleError: String?
    @State private var subtasksError: String?

    // MARK: - Feedback State

    @State private var isSubmitting = false
    @State private var successMessage: String?
    @State private var errorMessage: String?

    // MARK: - Library State

    @State private var libraryTasks: [OYBC.Task] = []
    @State private var libraryCompositeTasks: [CompositeTask] = []

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            creationForm
        }
        .onAppear {
            ensurePlaygroundUser()
            loadLibrary()
        }
    }

    // MARK: - Computed Helpers

    /// Task IDs already selected by existing-mode subtasks.
    private var usedTaskIds: Set<String> {
        Set(subtasks.compactMap { item in
            guard item.mode == .existing, item.selectionType == .task,
                  !item.selectedTaskId.isEmpty else { return nil }
            return item.selectedTaskId
        })
    }

    /// Composite IDs already selected by existing-mode subtasks.
    private var usedCompositeIds: Set<String> {
        Set(subtasks.compactMap { item in
            guard item.mode == .existing, item.selectionType == .composite,
                  !item.selectedCompositeId.isEmpty else { return nil }
            return item.selectedCompositeId
        })
    }

    // MARK: - Creation Form

    private var creationForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create Composite Task")
                .font(.headline)

            // Title field
            VStack(alignment: .leading, spacing: 4) {
                TextField("Title (required)", text: $compositeTitle)
                    .textFieldStyle(.roundedBorder)
                HStack {
                    Text("\(compositeTitle.count)/200")
                        .font(.caption)
                        .foregroundColor(compositeTitle.count > 200 ? .red : .secondary)
                    if let error = titleError {
                        Text(error)
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }

            // Operator picker
            VStack(alignment: .leading, spacing: 6) {
                Text("Completion rule")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                Picker("Operator", selection: $operatorType) {
                    Text("All of").tag(OperatorType.and)
                    Text("Any of").tag(OperatorType.or)
                    Text("At least N of").tag(OperatorType.mOfN)
                }
                .pickerStyle(.segmented)

                if operatorType == .mOfN {
                    HStack {
                        Text("Required:")
                        Button("−") {
                            if threshold > 1 { threshold -= 1 }
                        }
                        .buttonStyle(.bordered)
                        Text("\(threshold)")
                            .frame(minWidth: 30)
                        Button("+") {
                            if threshold < subtasks.count { threshold += 1 }
                        }
                        .buttonStyle(.bordered)
                        Text("of \(subtasks.count) subtasks")
                            .foregroundColor(.secondary)
                            .font(.subheadline)
                    }
                }
            }

            // Subtask list
            VStack(alignment: .leading, spacing: 8) {
                Text("Subtasks")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                ForEach(subtasks) { item in
                    SubtaskRowView(
                        item: item,
                        libraryTasks: libraryTasks,
                        libraryCompositeTasks: libraryCompositeTasks,
                        usedTaskIds: usedTaskIds,
                        usedCompositeIds: usedCompositeIds,
                        onRemove: { removeSubtask(item) }
                    )
                }

                if let error = subtasksError {
                    Text(error)
                        .font(.caption)
                        .foregroundColor(.red)
                }

                // Add buttons
                HStack(spacing: 8) {
                    Button("+ Add existing task") {
                        subtasks.append(SubtaskItem(mode: .existing))
                    }
                    .buttonStyle(.bordered)
                    Button("+ Create new task") {
                        let item = SubtaskItem(mode: .inline_)
                        item.inlineSteps = [ProgressStepFormState()]
                        subtasks.append(item)
                    }
                    .buttonStyle(.bordered)
                }
            }

            // Feedback messages
            if let error = errorMessage {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }
            if let success = successMessage {
                Text(success)
                    .foregroundColor(.green)
                    .font(.caption)
            }

            // Submit button
            Button("Create Composite Task") {
                handleCreateCompositeTask()
            }
            .buttonStyle(.borderedProminent)
            .disabled(isSubmitting)
        }
    }

    // MARK: - Library Section

    // MARK: - Actions

    /// Removes a subtask item from the list.
    ///
    /// - Parameter item: The item to remove.
    private func removeSubtask(_ item: SubtaskItem) {
        subtasks.removeAll { $0.id == item.id }
        // Clamp threshold if needed
        if operatorType == .mOfN && threshold > subtasks.count && subtasks.count > 0 {
            threshold = subtasks.count
        }
    }

    // MARK: - Validation

    /// Validates all form fields.
    ///
    /// - Returns: `true` if all fields are valid, `false` otherwise.
    private func validate() -> Bool {
        titleError = nil
        subtasksError = nil

        let trimmedTitle = compositeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmedTitle.isEmpty else {
            titleError = "Title is required"
            return false
        }
        guard trimmedTitle.count <= 200 else {
            titleError = "Title must be 200 characters or less"
            return false
        }
        guard subtasks.count >= 2 else {
            subtasksError = "At least 2 subtasks are required"
            return false
        }

        var seenTaskIds = Set<String>()
        var seenCompositeIds = Set<String>()

        for item in subtasks {
            if item.mode == .existing {
                if item.selectionType == .task {
                    guard !item.selectedTaskId.isEmpty else {
                        subtasksError = "Select a task for all existing subtasks"
                        return false
                    }
                    guard seenTaskIds.insert(item.selectedTaskId).inserted else {
                        subtasksError = "Duplicate subtask — same task added twice"
                        return false
                    }
                } else {
                    guard !item.selectedCompositeId.isEmpty else {
                        subtasksError = "Select a composite for all existing subtasks"
                        return false
                    }
                    guard seenCompositeIds.insert(item.selectedCompositeId).inserted else {
                        subtasksError = "Duplicate subtask — same composite added twice"
                        return false
                    }
                }
            } else {
                if item.inlineType == .counting {
                    guard !item.inlineAction.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        subtasksError = "Counting subtask requires an action"
                        return false
                    }
                    guard !item.inlineUnit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        subtasksError = "Counting subtask requires a unit"
                        return false
                    }
                    guard let maxCount = Int(item.inlineMaxCountStr), maxCount > 0 else {
                        subtasksError = "Counting subtask requires a positive max count"
                        return false
                    }
                } else {
                    guard !item.inlineTitle.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                        subtasksError = "All inline subtasks must have a title"
                        return false
                    }
                }
            }
        }

        if operatorType == .mOfN {
            guard threshold >= 1 && threshold <= subtasks.count else {
                subtasksError = "Threshold must be between 1 and \(subtasks.count)"
                return false
            }
        }

        return true
    }

    // MARK: - Submit Action

    /// Validates the form and writes the composite task (and any inline tasks) in one transaction.
    private func handleCreateCompositeTask() {
        guard validate() else { return }

        isSubmitting = true
        errorMessage = nil

        let now = AppDatabase.currentTimestamp()
        let compositeTaskId = AppDatabase.generateUUID()
        let rootNodeId = AppDatabase.generateUUID()

        let capturedSubtasks = subtasks
        let capturedTitle = compositeTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let capturedOperator = operatorType
        let capturedThreshold = threshold

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try AppDatabase.shared.write { db in
                    // 1. Resolve leaves — create inline tasks where needed
                    var resolvedLeaves: [(taskId: String?, childCompositeTaskId: String?)] = []

                    for item in capturedSubtasks {
                        switch item.mode {
                        case .existing:
                            if item.selectionType == .task {
                                resolvedLeaves.append((taskId: item.selectedTaskId, childCompositeTaskId: nil))
                            } else {
                                resolvedLeaves.append((taskId: nil, childCompositeTaskId: item.selectedCompositeId))
                            }
                        case .inline_:
                            let newTaskId = AppDatabase.generateUUID()
                            let trimmedTitle = item.inlineTitle
                                .trimmingCharacters(in: .whitespacesAndNewlines)
                            let taskType: TaskType
                            switch item.inlineType {
                            case .normal: taskType = .normal
                            case .counting: taskType = .counting
                            case .progress: taskType = .progress
                            }
                            let newTask = OYBC.Task(
                                id: newTaskId,
                                userId: playgroundUserId,
                                title: trimmedTitle.isEmpty ? "Untitled" : trimmedTitle,
                                description: nil,
                                type: taskType,
                                action: item.inlineType == .counting ? item.inlineAction : nil,
                                unit: item.inlineType == .counting ? item.inlineUnit : nil,
                                maxCount: item.inlineType == .counting ? Int(item.inlineMaxCountStr) : nil,
                                totalCompletions: 0,
                                totalInstances: 0,
                                createdAt: now,
                                updatedAt: now,
                                version: 1,
                                isDeleted: false
                            )
                            try newTask.save(db)

                            // Save steps for progress tasks
                            if item.inlineType == .progress {
                                for (stepIndex, step) in item.inlineSteps.enumerated() {
                                    let taskStep = TaskStep(
                                        id: AppDatabase.generateUUID(),
                                        taskId: newTaskId,
                                        stepIndex: stepIndex,
                                        title: step.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                                            ? "Untitled Step" : step.title.trimmingCharacters(in: .whitespacesAndNewlines),
                                        type: step.type == .counting ? .counting : .normal,
                                        action: step.type == .counting ? step.action : nil,
                                        unit: step.type == .counting ? step.unit : nil,
                                        maxCount: step.type == .counting ? Int(step.maxCount) : nil,
                                        linkedTaskId: nil,
                                        createdAt: now,
                                        updatedAt: now,
                                        lastSyncedAt: nil,
                                        version: 1,
                                        isDeleted: false,
                                        deletedAt: nil
                                    )
                                    try taskStep.save(db)
                                }
                            }

                            resolvedLeaves.append((taskId: newTaskId, childCompositeTaskId: nil))
                        }
                    }

                    // 2. Composite task record first — nodes FK to composite_tasks, so
                    //    composite_tasks must exist before any composite_nodes are inserted.
                    //    (rootNodeId has no FK constraint on composite_tasks, so saving it
                    //    before the root node exists is safe.)
                    let compositeTask = CompositeTask(
                        id: compositeTaskId,
                        userId: playgroundUserId,
                        title: capturedTitle,
                        description: nil,
                        rootNodeId: rootNodeId,
                        createdAt: now,
                        updatedAt: now,
                        lastSyncedAt: nil,
                        version: 1,
                        isDeleted: false,
                        deletedAt: nil
                    )
                    try compositeTask.save(db)

                    // 3. Root operator node
                    let rootNode = CompositeNode(
                        id: rootNodeId,
                        compositeTaskId: compositeTaskId,
                        parentNodeId: nil,
                        nodeIndex: 0,
                        nodeType: .operator,
                        operatorType: capturedOperator,
                        threshold: capturedOperator == .mOfN ? capturedThreshold : nil,
                        taskId: nil,
                        childCompositeTaskId: nil,
                        createdAt: now,
                        updatedAt: now,
                        lastSyncedAt: nil,
                        version: 1,
                        isDeleted: false,
                        deletedAt: nil
                    )
                    try rootNode.save(db)

                    // 4. Leaf nodes
                    for (index, leaf) in resolvedLeaves.enumerated() {
                        let leafNode = CompositeNode(
                            id: AppDatabase.generateUUID(),
                            compositeTaskId: compositeTaskId,
                            parentNodeId: rootNodeId,
                            nodeIndex: index,
                            nodeType: .leaf,
                            operatorType: nil,
                            threshold: nil,
                            taskId: leaf.taskId,
                            childCompositeTaskId: leaf.childCompositeTaskId,
                            createdAt: now,
                            updatedAt: now,
                            lastSyncedAt: nil,
                            version: 1,
                            isDeleted: false,
                            deletedAt: nil
                        )
                        try leafNode.save(db)
                    }
                }

                DispatchQueue.main.async {
                    resetForm()
                    successMessage = "Composite task created!"
                    loadLibrary()
                    DispatchQueue.main.asyncAfter(deadline: .now() + successDismissSeconds) {
                        successMessage = nil
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = "Failed: \(error.localizedDescription)"
                    isSubmitting = false
                }
            }
        }
    }

    // MARK: - Reset

    /// Resets all form fields to their initial state after a successful submission.
    private func resetForm() {
        compositeTitle = ""
        operatorType = .and
        threshold = 2
        subtasks = []
        titleError = nil
        subtasksError = nil
        isSubmitting = false
    }

    // MARK: - Library Loading

    /// Loads tasks and composite tasks from the database on a background thread.
    private func loadLibrary() {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let tasks = try AppDatabase.shared.fetchTasks(userId: playgroundUserId)
                let composites = try AppDatabase.shared.read { db in
                    try CompositeTask
                        .filter(Column("userId") == playgroundUserId && Column("isDeleted") == false)
                        .order(Column("updatedAt").desc)
                        .fetchAll(db)
                }
                DispatchQueue.main.async {
                    self.libraryTasks = tasks
                    self.libraryCompositeTasks = composites
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Failed to load library: \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - SubtaskRowView

/// A single row in the flat subtask list.
///
/// Handles both existing-selection mode and inline-creation mode.
private struct SubtaskRowView: View {
    @ObservedObject var item: SubtaskItem
    let libraryTasks: [OYBC.Task]
    let libraryCompositeTasks: [CompositeTask]
    let usedTaskIds: Set<String>
    let usedCompositeIds: Set<String>
    let onRemove: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // Header: mode indicator + remove button
            HStack {
                Text(item.mode == .existing ? "Existing" : "New inline")
                    .font(.caption)
                    .foregroundColor(.secondary)
                Spacer()
                Button(action: onRemove) {
                    Image(systemName: "minus.circle.fill")
                        .foregroundColor(.red)
                }
                .buttonStyle(.plain)
            }

            if item.mode == .existing {
                existingModeContent
            } else {
                inlineModeContent
            }
        }
        .padding(10)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }

    // MARK: - Existing Mode

    @ViewBuilder
    private var existingModeContent: some View {
        // Selection type toggle
        Picker("Select from", selection: $item.selectionType) {
            Text("Task").tag(SubtaskItem.SelectionType.task)
            Text("Composite").tag(SubtaskItem.SelectionType.composite)
        }
        .pickerStyle(.segmented)

        if item.selectionType == .task {
            taskSelectionPicker
        } else {
            compositeSelectionPicker
        }
    }

    @ViewBuilder
    private var taskSelectionPicker: some View {
        let availableTasks = libraryTasks.filter { t in
            !usedTaskIds.contains(t.id) || t.id == item.selectedTaskId
        }

        if availableTasks.isEmpty {
            Text("No tasks available — create some first or add inline")
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            Picker("Task", selection: $item.selectedTaskId) {
                Text("Select a task").tag("")
                ForEach(availableTasks, id: \.id) { task in
                    Text(task.title).tag(task.id)
                }
            }
            .pickerStyle(.menu)
        }
    }

    @ViewBuilder
    private var compositeSelectionPicker: some View {
        let availableComposites = libraryCompositeTasks.filter { c in
            !usedCompositeIds.contains(c.id) || c.id == item.selectedCompositeId
        }

        if availableComposites.isEmpty {
            Text("No composite tasks available — create one first")
                .font(.caption)
                .foregroundColor(.secondary)
        } else {
            Picker("Composite", selection: $item.selectedCompositeId) {
                Text("Select a composite").tag("")
                ForEach(availableComposites, id: \.id) { ct in
                    Text(ct.title).tag(ct.id)
                }
            }
            .pickerStyle(.menu)
        }
    }

    // MARK: - Inline Mode

    @ViewBuilder
    private var inlineModeContent: some View {
        // Inline type picker
        Picker("Type", selection: $item.inlineType) {
            ForEach(InlineSubtaskType.allCases) { t in
                Text(t.rawValue).tag(t)
            }
        }
        .pickerStyle(.segmented)

        // Title field (shown for all types; required for normal and progress)
        TextField(
            item.inlineType == .counting
                ? "Title (auto-generated if blank)"
                : "Title (required)",
            text: $item.inlineTitle
        )
        .textFieldStyle(.roundedBorder)

        // Type-specific additional fields
        switch item.inlineType {
        case .normal:
            EmptyView()
        case .counting:
            CountingStepFieldsView(
                action: $item.inlineAction,
                maxCount: $item.inlineMaxCountStr,
                unit: $item.inlineUnit
            )
        case .progress:
            progressStepsContent
        }
    }

    @ViewBuilder
    private var progressStepsContent: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Steps")
                .font(.caption)
                .foregroundColor(.secondary)

            ForEach(Array(item.inlineSteps.indices), id: \.self) { index in
                ProgressStepRowView(
                    index: index,
                    step: Binding(
                        get: { item.inlineSteps[index] },
                        set: { item.inlineSteps[index] = $0 }
                    ),
                    stepCount: item.inlineSteps.count,
                    onRemove: {
                        item.inlineSteps.remove(at: index)
                    }
                )
            }

            Button("+ Add Step") {
                item.inlineSteps.append(ProgressStepFormState())
            }
            .font(.caption)
        }
    }
}
