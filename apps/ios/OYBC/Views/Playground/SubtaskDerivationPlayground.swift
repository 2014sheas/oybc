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
/// - Counting tasks: TextField for partial count allocation with a live title preview
///   and a "Create Subtask" button that writes the new task to the database.
/// - Progress tasks: Lists each TaskStep with type, linked-task badge, counting
///   detail, and an "Extract as Task" button for unlinked steps.
/// - Composite tasks: Shows the operator type and resolves leaf nodes to named entries.
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

    /// Validated partial count value. nil when the string is not a valid positive integer.
    private var partialCount: Int? {
        let trimmed = partialCountStr.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let value = Int(trimmed), value > 0 else { return nil }
        return value
    }

    /// Whether the partial count is within the allowed range for the selected counting task.
    private var isPartialCountValid: Bool {
        guard let count = partialCount,
              let task = selectedTask,
              let maxCount = task.maxCount else { return false }
        return count <= maxCount
    }

    /// Live-previewed derived subtask title for counting tasks.
    ///
    /// Replicates `generateCounterTaskTitle` from packages/shared: "\(action) \(count) \(unit)".
    private var derivedCountingTitle: String? {
        guard let task = selectedTask,
              task.type == .counting,
              let action = task.action,
              let unit = task.unit,
              let count = partialCount else { return nil }
        return "\(action) \(count) \(unit)"
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
                            compositeDerivationPanel(ct)
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
                        HStack {
                            Text(entry.title)
                                .font(.subheadline)
                                .lineLimit(1)
                            Spacer()
                            TypeBadgeView(type: entry.type, size: .small)
                            Button {
                                boardPool.removeAll { $0.taskId == entry.taskId }
                            } label: {
                                Image(systemName: "xmark.circle.fill")
                                    .foregroundColor(.secondary)
                            }
                            .buttonStyle(.plain)
                        }
                        .padding(8)
                        .background(Color(.systemGray5))
                        .cornerRadius(6)
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
                    countingDerivationPanel(task)
                case .progress:
                    progressDerivationPanel(task)
                }
            } else if let ct = selectedCompositeTask {
                compositeDerivationPanel(ct)
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

    /// Panel shown for counting tasks — partial count allocation with live preview.
    ///
    /// - Parameter task: The selected counting Task.
    @ViewBuilder
    private func countingDerivationPanel(_ task: Task) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(task.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                TypeBadgeView(type: task.type.rawValue, size: .small)
            }

            // Parent task metadata
            VStack(alignment: .leading, spacing: 4) {
                if let action = task.action, let unit = task.unit, let maxCount = task.maxCount {
                    HStack(spacing: 0) {
                        metaChip(label: "Action", value: action)
                        Text(" · ")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        metaChip(label: "Unit", value: unit)
                        Text(" · ")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        metaChip(label: "Parent total", value: "\(maxCount)")
                    }
                }
            }

            Divider()

            // Partial count allocation
            VStack(alignment: .leading, spacing: 6) {
                Text("Allocate partial count")
                    .font(.subheadline)
                    .fontWeight(.semibold)

                HStack {
                    TextField("Partial count", text: $partialCountStr)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad)
                        .frame(maxWidth: 140)

                    if let maxCount = task.maxCount {
                        Text("of \(maxCount)")
                            .font(.subheadline)
                            .foregroundColor(.secondary)
                    }
                }

                // Validation feedback
                if !partialCountStr.isEmpty {
                    if partialCount == nil {
                        Text("Enter a positive integer.")
                            .font(.caption)
                            .foregroundColor(.red)
                    } else if !isPartialCountValid, let maxCount = task.maxCount {
                        Text("Must be \(maxCount) or less.")
                            .font(.caption)
                            .foregroundColor(.red)
                    }
                }
            }

            // Live preview
            if isPartialCountValid, let previewTitle = derivedCountingTitle {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Derived Subtask Preview")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    Text(previewTitle)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 6)
                        .background(Color.orange.opacity(0.12))
                        .cornerRadius(6)
                }
            }

            // Create subtask action
            Button(action: { createCountingSubtask(from: task) }) {
                Text(isCreating ? "Adding..." : "Add to Board Pool")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(!isPartialCountValid || isCreating)
        }
        .padding(12)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }

    /// Panel shown for progress tasks — lists each TaskStep with type and link status.
    ///
    /// - Parameter task: The selected progress Task.
    @ViewBuilder
    private func progressDerivationPanel(_ task: Task) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(task.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                TypeBadgeView(type: task.type.rawValue, size: .small)
            }

            if taskSteps.isEmpty {
                Text("No steps defined for this task.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(taskSteps.count) step\(taskSteps.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ForEach(taskSteps.sorted(by: { $0.stepIndex < $1.stepIndex }), id: \.id) { step in
                        progressStepRow(step)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }

    /// A single step row within the progress derivation panel.
    ///
    /// - Parameter step: The TaskStep to display.
    @ViewBuilder
    private func progressStepRow(_ step: TaskStep) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .top) {
                Text("\(step.stepIndex + 1).")
                    .font(.caption)
                    .foregroundColor(.secondary)
                    .frame(width: 18, alignment: .leading)

                VStack(alignment: .leading, spacing: 3) {
                    HStack {
                        Text(step.title)
                            .font(.subheadline)
                        Spacer()
                        TypeBadgeView(type: step.type.rawValue, size: .small)
                    }

                    // Counting step metadata
                    if step.type == .counting,
                       let action = step.action,
                       let maxCount = step.maxCount,
                       let unit = step.unit {
                        Text("\(action) \(maxCount) \(unit)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()

                // Pool/extract action
                if let linkedId = step.linkedTaskId {
                    if boardPool.contains(where: { $0.taskId == linkedId }) {
                        Text("In Pool ✓")
                            .font(.caption)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Color.green.opacity(0.2))
                            .foregroundColor(.green)
                            .cornerRadius(4)
                    } else {
                        Button("Add to Pool") {
                            if let linkedTask = tasks.first(where: { $0.id == linkedId }) {
                                addToPool(taskId: linkedTask.id, title: linkedTask.title, type: linkedTask.type.rawValue)
                                showSuccess("Added to board pool: \"\(linkedTask.title)\"")
                            }
                        }
                        .font(.caption)
                        .buttonStyle(.bordered)
                    }
                } else {
                    Text("No Task")
                        .font(.caption)
                        .foregroundColor(.orange)
                }
            }

            // Extract button — only for unlinked steps
            if step.linkedTaskId == nil {
                Button("Extract & Add to Pool") {
                    extractStepAsTask(step: step, parentTask: selectedTask!)
                }
                .font(.caption)
                .buttonStyle(.bordered)
                .disabled(isCreating)
            }
        }
        .padding(8)
        .background(Color(.systemGray5))
        .cornerRadius(6)
    }

    /// A green or yellow badge indicating whether a step already has a linked task.
    ///
    /// - Parameter isLinked: True if `linkedTaskId` is non-nil.
    @ViewBuilder
    private func linkedTaskBadge(_ isLinked: Bool) -> some View {
        let (label, color): (String, Color) = isLinked
            ? ("Existing Task", .green)
            : ("New Task Required", .orange)
        Text(label)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .foregroundColor(color)
            .cornerRadius(4)
    }

    /// Panel shown for composite tasks — shows operator type and resolves leaf nodes.
    ///
    /// - Parameter ct: The selected CompositeTask.
    @ViewBuilder
    private func compositeDerivationPanel(_ ct: CompositeTask) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(ct.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                TypeBadgeView(type: "composite", size: .small)
            }

            if compositeNodes.isEmpty {
                Text("No nodes found for this composite task.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                let rootNode = compositeNodes.first(where: { $0.parentNodeId == nil })
                let leafNodes = compositeNodes.filter { $0.nodeType == .leaf }
                let taskMap = Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
                let compositeMap = Dictionary(uniqueKeysWithValues: compositeTasks.map { ($0.id, $0) })

                // Operator summary
                if let root = rootNode, let opType = root.operatorType {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Operator")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack {
                            Text(operatorLabel(opType, threshold: root.threshold, leafCount: leafNodes.count))
                                .font(.subheadline)
                                .fontWeight(.medium)
                            Text(opType.rawValue)
                                .font(.caption)
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(Color.purple.opacity(0.2))
                                .cornerRadius(4)
                        }
                    }

                    Divider()
                }

                // Leaf nodes
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(leafNodes.count) leaf node\(leafNodes.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    ForEach(leafNodes.sorted(by: { $0.nodeIndex < $1.nodeIndex }), id: \.id) { node in
                        compositeLeafRow(node, taskMap: taskMap, compositeMap: compositeMap)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }

    /// A single leaf node row within the composite derivation panel.
    ///
    /// - Parameters:
    ///   - node: The CompositeNode (leaf) to display.
    ///   - taskMap: Dictionary mapping task IDs to Task values for quick lookup.
    ///   - compositeMap: Dictionary mapping composite task IDs to CompositeTask values.
    @ViewBuilder
    private func compositeLeafRow(
        _ node: CompositeNode,
        taskMap: [String: Task],
        compositeMap: [String: CompositeTask]
    ) -> some View {
        HStack {
            Text("·")
                .foregroundColor(.secondary)

            if let taskId = node.taskId, let task = taskMap[taskId] {
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title)
                        .font(.subheadline)
                    if task.type == .counting,
                       let action = task.action,
                       let maxCount = task.maxCount,
                       let unit = task.unit {
                        Text("\(action) \(maxCount) \(unit)")
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                }
                Spacer()
                TypeBadgeView(type: task.type.rawValue, size: .small)
            } else if let childId = node.childCompositeTaskId, let child = compositeMap[childId] {
                Text(child.title)
                    .font(.subheadline)
                Spacer()
                TypeBadgeView(type: "composite", size: .small)
            } else {
                Text("Unknown reference")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(8)
        .background(Color(.systemGray5))
        .cornerRadius(6)
    }

    /// Inline key/value chip used in the counting panel metadata row.
    ///
    /// - Parameters:
    ///   - label: Short label shown in secondary color.
    ///   - value: Value shown in primary color.
    @ViewBuilder
    private func metaChip(label: String, value: String) -> some View {
        HStack(spacing: 2) {
            Text("\(label): ")
                .font(.caption)
                .foregroundColor(.secondary)
            Text(value)
                .font(.caption)
                .fontWeight(.medium)
        }
    }

    /// Human-readable label for a composite operator.
    ///
    /// - Parameters:
    ///   - type: The OperatorType.
    ///   - threshold: Threshold for M_OF_N; unused for AND/OR.
    ///   - leafCount: Total leaf count for M_OF_N context.
    /// - Returns: A descriptive string such as "All of", "Any of", or "At least 2 of 4".
    private func operatorLabel(_ type: OperatorType, threshold: Int?, leafCount: Int) -> String {
        switch type {
        case .and:   return "All of"
        case .or:    return "Any of"
        case .mOfN:  return "At least \(threshold ?? 0) of \(leafCount)"
        }
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
    /// Uses `partialCount` as the `maxCount` for the new task. The title is auto-generated
    /// following the `generateCounterTaskTitle` convention: "\(action) \(count) \(unit)".
    /// Clears the partial count field and refreshes the task library on success.
    ///
    /// - Parameter parentTask: The counting Task from which the subtask is derived.
    private func createCountingSubtask(from parentTask: Task) {
        guard let action = parentTask.action,
              let unit = parentTask.unit,
              let count = partialCount else { return }

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
