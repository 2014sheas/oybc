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

/// Subtask Derivation Engine Playground — READ-ONLY.
///
/// Lets users select a parent task from the task library and inspect what subtasks
/// can be derived from it. No database writes are performed.
///
/// - Normal tasks: Shown as not subdivisible.
/// - Counting tasks: TextField for partial count allocation with a live title preview.
/// - Progress tasks: Lists each TaskStep with type, linked-task badge, and counting detail.
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

    // Error state
    @State private var loadError: String? = nil

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
                taskTypeBadge(for: task.type)
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
                Text("COMPOSITE")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.indigo.opacity(0.2))
                    .cornerRadius(4)
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
                taskTypeBadge(for: task.type)
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
                taskTypeBadge(for: task.type)
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
                taskTypeBadge(for: task.type)
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
                        taskTypeBadge(for: step.type)
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

                // Linked task badge
                linkedTaskBadge(step.linkedTaskId != nil)
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
                Text("COMPOSITE")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.indigo.opacity(0.2))
                    .cornerRadius(4)
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
                            operatorBadge(opType)
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
                taskTypeBadge(for: task.type)
            } else if let childId = node.childCompositeTaskId, let child = compositeMap[childId] {
                Text(child.title)
                    .font(.subheadline)
                Spacer()
                Text("COMPOSITE")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.indigo.opacity(0.2))
                    .cornerRadius(4)
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

    // MARK: - Shared Badge Helpers

    /// Renders a colored type badge for a task type.
    ///
    /// - Parameter type: The TaskType to render a badge for.
    @ViewBuilder
    private func taskTypeBadge(for type: TaskType) -> some View {
        let (label, color): (String, Color) = {
            switch type {
            case .normal:   return ("NORMAL", .blue)
            case .counting: return ("COUNTING", .orange)
            case .progress: return ("PROGRESS", .purple)
            }
        }()
        Text(label)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .cornerRadius(4)
    }

    /// Renders a small colored badge for a composite operator type.
    ///
    /// - Parameter type: The OperatorType to badge.
    @ViewBuilder
    private func operatorBadge(_ type: OperatorType) -> some View {
        let (label, color): (String, Color) = {
            switch type {
            case .and:   return ("AND", .blue)
            case .or:    return ("OR", .teal)
            case .mOfN:  return ("M of N", .purple)
            }
        }()
        Text(label)
            .font(.caption)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(color.opacity(0.2))
            .cornerRadius(4)
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
}
