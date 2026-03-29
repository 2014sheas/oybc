import SwiftUI
import GRDB

// MARK: - Task Type Picker

/// Wrapper type for the Create tab task-type picker that includes Composite alongside
/// the three TaskType cases.
///
/// Composite tasks are NOT a `TaskType`; they live in their own `composite_tasks` table.
/// This enum lets the picker treat all four as a single selection.
private enum BoardTaskType: String, CaseIterable {
    case normal = "Normal"
    case counting = "Counting"
    case progress = "Progress"
    case composite = "Composite"
}

// MARK: - Mode

/// The two tab modes for the Board Task Selection playground.
private enum SelectionMode: String, CaseIterable {
    case create = "Create New"
    case existing = "Existing Tasks"
}

// MARK: - Existing Browse Mode

/// Sub-toggle within the Existing Tasks tab for browsing source.
private enum ExistingBrowseMode: String, CaseIterable {
    case library = "Task Library"
    case board = "From Board"
}

// MARK: - Existing Tab Filter

/// Filter options for the Existing Tasks tab.
private enum ExistingFilter: String, CaseIterable {
    case all = "All"
    case normal = "Normal"
    case counting = "Counting"
    case progress = "Progress"
    case composite = "Composite"
}

// MARK: - BoardTaskSelectionPlayground

/// Board Task Selection Playground — SF4 entry point.
///
/// Provides two tabs for populating a board task pool:
///
/// - **Create New**: Inline task creation for Normal/Counting/Progress tasks, plus
///   `CompositeTaskFormView` for Composite. Newly created tasks are added directly to the pool.
/// - **Existing Tasks**: Filterable list of all tasks in the library. Each row shows title and
///   type badge. Normal tasks show only an "Add to Pool" button. Counting, Progress, and
///   Composite tasks additionally show an expand/collapse button (▶/▼) that reveals an inline
///   derivation panel (`CountingDerivationPanelView`, `ProgressDerivationPanelView`,
///   `CompositeDerivationPanelView`). An "Add to Pool" button or "In Pool" badge appears on
///   every row.
///
/// The **Board Task Pool** section is always visible at the bottom and shows all queued tasks
/// with individual remove buttons and a bulk "Clear Pool" action.
struct BoardTaskSelectionPlayground: View {

    // MARK: - Mode State

    @State private var mode: SelectionMode = .create

    // MARK: - Create Tab State

    @State private var createTaskType: BoardTaskType = .normal

    /// Maps `createTaskType` to a concrete `TaskType`. Returns `nil` for `.composite`.
    private var createSelectedType: TaskType? {
        switch createTaskType {
        case .normal:    return .normal
        case .counting:  return .counting
        case .progress:  return .progress
        case .composite: return nil
        }
    }

    // Shared fields
    @State private var createTitle = ""
    @State private var createDescription = ""

    // Counting fields
    @State private var createCountingAction = ""
    @State private var createCountingUnit = ""
    @State private var createCountingMaxCount = ""

    // Progress fields
    @State private var createProgressSteps: [ProgressStepFormState] = [ProgressStepFormState()]
    @State private var createProgressStepErrors: [UUID: ProgressStepFormErrors] = [:]

    // Submission feedback
    @State private var createIsSubmitting = false
    @State private var createErrorMessage: String?
    @State private var createSuccessMessage: String?

    // MARK: - Existing Tab State

    @State private var existingBrowseMode: ExistingBrowseMode = .library
    @State private var existingFilter: ExistingFilter = .all
    @State private var expandedTaskId: String? = nil
    @State private var expandedCompositeTaskId: String? = nil
    @State private var deriveTaskSteps: [TaskStep] = []
    @State private var deriveCompositeNodes: [CompositeNode] = []
    @State private var derivePartialCountStr: String = ""
    @State private var deriveIsCreating: Bool = false

    // MARK: - From Board Tab State

    @State private var boards: [Board] = []
    @State private var selectedBoardId: String? = nil
    @State private var boardTasks: [BoardTask] = []
    @State private var boardSelectedTaskId: String? = nil
    @State private var boardTaskSteps: [TaskStep] = []
    @State private var boardCompositeNodes: [CompositeNode] = []
    @State private var boardPartialCountStr: String = ""
    @State private var boardSuccessMessage: String? = nil
    @State private var isBoardSettingUp: Bool = false

    // MARK: - Library State (shared across tabs)

    @State private var libraryTasks: [Task] = []
    @State private var libraryCompositeTasks: [CompositeTask] = []
    @State private var allLibraryTaskSteps: [TaskStep] = []
    @State private var loadError: String? = nil

    // MARK: - Pool State

    @State private var boardPool: [(taskId: String, title: String, type: String)] = []

    // MARK: - Computed

    /// Tasks visible in the Existing tab after applying the current filter.
    private var existingFilteredTasks: [Task] {
        switch existingFilter {
        case .all:       return libraryTasks
        case .normal:    return libraryTasks.filter { $0.type == .normal }
        case .counting:  return libraryTasks.filter { $0.type == .counting }
        case .progress:  return libraryTasks.filter { $0.type == .progress }
        case .composite: return []
        }
    }

    /// Composite tasks visible in the Existing tab after applying the current filter.
    private var existingFilteredComposites: [CompositeTask] {
        switch existingFilter {
        case .all, .composite: return libraryCompositeTasks
        default:               return []
        }
    }

    // MARK: - From Board Tab Computed

    /// The board currently selected in the From Board tab.
    private var selectedBoard: Board? {
        guard let id = selectedBoardId else { return nil }
        return boards.first(where: { $0.id == id })
    }

    /// O(1) lookup from `"\(row)-\(col)"` to BoardTask for the selected board's grid.
    private var boardTaskMap: [String: BoardTask] {
        Dictionary(uniqueKeysWithValues: boardTasks.map { ("\($0.row)-\($0.col)", $0) })
    }

    /// Board tasks sorted by row then column for natural grid reading order.
    private var sortedBoardTasks: [BoardTask] {
        boardTasks.sorted { $0.row == $1.row ? $0.col < $1.col : $0.row < $1.row }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // ── Mode picker + pool chip ──
            HStack {
                Picker("Mode", selection: $mode) {
                    ForEach(SelectionMode.allCases, id: \.self) { m in
                        Text(m.rawValue).tag(m)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: mode) {
                    clearCreateFeedback()
                }

                if !boardPool.isEmpty {
                    Text("Pool: \(boardPool.count)")
                        .font(.caption)
                        .fontWeight(.bold)
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
            }

            // ── Tab content ──
            switch mode {
            case .create:
                createTab
            case .existing:
                existingTab
            }

            // ── Board Task Pool ──
            Divider()
            poolSection

            // ── Board Creator ──
            if !boardPool.isEmpty {
                Divider()
                BoardCreatorPanelView(
                    boardPool: boardPool,
                    libraryTasks: libraryTasks,
                    allTaskSteps: allLibraryTaskSteps,
                    onBoardCreated: { _ in
                        // Board created from pool — library refresh picks up the new board
                        loadLibrary()
                    }
                )
            }

        }
        .preference(key: PoolCountPreferenceKey.self, value: boardPool.count)
        .onAppear {
            ensurePlaygroundUser()
            loadLibrary()
        }
    }

    // MARK: - Create Tab

    @ViewBuilder
    private var createTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create Task")
                .font(.headline)

            // Type picker
            Picker("Task Type", selection: $createTaskType) {
                ForEach(BoardTaskType.allCases, id: \.self) { pt in
                    Text(pt.rawValue).tag(pt)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: createTaskType) {
                clearCreateFeedback()
            }

            if createTaskType == .composite {
                // Composite creation handled entirely by CompositeTaskFormView.
                // onCreated adds the new composite to the pool and refreshes the library.
                CompositeTaskFormView(onCreated: { compositeTask in
                    addToPool(
                        taskId: compositeTask.id,
                        title: compositeTask.title,
                        type: "composite"
                    )
                    loadLibrary()
                })
            } else {
                // Shared title field
                VStack(alignment: .leading, spacing: 4) {
                    TextField(
                        createSelectedType == .counting
                            ? "Title (auto-generated if blank)"
                            : "Title (required)",
                        text: $createTitle
                    )
                    .textFieldStyle(.roundedBorder)
                    Text("\(createTitle.count)/200")
                        .font(.caption)
                        .foregroundColor(createTitle.count > 200 ? .red : .secondary)
                }

                // Shared description field
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Description (optional)", text: $createDescription, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...)
                    Text("\(createDescription.count)/1000")
                        .font(.caption)
                        .foregroundColor(createDescription.count > 1000 ? .red : .secondary)
                }

                // Counting-specific fields
                if createSelectedType == .counting {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Counting Details")
                            .font(.subheadline)
                            .fontWeight(.semibold)

                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Action (e.g. Run, Read)", text: $createCountingAction)
                                .textFieldStyle(.roundedBorder)
                            Text("\(createCountingAction.count)/50")
                                .font(.caption)
                                .foregroundColor(createCountingAction.count > 50 ? .red : .secondary)
                        }

                        TextField("Max Count (positive integer)", text: $createCountingMaxCount)
                            .textFieldStyle(.roundedBorder)
                            .keyboardType(.numberPad)

                        VStack(alignment: .leading, spacing: 4) {
                            TextField("Unit (e.g. miles, pages)", text: $createCountingUnit)
                                .textFieldStyle(.roundedBorder)
                            Text("\(createCountingUnit.count)/50")
                                .font(.caption)
                                .foregroundColor(createCountingUnit.count > 50 ? .red : .secondary)
                        }
                    }
                    .padding(8)
                    .background(Color(.systemGray5))
                    .cornerRadius(6)
                }

                // Progress-specific fields
                if createSelectedType == .progress {
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Steps")
                            .font(.subheadline)
                            .fontWeight(.semibold)

                        ForEach(createProgressSteps.indices, id: \.self) { i in
                            ProgressStepRowView(
                                index: i,
                                step: $createProgressSteps[i],
                                stepCount: createProgressSteps.count,
                                errors: createProgressStepErrors[createProgressSteps[i].id],
                                onRemove: { createProgressSteps.remove(at: i) }
                            )
                        }

                        Button("Add Step") {
                            createProgressSteps.append(ProgressStepFormState())
                        }
                        .font(.subheadline)
                    }
                }

                // Feedback
                if let error = createErrorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }
                if let success = createSuccessMessage {
                    Text(success)
                        .foregroundColor(.green)
                        .font(.caption)
                }

                // Submit
                Button("Create & Add to Pool") {
                    handleCreateAndAddToPool()
                }
                .buttonStyle(.borderedProminent)
                .disabled(createIsSubmitting)
            }
        }
    }

    // MARK: - Existing Tasks Tab

    @ViewBuilder
    private var existingTab: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Existing Tasks")
                .font(.headline)

            // Browse mode sub-toggle
            Picker("Browse", selection: $existingBrowseMode) {
                ForEach(ExistingBrowseMode.allCases, id: \.self) { bm in
                    Text(bm.rawValue).tag(bm)
                }
            }
            .pickerStyle(.segmented)

            switch existingBrowseMode {
            case .library:
                existingLibraryContent
            case .board:
                boardTab
            }
        }
    }

    /// The Task Library content within the Existing Tasks tab.
    ///
    /// Shows type filter pills and a list of all library tasks with add/derive controls.
    @ViewBuilder
    private var existingLibraryContent: some View {
        VStack(alignment: .leading, spacing: 12) {
            // Type filter — scrollable horizontal pills
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 8) {
                    ForEach(ExistingFilter.allCases, id: \.self) { f in
                        Button(f.rawValue) {
                            existingFilter = f
                            clearExpandedState()
                        }
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(existingFilter == f ? Color.accentColor : Color(.systemGray5))
                        .foregroundColor(existingFilter == f ? .white : .primary)
                        .clipShape(Capsule())
                    }
                }
            }

            if let error = loadError {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            if existingFilteredTasks.isEmpty && existingFilteredComposites.isEmpty {
                Text("No tasks found — create some first.")
                    .foregroundColor(.secondary)
                    .font(.subheadline)
            } else {
                ForEach(existingFilteredTasks, id: \.id) { task in
                    existingTaskRow(task)
                    if expandedTaskId == task.id {
                        derivePanel(for: task)
                            .padding(.leading, 8)
                            .transition(.opacity)
                    }
                }
                ForEach(existingFilteredComposites, id: \.id) { ct in
                    existingCompositeRow(ct)
                    if expandedCompositeTaskId == ct.id {
                        CompositeDerivationPanelView(
                            compositeTask: ct,
                            compositeNodes: deriveCompositeNodes,
                            tasks: libraryTasks,
                            compositeTasks: libraryCompositeTasks,
                            boardPool: boardPool,
                            onAddLeafToPool: { taskId, title, type in
                                addToPool(taskId: taskId, title: title, type: type)
                            }
                        )
                        .padding(.leading, 8)
                        .transition(.opacity)
                    }
                }
            }
        }
    }

    /// A single task row for the Existing Tasks tab.
    ///
    /// Normal tasks show only the "Add to Pool" / "In Pool" control. Counting, Progress, and
    /// Composite tasks additionally show a derive-expand button (`arrow.triangle.branch` /
    /// `chevron.up.circle`) that reveals the inline derivation panel.
    ///
    /// - Parameter task: The Task to display.
    @ViewBuilder
    private func existingTaskRow(_ task: Task) -> some View {
        let inPool = boardPool.contains(where: { $0.taskId == task.id })
        let isExpanded = expandedTaskId == task.id
        let supportsDerivation = task.type != .normal

        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                if let desc = task.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            TypeBadgeView(type: task.type.rawValue, size: .small)

            if supportsDerivation {
                Button {
                    toggleExpandTask(task)
                } label: {
                    Image(systemName: isExpanded ? "chevron.up.circle" : "arrow.triangle.branch")
                        .font(.system(size: 24))
                        .foregroundColor(isExpanded ? .accentColor : .secondary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(isExpanded ? "Collapse derivation" : "Derive subtasks")
            }

            if inPool {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.green)
                    .accessibilityLabel("In pool")
            } else {
                Button {
                    addToPool(taskId: task.id, title: task.title, type: task.type.rawValue)
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add \(task.title) to pool")
            }
        }
        .padding(10)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }

    /// A single composite task row for the Existing Tasks tab.
    ///
    /// Always shows a derive-expand button (`arrow.triangle.branch` / `chevron.up.circle`)
    /// alongside the "Add to Pool" / "In Pool" control.
    ///
    /// - Parameter ct: The CompositeTask to display.
    @ViewBuilder
    private func existingCompositeRow(_ ct: CompositeTask) -> some View {
        let inPool = boardPool.contains(where: { $0.taskId == ct.id })
        let isExpanded = expandedCompositeTaskId == ct.id

        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(ct.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                if let desc = ct.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            TypeBadgeView(type: "composite", size: .small)

            Button {
                toggleExpandComposite(ct)
            } label: {
                Image(systemName: isExpanded ? "chevron.up.circle" : "arrow.triangle.branch")
                    .font(.system(size: 24))
                    .foregroundColor(isExpanded ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse derivation" : "Derive subtasks")

            if inPool {
                Image(systemName: "checkmark.circle.fill")
                    .font(.system(size: 24))
                    .foregroundColor(.green)
                    .accessibilityLabel("In pool")
            } else {
                Button {
                    addToPool(taskId: ct.id, title: ct.title, type: "composite")
                } label: {
                    Image(systemName: "plus.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.accentColor)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add \(ct.title) to pool")
            }
        }
        .padding(10)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }

    /// The derivation panel, rendered according to the selected task type.
    ///
    /// - Parameter task: The expanded regular Task.
    @ViewBuilder
    private func derivePanel(for task: Task) -> some View {
        switch task.type {
        case .normal:
            EmptyView()

        case .counting:
            CountingDerivationPanelView(
                task: task,
                partialCountStr: $derivePartialCountStr,
                isCreating: deriveIsCreating,
                onCreateSubtask: { parentTask, count in
                    createCountingSubtask(from: parentTask, count: count)
                }
            )

        case .progress:
            ProgressDerivationPanelView(
                task: task,
                taskSteps: deriveTaskSteps,
                allTasks: libraryTasks,
                boardPool: boardPool,
                isCreating: deriveIsCreating,
                onExtractStep: { step, parentTask in
                    extractStepAsTask(step: step, parentTask: parentTask)
                },
                onAddStepToPool: { linkedTask in
                    addToPool(
                        taskId: linkedTask.id,
                        title: linkedTask.title,
                        type: linkedTask.type.rawValue
                    )
                }
            )
        }
    }

    // MARK: - Pool Section

    @ViewBuilder
    private var poolSection: some View {
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
                Text("No tasks in the pool yet. Use the tabs above to add tasks.")
                    .foregroundColor(.secondary)
                    .font(.subheadline)
            } else {
                ForEach(boardPool, id: \.taskId) { entry in
                    PoolItemView(title: entry.title, type: entry.type) {
                        boardPool.removeAll { $0.taskId == entry.taskId }
                    }
                }

                Button("Clear Pool") {
                    boardPool.removeAll()
                }
                .font(.caption)
                .foregroundColor(.red)
            }
        }
    }

    // MARK: - Create Tab Actions

    /// Validates the Create tab form, persists the task, and adds it to the pool.
    ///
    /// Mirrors the validation and creation logic from `UnifiedTaskCreatorPlayground.handleCreateTask()`.
    private func handleCreateAndAddToPool() {
        let trimmedTitle = createTitle.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDesc = createDescription.trimmingCharacters(in: .whitespacesAndNewlines)

        guard let resolvedType = createSelectedType else { return }

        if resolvedType != .counting {
            guard !trimmedTitle.isEmpty else {
                createErrorMessage = "Title is required"
                return
            }
        }
        guard trimmedTitle.count <= 200 else {
            createErrorMessage = "Title must be 200 characters or less"
            return
        }
        guard trimmedDesc.count <= 1000 else {
            createErrorMessage = "Description must be 1000 characters or less"
            return
        }

        switch resolvedType {
        case .normal:
            break

        case .counting:
            let a = createCountingAction.trimmingCharacters(in: .whitespacesAndNewlines)
            let u = createCountingUnit.trimmingCharacters(in: .whitespacesAndNewlines)
            let m = createCountingMaxCount.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !a.isEmpty else {
                createErrorMessage = "Action is required for Counting tasks"
                return
            }
            guard a.count <= 50 else {
                createErrorMessage = "Action must be 50 characters or less"
                return
            }
            guard !u.isEmpty else {
                createErrorMessage = "Unit is required for Counting tasks"
                return
            }
            guard u.count <= 50 else {
                createErrorMessage = "Unit must be 50 characters or less"
                return
            }
            guard let v = Int(m), v > 0 else {
                createErrorMessage = "Max Count must be a positive integer"
                return
            }

        case .progress:
            var stepErrors: [UUID: ProgressStepFormErrors] = [:]
            for step in createProgressSteps {
                var err = ProgressStepFormErrors()
                if step.type != .counting && step.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    err.title = "Step title is required"
                }
                if step.type == .counting {
                    if step.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        err.action = "Action is required"
                    }
                    if step.unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        err.unit = "Unit is required"
                    }
                    if (Int(step.maxCount.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0) <= 0 {
                        err.maxCount = "Must be a positive number"
                    }
                }
                if err.hasErrors { stepErrors[step.id] = err }
            }
            createProgressStepErrors = stepErrors
            if !stepErrors.isEmpty {
                createErrorMessage = "Please fix the errors below"
                return
            }
        }

        createIsSubmitting = true
        createErrorMessage = nil

        let now = AppDatabase.currentTimestamp()
        let taskId = AppDatabase.generateUUID()

        let resolvedTitle: String
        if resolvedType == .counting && trimmedTitle.isEmpty {
            let a = createCountingAction.trimmingCharacters(in: .whitespacesAndNewlines)
            let u = createCountingUnit.trimmingCharacters(in: .whitespacesAndNewlines)
            let m = Int(createCountingMaxCount.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            resolvedTitle = "\(a) \(m) \(u)"
        } else {
            resolvedTitle = trimmedTitle
        }

        let newTask = buildCreateTask(
            id: taskId,
            type: resolvedType,
            title: resolvedTitle,
            desc: trimmedDesc.isEmpty ? nil : trimmedDesc,
            now: now
        )
        let newSteps: [TaskStep] = resolvedType == .progress
            ? buildCreateSteps(taskId: taskId, now: now)
            : []

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                if newSteps.isEmpty {
                    try AppDatabase.shared.saveTask(newTask)
                } else {
                    try AppDatabase.shared.write { db in
                        try newTask.save(db)
                        for var step in newSteps {
                            // Create standalone task for each step
                            let stepTaskId = AppDatabase.generateUUID()
                            let stepTask = Task(
                                id: stepTaskId,
                                userId: playgroundUserId,
                                title: step.title,
                                type: step.type,
                                action: step.action,
                                unit: step.unit,
                                maxCount: step.maxCount,
                                totalCompletions: 0,
                                totalInstances: 0,
                                createdAt: step.createdAt,
                                updatedAt: step.updatedAt,
                                version: 1,
                                isDeleted: false
                            )
                            try stepTask.save(db)
                            step.linkedTaskId = stepTaskId
                            try step.save(db)
                        }
                    }
                }
                DispatchQueue.main.async {
                    addToPool(taskId: taskId, title: resolvedTitle, type: resolvedType.rawValue)
                    resetCreateForm()
                    createSuccessMessage = "Task created and added to pool!"
                    loadLibrary()
                    DispatchQueue.main.asyncAfter(deadline: .now() + successDismissSeconds) {
                        createSuccessMessage = nil
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    createErrorMessage = "Failed to create task: \(error.localizedDescription)"
                    createIsSubmitting = false
                }
            }
        }
    }

    /// Builds a Task value from the Create tab form state.
    ///
    /// - Parameters:
    ///   - id: Pre-generated UUID string.
    ///   - type: The resolved `TaskType`.
    ///   - title: Validated, trimmed title (auto-generated for counting if blank).
    ///   - desc: Optional trimmed description.
    ///   - now: ISO8601 timestamp.
    /// - Returns: A `Task` ready to persist.
    private func buildCreateTask(id: String, type: TaskType, title: String, desc: String?, now: String) -> Task {
        switch type {
        case .normal:
            return Task(
                id: id, userId: playgroundUserId, title: title, description: desc,
                type: .normal, totalCompletions: 0, totalInstances: 0,
                createdAt: now, updatedAt: now, version: 1, isDeleted: false
            )
        case .counting:
            let a = createCountingAction.trimmingCharacters(in: .whitespacesAndNewlines)
            let u = createCountingUnit.trimmingCharacters(in: .whitespacesAndNewlines)
            let m = Int(createCountingMaxCount.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            return Task(
                id: id, userId: playgroundUserId, title: title, description: desc,
                type: .counting, action: a, unit: u, maxCount: m,
                totalCompletions: 0, totalInstances: 0,
                createdAt: now, updatedAt: now, version: 1, isDeleted: false
            )
        case .progress:
            return Task(
                id: id, userId: playgroundUserId, title: title, description: desc,
                type: .progress, totalCompletions: 0, totalInstances: 0,
                createdAt: now, updatedAt: now, version: 1, isDeleted: false
            )
        }
    }

    /// Builds `TaskStep` values from the Create tab progress step form state.
    ///
    /// - Parameters:
    ///   - taskId: The parent task ID.
    ///   - now: ISO8601 timestamp.
    /// - Returns: Array of `TaskStep` values ready to persist.
    private func buildCreateSteps(taskId: String, now: String) -> [TaskStep] {
        createProgressSteps.enumerated().map { index, stepForm in
            let trimmedAction = stepForm.action.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedUnit = stepForm.unit.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedTitle = stepForm.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedStepTitle: String
            if stepForm.type == .counting && trimmedTitle.isEmpty {
                let m = Int(stepForm.maxCount.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                resolvedStepTitle = "\(trimmedAction) \(m) \(trimmedUnit)"
            } else {
                resolvedStepTitle = trimmedTitle
            }
            return TaskStep(
                id: AppDatabase.generateUUID(),
                taskId: taskId,
                stepIndex: index,
                title: resolvedStepTitle,
                type: stepForm.type,
                action: stepForm.type == .counting ? trimmedAction : nil,
                unit: stepForm.type == .counting ? trimmedUnit : nil,
                maxCount: stepForm.type == .counting
                    ? Int(stepForm.maxCount.trimmingCharacters(in: .whitespacesAndNewlines))
                    : nil,
                linkedTaskId: nil,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: nil,
                version: 1,
                isDeleted: false,
                deletedAt: nil
            )
        }
    }

    /// Resets the Create tab form to its initial state after a successful submission.
    private func resetCreateForm() {
        createTitle = ""
        createDescription = ""
        createCountingAction = ""
        createCountingUnit = ""
        createCountingMaxCount = ""
        createProgressSteps = [ProgressStepFormState()]
        createProgressStepErrors = [:]
        createIsSubmitting = false
    }

    /// Clears Create tab feedback messages when the type picker or mode changes.
    private func clearCreateFeedback() {
        createErrorMessage = nil
        createSuccessMessage = nil
    }

    // MARK: - Existing Tab Actions

    /// Toggles the expand/collapse state for a regular task row.
    ///
    /// If the task is not already expanded, loads its steps (for progress tasks).
    /// Collapses the composite expansion when a regular task is expanded.
    ///
    /// - Parameter task: The Task the user toggled.
    private func toggleExpandTask(_ task: Task) {
        if expandedTaskId == task.id {
            expandedTaskId = nil
            deriveTaskSteps = []
            derivePartialCountStr = ""
        } else {
            expandedTaskId = task.id
            expandedCompositeTaskId = nil
            deriveCompositeNodes = []
            derivePartialCountStr = ""
            deriveTaskSteps = []
            if task.type == .progress {
                loadDeriveSteps(for: task.id)
            }
        }
    }

    /// Toggles the expand/collapse state for a composite task row.
    ///
    /// Loads composite nodes when expanding. Collapses the regular task expansion.
    ///
    /// - Parameter ct: The CompositeTask the user toggled.
    private func toggleExpandComposite(_ ct: CompositeTask) {
        if expandedCompositeTaskId == ct.id {
            expandedCompositeTaskId = nil
            deriveCompositeNodes = []
        } else {
            expandedCompositeTaskId = ct.id
            expandedTaskId = nil
            deriveTaskSteps = []
            derivePartialCountStr = ""
            deriveCompositeNodes = []
            loadDeriveNodes(for: ct.id)
        }
    }

    /// Clears the expanded state and all derived data (e.g. when the filter changes).
    private func clearExpandedState() {
        expandedTaskId = nil
        expandedCompositeTaskId = nil
        derivePartialCountStr = ""
        deriveTaskSteps = []
        deriveCompositeNodes = []
    }

    /// Creates a new counting subtask from a parent task and adds it to the pool.
    ///
    /// - Parameters:
    ///   - parentTask: The counting Task to derive from.
    ///   - count: The partial count for the new subtask.
    private func createCountingSubtask(from parentTask: Task, count: Int) {
        guard let action = parentTask.action, let unit = parentTask.unit else { return }
        deriveIsCreating = true
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
                    self.deriveIsCreating = false
                    self.addToPool(taskId: newTask.id, title: title, type: TaskType.counting.rawValue)
                    self.derivePartialCountStr = ""
                    self.loadLibrary()
                }
            } catch {
                DispatchQueue.main.async {
                    self.deriveIsCreating = false
                    self.loadError = "Failed to create subtask: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Extracts a progress task step into a standalone task, links them, and adds the task to the pool.
    ///
    /// - Parameters:
    ///   - step: The TaskStep to extract.
    ///   - parentTask: The progress Task that owns the step.
    private func extractStepAsTask(step: TaskStep, parentTask: Task) {
        // If step already has a linked task, just add it to pool — don't create a duplicate
        if let linkedId = step.linkedTaskId,
           let linkedTask = libraryTasks.first(where: { $0.id == linkedId }) {
            addToPool(taskId: linkedTask.id, title: linkedTask.title, type: linkedTask.type.rawValue)
            showBoardSuccess("Added to board pool: \"\(linkedTask.title)\"")
            return
        }

        deriveIsCreating = true
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
                    try db.execute(
                        sql: "UPDATE \(TaskStep.databaseTableName) SET linkedTaskId = ?, updatedAt = ? WHERE id = ?",
                        arguments: [newTask.id, now, step.id]
                    )
                }
                DispatchQueue.main.async {
                    self.deriveIsCreating = false
                    self.addToPool(taskId: newTask.id, title: newTask.title, type: newTask.type.rawValue)
                    self.loadLibrary()
                    self.loadDeriveSteps(for: parentTask.id)
                }
            } catch {
                DispatchQueue.main.async {
                    self.deriveIsCreating = false
                    self.loadError = "Failed to extract step: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Pool Helpers

    /// Adds a task to the board pool if not already present.
    ///
    /// - Parameters:
    ///   - taskId: The task/composite ID.
    ///   - title: Display title.
    ///   - type: Type string (e.g. "normal", "counting", "composite").
    private func addToPool(taskId: String, title: String, type: String) {
        guard !boardPool.contains(where: { $0.taskId == taskId }) else { return }
        boardPool.append((taskId: taskId, title: title, type: type))
    }

    // MARK: - Data Loading

    /// Loads all non-deleted tasks, composite tasks, and boards for the playground user.
    private func loadLibrary() {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let fetched = try AppDatabase.shared.fetchTasks(userId: playgroundUserId)
                let composites = try AppDatabase.shared.read { db in
                    try CompositeTask
                        .filter(Column("userId") == playgroundUserId && Column("isDeleted") == false)
                        .order(Column("title"))
                        .fetchAll(db)
                }
                let fetchedBoards = try AppDatabase.shared.fetchBoards(userId: playgroundUserId)
                let fetchedSteps = try AppDatabase.shared.fetchAllTaskSteps(userId: playgroundUserId)
                DispatchQueue.main.async {
                    self.libraryTasks = fetched
                    self.libraryCompositeTasks = composites
                    self.boards = fetchedBoards
                    self.allLibraryTaskSteps = fetchedSteps
                    self.loadError = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.loadError = "Failed to load tasks: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Loads TaskStep records for a given progress task.
    ///
    /// - Parameter taskId: The parent task ID.
    private func loadDeriveSteps(for taskId: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let steps = try AppDatabase.shared.fetchTaskSteps(taskId: taskId)
                DispatchQueue.main.async {
                    self.deriveTaskSteps = steps
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
    private func loadDeriveNodes(for compositeTaskId: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let nodes = try AppDatabase.shared.read { db in
                    try CompositeNode
                        .filter(
                            Column("compositeTaskId") == compositeTaskId
                            && Column("isDeleted") == false
                        )
                        .fetchAll(db)
                }
                DispatchQueue.main.async {
                    self.deriveCompositeNodes = nodes
                    self.loadError = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.loadError = "Failed to load composite nodes: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - From Board Tab

    /// The "From Board" tab — board picker, task grid, derivation panel, and shared pool.
    ///
    /// Board Picker (`.menu` style) + "Create Demo Board" button at top; below that a
    /// `LazyVGrid` of `InteractiveTaskSquareView` tiles once a board is selected. Tapping a
    /// tile opens the appropriate derivation panel below the grid. Derived tasks and extracted
    /// steps are staged in the shared `boardPool`.
    @ViewBuilder
    private var boardTab: some View {
        VStack(alignment: .leading, spacing: 12) {

            // ── Success banner ──
            if let success = boardSuccessMessage {
                Text(success)
                    .font(.subheadline)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.15))
                    .foregroundColor(.green)
                    .cornerRadius(8)
            }

            // ── Board picker + create button ──
            HStack {
                Text("Board")
                    .font(.headline)
                Spacer()
                Button(isBoardSettingUp ? "Creating..." : "+ Create Demo Board") {
                    createDemoBoard()
                }
                .font(.caption)
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .disabled(isBoardSettingUp)
            }

            if boards.isEmpty {
                Text("No boards yet. Tap \"+ Create Demo Board\" above to get started.")
                    .foregroundColor(.secondary)
                    .font(.subheadline)
            } else {
                Picker("Select Board", selection: Binding(
                    get: { selectedBoardId ?? "" },
                    set: { newValue in
                        if newValue.isEmpty {
                            selectedBoardId = nil
                            boardTasks = []
                            boardSelectedTaskId = nil
                            boardTaskSteps = []
                            boardCompositeNodes = []
                        } else if let board = boards.first(where: { $0.id == newValue }) {
                            selectBoardForBrowse(board)
                        }
                    }
                )) {
                    Text("Choose a board…").tag("")
                    ForEach(boards, id: \.id) { board in
                        Text("\(board.name) (\(board.boardSize)×\(board.boardSize))")
                            .tag(board.id)
                    }
                }
                .pickerStyle(.menu)

                if selectedBoardId != nil {
                    boardTasksGridSection
                        .transition(.opacity)
                }
            }
        }
    }

    // MARK: - Board Tasks Grid Section

    /// A `LazyVGrid` of `InteractiveTaskSquareView` tiles for the selected board's tasks,
    /// followed by the derivation panel for the currently selected tile.
    @ViewBuilder
    private var boardTasksGridSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Board Tasks")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            if boardTasks.isEmpty {
                Text("No tasks on this board.")
                    .foregroundColor(.secondary)
                    .font(.subheadline)
            } else {
                let size = selectedBoard?.boardSize ?? 3
                let columns = Array(repeating: GridItem(.fixed(90), spacing: 8), count: size)
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(0..<(size * size), id: \.self) { index in
                        let row = index / size
                        let col = index % size
                        if let bt = boardTaskMap["\(row)-\(col)"] {
                            boardTaskSquare(for: bt)
                        } else {
                            // Empty cell — FREE only at odd-sized board center when center type is free
                            let isCenter = row == size / 2 && col == size / 2 && size % 2 == 1
                            let showFree = isCenter && selectedBoard?.centerSquareType == .free
                            RoundedRectangle(cornerRadius: 8)
                                .strokeBorder(style: StrokeStyle(lineWidth: 2, dash: [6]))
                                .foregroundColor(Color(.systemGray3))
                                .frame(width: 90, height: 90)
                                .overlay(
                                    Text(showFree ? "FREE" : "—")
                                        .font(.caption)
                                        .fontWeight(.semibold)
                                        .foregroundColor(.secondary)
                                )
                        }
                    }
                }

                // ── Derivation panel below grid ──
                if let task = libraryTasks.first(where: { $0.id == boardSelectedTaskId }) {
                    boardTaskDerivationPanel(for: task)
                        .transition(.opacity)
                } else if let ct = libraryCompositeTasks.first(where: { $0.id == boardSelectedTaskId }) {
                    VStack(alignment: .leading, spacing: 12) {
                        // Add this composite directly
                        HStack {
                            Text(ct.title)
                                .font(.subheadline)
                                .fontWeight(.semibold)
                            Spacer()
                            TypeBadgeView(type: "composite", size: .small)
                            if boardPool.contains(where: { $0.taskId == ct.id }) {
                                Image(systemName: "checkmark.circle.fill")
                                    .font(.system(size: 24))
                                    .foregroundColor(.green)
                            } else {
                                Button {
                                    addToPool(taskId: ct.id, title: ct.title, type: "composite")
                                    showBoardSuccess("Added to board pool: \"\(ct.title)\"")
                                } label: {
                                    Image(systemName: "plus.circle.fill")
                                        .font(.system(size: 24))
                                        .foregroundColor(.accentColor)
                                }
                                .buttonStyle(.plain)
                            }
                        }

                        Divider()
                        Text("Or add individual subtasks:")
                            .font(.caption)
                            .fontWeight(.semibold)
                            .foregroundColor(.secondary)
                            .textCase(.uppercase)

                        CompositeDerivationPanelView(
                            compositeTask: ct,
                            compositeNodes: boardCompositeNodes,
                            tasks: libraryTasks,
                            compositeTasks: libraryCompositeTasks,
                            boardPool: boardPool,
                            onAddLeafToPool: { taskId, title, type in
                                addToPool(taskId: taskId, title: title, type: type)
                                showBoardSuccess("Added to board pool: \"\(title)\"")
                            }
                        )
                    }
                    .transition(.opacity)
                }
            }
        }
        .padding(10)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }

    /// Builds an `InteractiveTaskSquareView` tile for the given BoardTask in the From Board tab.
    ///
    /// Tapping selects the tile for derivation (does not toggle completion). A blue border
    /// overlay indicates the currently selected square.
    ///
    /// - Parameter boardTask: The BoardTask to render.
    @ViewBuilder
    private func boardTaskSquare(for boardTask: BoardTask) -> some View {
        let isSelected = boardSelectedTaskId == boardTask.taskId

        if let task = libraryTasks.first(where: { $0.id == boardTask.taskId }) {
            boardRegularTaskSquare(boardTask: boardTask, task: task, isSelected: isSelected)
        } else if let ct = libraryCompositeTasks.first(where: { $0.id == boardTask.taskId }) {
            // Composite task square — rendered as a normal-type square
            ZStack {
                InteractiveTaskSquareView(
                    title: ct.title,
                    taskType: .normal,
                    isCompleted: boardTask.isCompleted
                )

                if isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.blue, lineWidth: 3)
                        .frame(width: 90, height: 90)
                        .allowsHitTesting(false)
                }

                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture { selectBoardCompositeTask(ct) }
            }
            .frame(width: 90, height: 90)
            .contextMenu {
                if !boardPool.contains(where: { $0.taskId == ct.id }) {
                    Button {
                        addToPool(taskId: ct.id, title: ct.title, type: "composite")
                        showBoardSuccess("Added to pool: \"\(ct.title)\"")
                    } label: {
                        Label("Add to Pool", systemImage: "plus.circle")
                    }
                } else {
                    Text("Already in Pool")
                }

                Divider()
                Button {
                    selectBoardCompositeTask(ct)
                } label: {
                    Label("Inspect Subtasks…", systemImage: "arrow.triangle.branch")
                }
            }
        } else {
            // Unknown task — placeholder
            InteractiveTaskSquareView(
                title: "Unknown",
                taskType: .normal,
                isCompleted: false
            )
        }
    }

    /// Builds the correct `InteractiveTaskSquareView` for a regular (non-composite) board task.
    ///
    /// In the From Board tab, tapping selects for derivation — not completion. A transparent
    /// `Color.clear` overlay on top intercepts taps before `InteractiveTaskSquareView`'s
    /// internal gesture handler.
    ///
    /// - Parameters:
    ///   - boardTask: Provides current progress state from the database.
    ///   - task: The resolved Task for title, type, and metadata.
    ///   - isSelected: When true, renders a blue border overlay.
    @ViewBuilder
    private func boardRegularTaskSquare(boardTask: BoardTask, task: Task, isSelected: Bool) -> some View {
        ZStack {
            switch task.type {
            case .normal:
                InteractiveTaskSquareView(
                    title: task.title,
                    taskType: .normal,
                    isCompleted: boardTask.isCompleted
                )

            case .counting:
                let current = boardTask.currentCount ?? 0
                let maxVal = task.maxCount ?? 0
                let unitText = task.unit ?? ""
                InteractiveTaskSquareView(
                    title: task.title,
                    taskType: .counting,
                    isCompleted: boardTask.isCompleted,
                    currentCount: current,
                    maxCount: maxVal,
                    unit: unitText
                )

            case .progress:
                let completedCount = boardTask.completedStepIds?.count ?? 0
                let stepsForTask = boardTaskSteps.filter { $0.taskId == task.id }
                let total = stepsForTask.count
                InteractiveTaskSquareView(
                    title: task.title,
                    taskType: .progress,
                    isCompleted: boardTask.isCompleted,
                    completedSteps: completedCount,
                    totalSteps: total
                )
            }

            // Blue border overlay when selected
            if isSelected {
                RoundedRectangle(cornerRadius: 8)
                    .stroke(Color.blue, lineWidth: 3)
                    .frame(width: 90, height: 90)
                    .allowsHitTesting(false)
            }

            // Transparent tap target — intercepts taps before InteractiveTaskSquareView's
            // internal gesture (which blocks progress tile taps).
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { selectBoardTask(task) }
        }
        .frame(width: 90, height: 90)
        .contextMenu {
            if !boardPool.contains(where: { $0.taskId == task.id }) {
                Button {
                    addToPool(taskId: task.id, title: task.title, type: task.type.rawValue)
                    showBoardSuccess("Added to pool: \"\(task.title)\"")
                } label: {
                    Label("Add to Pool", systemImage: "plus.circle")
                }
            } else {
                Text("Already in Pool")
            }

            if task.type == .progress {
                let steps = boardTaskSteps.filter { $0.taskId == task.id }.sorted { $0.stepIndex < $1.stepIndex }
                if !steps.isEmpty {
                    Divider()
                    ForEach(steps, id: \.id) { step in
                        if let linkedId = step.linkedTaskId,
                           let linkedTask = libraryTasks.first(where: { $0.id == linkedId }) {
                            if boardPool.contains(where: { $0.taskId == linkedId }) {
                                Label("\(step.title) (in pool)", systemImage: "checkmark.circle")
                                    .foregroundColor(.secondary)
                            } else {
                                Button {
                                    addToPool(taskId: linkedTask.id, title: linkedTask.title, type: linkedTask.type.rawValue)
                                    showBoardSuccess("Added step: \"\(linkedTask.title)\"")
                                } label: {
                                    Label(step.title, systemImage: "plus.circle")
                                }
                            }
                        } else {
                            Label("\(step.title) (extract first)", systemImage: "exclamationmark.circle")
                                .foregroundColor(.secondary)
                        }
                    }
                }

                Divider()
                Button {
                    selectBoardTask(task)
                } label: {
                    Label("View All Steps…", systemImage: "arrow.triangle.branch")
                }
            }

            if task.type == .counting {
                Divider()
                Button {
                    selectBoardTask(task)
                } label: {
                    Label("Derive Subtask…", systemImage: "arrow.triangle.branch")
                }
            }
        }
    }

    /// Returns the appropriate derivation panel for the selected regular task in the board grid.
    ///
    /// - Parameter task: The selected Task.
    @ViewBuilder
    private func boardTaskDerivationPanel(for task: Task) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            // Add this task directly to pool
            HStack {
                Text(task.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                TypeBadgeView(type: task.type.rawValue, size: .small)
                if boardPool.contains(where: { $0.taskId == task.id }) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 24))
                        .foregroundColor(.green)
                } else {
                    Button {
                        addToPool(taskId: task.id, title: task.title, type: task.type.rawValue)
                        showBoardSuccess("Added to board pool: \"\(task.title)\"")
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.system(size: 24))
                            .foregroundColor(.accentColor)
                    }
                    .buttonStyle(.plain)
                }
            }

            // Derivation options (non-normal tasks)
            switch task.type {
            case .normal:
                EmptyView()

            case .counting:
                Divider()
                Text("Or derive a subtask:")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                CountingDerivationPanelView(
                    task: task,
                    partialCountStr: $boardPartialCountStr,
                    isCreating: deriveIsCreating,
                    onCreateSubtask: { parentTask, count in
                        createCountingSubtask(from: parentTask, count: count)
                    }
                )

            case .progress:
                Divider()
                Text("Or extract steps:")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .foregroundColor(.secondary)
                    .textCase(.uppercase)
                ProgressDerivationPanelView(
                    task: task,
                    taskSteps: boardTaskSteps,
                    allTasks: libraryTasks,
                    boardPool: boardPool,
                    isCreating: deriveIsCreating,
                    onExtractStep: { step, parentTask in
                        extractStepAsTask(step: step, parentTask: parentTask)
                    },
                    onAddStepToPool: { linkedTask in
                        addToPool(
                            taskId: linkedTask.id,
                            title: linkedTask.title,
                            type: linkedTask.type.rawValue
                        )
                        showBoardSuccess("Added to board pool: \"\(linkedTask.title)\"")
                    }
                )
            }
        }
    }

    // MARK: - From Board Tab Selection

    /// Selects a board and loads its tasks. Re-tapping the same board deselects it.
    ///
    /// - Parameter board: The Board the user selected from the picker.
    private func selectBoardForBrowse(_ board: Board) {
        if selectedBoardId == board.id {
            selectedBoardId = nil
            boardTasks = []
            boardSelectedTaskId = nil
            boardTaskSteps = []
            boardCompositeNodes = []
            return
        }
        selectedBoardId = board.id
        boardSelectedTaskId = nil
        boardTaskSteps = []
        boardCompositeNodes = []
        boardPartialCountStr = ""
        loadBoardTasksForBrowse(boardId: board.id)
    }

    /// Selects a regular task in the board grid for derivation.
    ///
    /// Steps are already eagerly loaded by `loadBoardTasksForBrowse` and kept for the grid,
    /// so this only clears composite nodes and resets the partial count.
    ///
    /// - Parameter task: The Task the user tapped.
    private func selectBoardTask(_ task: Task) {
        if boardSelectedTaskId == task.id {
            boardSelectedTaskId = nil
            boardCompositeNodes = []
            return
        }
        boardSelectedTaskId = task.id
        boardCompositeNodes = []
        boardPartialCountStr = ""
    }

    /// Selects a composite task in the board grid and loads its nodes.
    ///
    /// - Parameter ct: The CompositeTask the user tapped.
    private func selectBoardCompositeTask(_ ct: CompositeTask) {
        if boardSelectedTaskId == ct.id {
            boardSelectedTaskId = nil
            boardCompositeNodes = []
            return
        }
        boardSelectedTaskId = ct.id
        boardCompositeNodes = []
        loadBoardCompositeNodes(for: ct.id)
    }

    // MARK: - From Board Tab Data Loading

    /// Loads BoardTask records for the selected board, then eagerly loads steps for all
    /// progress tasks so progress fractions render correctly across the whole grid.
    ///
    /// - Parameter boardId: The board whose tasks should be loaded.
    private func loadBoardTasksForBrowse(boardId: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let fetched = try AppDatabase.shared.fetchBoardTasks(boardId: boardId)

                // Identify progress task IDs by querying the DB directly (avoids race with
                // the in-memory libraryTasks array which may not be refreshed yet).
                let taskIds = fetched.map(\.taskId)
                let progressTaskIds: [String] = try AppDatabase.shared.read { db in
                    try Task
                        .filter(taskIds.contains(Column("id")) && Column("type") == TaskType.progress.rawValue)
                        .fetchAll(db)
                        .map(\.id)
                }

                var allSteps: [TaskStep] = []
                for taskId in progressTaskIds {
                    let steps = try AppDatabase.shared.fetchTaskSteps(taskId: taskId)
                    allSteps.append(contentsOf: steps)
                }

                DispatchQueue.main.async {
                    self.boardTasks = fetched
                    self.boardTaskSteps = allSteps
                    self.loadError = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.loadError = "Failed to load board tasks: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Loads CompositeNode records for a given composite task in the board grid.
    ///
    /// - Parameter compositeTaskId: The composite task ID.
    private func loadBoardCompositeNodes(for compositeTaskId: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let nodes = try AppDatabase.shared.read { db in
                    try CompositeNode
                        .filter(Column("compositeTaskId") == compositeTaskId && Column("isDeleted") == false)
                        .fetchAll(db)
                }
                DispatchQueue.main.async {
                    self.boardCompositeNodes = nodes
                    self.loadError = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.loadError = "Failed to load composite nodes: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - From Board Tab Demo Creation

    /// Creates a fully populated 3x3 demo board with a mix of counting, progress, and normal tasks.
    ///
    /// The board uses 8 randomly selected tasks from a fixed 9-task pool on non-center positions;
    /// the center square is a free space. The new board is auto-selected after creation.
    private func createDemoBoard() {
        isBoardSettingUp = true

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let now = AppDatabase.currentTimestamp()

                // ── Task definitions ──

                let readTask = Task(
                    id: AppDatabase.generateUUID(), userId: playgroundUserId,
                    title: "Read 50 pages", type: .counting,
                    action: "Read", unit: "pages", maxCount: 50,
                    totalCompletions: 0, totalInstances: 0,
                    createdAt: now, updatedAt: now, version: 1, isDeleted: false
                )
                let walkTask = Task(
                    id: AppDatabase.generateUUID(), userId: playgroundUserId,
                    title: "Walk 10 km", type: .counting,
                    action: "Walk", unit: "km", maxCount: 10,
                    totalCompletions: 0, totalInstances: 0,
                    createdAt: now, updatedAt: now, version: 1, isDeleted: false
                )
                let workoutTask = Task(
                    id: AppDatabase.generateUUID(), userId: playgroundUserId,
                    title: "Weekly Workout", type: .progress,
                    totalCompletions: 0, totalInstances: 0,
                    createdAt: now, updatedAt: now, version: 1, isDeleted: false
                )
                // Step tasks for Weekly Workout
                let workoutStepTitles = ["Monday run", "Wednesday weights", "Friday yoga"]
                var workoutSteps: [TaskStep] = []
                var workoutStepTasks: [Task] = []
                for (i, stepTitle) in workoutStepTitles.enumerated() {
                    let stepTaskId = AppDatabase.generateUUID()
                    workoutStepTasks.append(Task(
                        id: stepTaskId, userId: playgroundUserId,
                        title: stepTitle, type: .normal,
                        totalCompletions: 0, totalInstances: 0,
                        createdAt: now, updatedAt: now, version: 1, isDeleted: false
                    ))
                    workoutSteps.append(TaskStep(
                        id: AppDatabase.generateUUID(), taskId: workoutTask.id,
                        stepIndex: i, title: stepTitle, type: .normal,
                        linkedTaskId: stepTaskId,
                        createdAt: now, updatedAt: now, version: 1, isDeleted: false
                    ))
                }
                let cleanTask = Task(
                    id: AppDatabase.generateUUID(), userId: playgroundUserId,
                    title: "Clean House", type: .progress,
                    totalCompletions: 0, totalInstances: 0,
                    createdAt: now, updatedAt: now, version: 1, isDeleted: false
                )
                // Step tasks for Clean House
                let cleanStepTitles = ["Vacuum", "Dust", "Mop"]
                var cleanSteps: [TaskStep] = []
                var cleanStepTasks: [Task] = []
                for (i, stepTitle) in cleanStepTitles.enumerated() {
                    let stepTaskId = AppDatabase.generateUUID()
                    cleanStepTasks.append(Task(
                        id: stepTaskId, userId: playgroundUserId,
                        title: stepTitle, type: .normal,
                        totalCompletions: 0, totalInstances: 0,
                        createdAt: now, updatedAt: now, version: 1, isDeleted: false
                    ))
                    cleanSteps.append(TaskStep(
                        id: AppDatabase.generateUUID(), taskId: cleanTask.id,
                        stepIndex: i, title: stepTitle, type: .normal,
                        linkedTaskId: stepTaskId,
                        createdAt: now, updatedAt: now, version: 1, isDeleted: false
                    ))
                }
                let normalTitles = ["Meditate", "Call a friend", "Cook dinner", "Write in journal", "Read a chapter"]
                let normalTasks = normalTitles.map { title in
                    Task(
                        id: AppDatabase.generateUUID(), userId: playgroundUserId,
                        title: title, type: .normal,
                        totalCompletions: 0, totalInstances: 0,
                        createdAt: now, updatedAt: now, version: 1, isDeleted: false
                    )
                }

                let allDemoTasks: [Task] = [readTask, walkTask, workoutTask, cleanTask] + normalTasks
                let shuffled = Shuffle.fisherYatesShuffle(allDemoTasks)
                let boardSize = 3
                let boardId = AppDatabase.generateUUID()

                let existingCount = try AppDatabase.shared.fetchBoards(userId: playgroundUserId).count
                let boardName = "Demo Board \(existingCount + 1)"
                let board = Board.makePlayground(
                    id: boardId, userId: playgroundUserId,
                    name: boardName, now: now, centerSquareType: "free"
                )

                try AppDatabase.shared.write { db in
                    try board.save(db)
                    for task in allDemoTasks { try task.save(db) }
                    for stepTask in workoutStepTasks + cleanStepTasks { try stepTask.save(db) }
                    for step in workoutSteps + cleanSteps { try step.save(db) }

                    var taskIndex = 0
                    for row in 0..<boardSize {
                        for col in 0..<boardSize {
                            let isCenter = row == 1 && col == 1
                            if isCenter { continue }
                            guard taskIndex < shuffled.count else { break }
                            let bt = BoardTask.makePlayground(
                                boardId: boardId, taskId: shuffled[taskIndex].id,
                                row: row, col: col, now: now
                            )
                            try bt.save(db)
                            taskIndex += 1
                        }
                    }
                }

                DispatchQueue.main.async {
                    self.isBoardSettingUp = false
                    self.showBoardSuccess("Created \"\(boardName)\" with 8 tasks")
                    self.loadLibrary()
                    // Defer auto-select so loadLibrary has time to populate self.boards
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        if let newBoard = self.boards.first(where: { $0.id == boardId }) {
                            self.selectBoardForBrowse(newBoard)
                        } else {
                            self.selectedBoardId = boardId
                            self.loadBoardTasksForBrowse(boardId: boardId)
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isBoardSettingUp = false
                    self.loadError = "Failed to create demo board: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - From Board Tab Helpers

    /// Shows a success banner in the From Board tab that auto-dismisses after `successDismissSeconds`.
    ///
    /// - Parameter message: The success string to display.
    private func showBoardSuccess(_ message: String) {
        boardSuccessMessage = message
        DispatchQueue.main.asyncAfter(deadline: .now() + successDismissSeconds) {
            if self.boardSuccessMessage == message {
                self.boardSuccessMessage = nil
            }
        }
    }
}
