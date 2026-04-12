import SwiftUI
import GRDB

// MARK: - Local Enums

/// The two tab modes for the Create page.
private enum CreateMode: String, CaseIterable {
    case create = "Create New"
    case existing = "Existing Tasks"
}

/// Task type picker that includes Composite alongside the three TaskType cases.
private enum CreateTaskType: String, CaseIterable {
    case normal = "Normal"
    case counting = "Counting"
    case progress = "Progress"
    case composite = "Composite"
}

/// Filter options for the Existing Tasks tab.
private enum ExistingFilter: String, CaseIterable {
    case all = "All"
    case normal = "Normal"
    case counting = "Counting"
    case progress = "Progress"
    case composite = "Composite"
}

// MARK: - CreateView

/// CreateView — Production task pool builder + board creation.
///
/// Two-tab interface:
/// - **Create New**: form for Normal/Counting/Progress tasks, plus `CompositeTaskFormView`.
///   Newly created tasks are added directly to the pool.
/// - **Existing Tasks**: filterable task library with expand/collapse derivation panels.
///
/// The Board Task Pool section is always visible at the bottom. When the pool has enough
/// tasks, `BoardCreatorPanelView` lets the user configure and create a board, then
/// navigates to `BoardPlayView`.
struct CreateView: View {

    // MARK: - Dependencies

    @EnvironmentObject var authService: AuthService

    // MARK: - Navigation

    @State private var navigateToBoardId: String?

    // MARK: - Mode State

    @State private var mode: CreateMode = .create

    // MARK: - Create Tab State

    @State private var createTaskType: CreateTaskType = .normal
    @State private var createTitle = ""
    @State private var createDescription = ""
    @State private var createCountingAction = ""
    @State private var createCountingUnit = ""
    @State private var createCountingMaxCount = ""
    @State private var createProgressSteps: [ProgressStepFormState] = [ProgressStepFormState()]
    @State private var createProgressStepErrors: [UUID: ProgressStepFormErrors] = [:]
    @State private var createIsSubmitting = false
    @State private var createErrorMessage: String?
    @State private var createSuccessMessage: String?

    /// Maps `createTaskType` to a concrete `TaskType`. Returns `nil` for `.composite`.
    private var createSelectedType: TaskType? {
        switch createTaskType {
        case .normal:    return .normal
        case .counting:  return .counting
        case .progress:  return .progress
        case .composite: return nil
        }
    }

    // MARK: - Existing Tab State

    @State private var existingFilter: ExistingFilter = .all
    @State private var expandedTaskId: String?
    @State private var expandedCompositeTaskId: String?
    @State private var deriveTaskSteps: [TaskStep] = []
    @State private var deriveCompositeNodes: [CompositeNode] = []
    @State private var derivePartialCountStr: String = ""
    @State private var deriveIsCreating: Bool = false

    // MARK: - Library State

    @State private var libraryTasks: [Task] = []
    @State private var libraryCompositeTasks: [CompositeTask] = []
    @State private var allLibraryTaskSteps: [TaskStep] = []
    @State private var loadError: String?

    // MARK: - Pool State

    @State private var boardPool: [(taskId: String, title: String, type: String)] = []

    // MARK: - Computed

    private var existingFilteredTasks: [Task] {
        switch existingFilter {
        case .all:       return libraryTasks
        case .normal:    return libraryTasks.filter { $0.type == .normal }
        case .counting:  return libraryTasks.filter { $0.type == .counting }
        case .progress:  return libraryTasks.filter { $0.type == .progress }
        case .composite: return []
        }
    }

    private var existingFilteredComposites: [CompositeTask] {
        switch existingFilter {
        case .all, .composite: return libraryCompositeTasks
        default:               return []
        }
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // Mode picker
                HStack {
                    Picker("Mode", selection: $mode) {
                        ForEach(CreateMode.allCases, id: \.self) { m in
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

                // Tab content
                switch mode {
                case .create:
                    createTab
                case .existing:
                    existingTab
                }

                // Pool section
                Divider()
                poolSection

                // Board Creator
                if !boardPool.isEmpty, let userId = authService.currentUser?.id {
                    Divider()
                    BoardCreatorPanelView(
                        boardPool: boardPool,
                        libraryTasks: libraryTasks,
                        allTaskSteps: allLibraryTaskSteps,
                        userId: userId,
                        onBoardCreated: { boardId in
                            navigateToBoardId = boardId
                        }
                    )
                }
            }
            .padding(.horizontal)
        }
        .navigationTitle("Create")
        .navigationDestination(item: $navigateToBoardId) { boardId in
            BoardPlayView(boardId: boardId)
        }
        .onAppear {
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
                ForEach(CreateTaskType.allCases, id: \.self) { pt in
                    Text(pt.rawValue).tag(pt)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: createTaskType) {
                clearCreateFeedback()
            }

            if createTaskType == .composite {
                if let userId = authService.currentUser?.id {
                    CompositeTaskFormView(userId: userId, onCreated: { compositeTask in
                        addToPool(
                            taskId: compositeTask.id,
                            title: compositeTask.title,
                            type: "composite"
                        )
                        loadLibrary()
                    })
                }
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

            // Type filter pills
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

    /// A single task row in the Existing Tasks tab.
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

    /// A single composite task row in the Existing Tasks tab.
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

    // MARK: - Derive Panel

    @ViewBuilder
    private func derivePanel(for task: Task) -> some View {
        Group {
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
    private func handleCreateAndAddToPool() {
        guard let userId = authService.currentUser?.id else { return }
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
            userId: userId,
            type: resolvedType,
            title: resolvedTitle,
            desc: trimmedDesc.isEmpty ? nil : trimmedDesc,
            now: now
        )
        let newSteps: [TaskStep] = resolvedType == .progress
            ? buildCreateSteps(taskId: taskId, userId: userId, now: now)
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
                                userId: userId,
                                title: step.title,
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
                            try stepTask.save(db)
                            step.linkedTaskId = stepTaskId
                            try step.save(db)
                        }
                    }
                }
                DispatchQueue.main.async {
                    self.createIsSubmitting = false
                    self.addToPool(taskId: taskId, title: resolvedTitle, type: resolvedType.rawValue)
                    self.createSuccessMessage = "Created & added to pool: \"\(resolvedTitle)\""
                    self.resetCreateForm()
                    self.loadLibrary()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        if self.createSuccessMessage == "Created & added to pool: \"\(resolvedTitle)\"" {
                            self.createSuccessMessage = nil
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.createIsSubmitting = false
                    self.createErrorMessage = "Failed: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Builds a Task value for the create form.
    private func buildCreateTask(id: String, userId: String, type: TaskType, title: String, desc: String?, now: String) -> Task {
        switch type {
        case .normal:
            return Task(
                id: id, userId: userId, title: title, description: desc,
                type: .normal, totalCompletions: 0, totalInstances: 0,
                createdAt: now, updatedAt: now, version: 1, isDeleted: false
            )
        case .counting:
            let a = createCountingAction.trimmingCharacters(in: .whitespacesAndNewlines)
            let u = createCountingUnit.trimmingCharacters(in: .whitespacesAndNewlines)
            let m = Int(createCountingMaxCount.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            return Task(
                id: id, userId: userId, title: title, description: desc,
                type: .counting, action: a, unit: u, maxCount: m,
                totalCompletions: 0, totalInstances: 0,
                createdAt: now, updatedAt: now, version: 1, isDeleted: false
            )
        case .progress:
            return Task(
                id: id, userId: userId, title: title, description: desc,
                type: .progress, totalCompletions: 0, totalInstances: 0,
                createdAt: now, updatedAt: now, version: 1, isDeleted: false
            )
        }
    }

    /// Builds TaskStep values from the Create tab progress step form state.
    private func buildCreateSteps(taskId: String, userId: String, now: String) -> [TaskStep] {
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
                type: stepForm.type == .counting ? .counting : .normal,
                action: stepForm.type == .counting ? trimmedAction : nil,
                unit: stepForm.type == .counting ? trimmedUnit : nil,
                maxCount: stepForm.type == .counting ? Int(stepForm.maxCount.trimmingCharacters(in: .whitespacesAndNewlines)) : nil,
                createdAt: now,
                updatedAt: now,
                version: 1,
                isDeleted: false
            )
        }
    }

    // MARK: - Existing Tab Actions

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

    private func clearExpandedState() {
        expandedTaskId = nil
        expandedCompositeTaskId = nil
        derivePartialCountStr = ""
        deriveTaskSteps = []
        deriveCompositeNodes = []
    }

    private func createCountingSubtask(from parentTask: Task, count: Int) {
        guard let userId = authService.currentUser?.id,
              let action = parentTask.action, let unit = parentTask.unit else { return }
        deriveIsCreating = true
        let title = "\(action) \(count) \(unit)"
        let now = AppDatabase.currentTimestamp()
        let newTask = Task(
            id: AppDatabase.generateUUID(),
            userId: userId,
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

    private func extractStepAsTask(step: TaskStep, parentTask: Task) {
        guard let userId = authService.currentUser?.id else { return }

        if let linkedId = step.linkedTaskId,
           let linkedTask = libraryTasks.first(where: { $0.id == linkedId }) {
            addToPool(taskId: linkedTask.id, title: linkedTask.title, type: linkedTask.type.rawValue)
            return
        }

        deriveIsCreating = true
        let now = AppDatabase.currentTimestamp()
        let newTask = Task(
            id: AppDatabase.generateUUID(),
            userId: userId,
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

    private func addToPool(taskId: String, title: String, type: String) {
        guard !boardPool.contains(where: { $0.taskId == taskId }) else { return }
        boardPool.append((taskId: taskId, title: title, type: type))
    }

    // MARK: - Form Helpers

    private func resetCreateForm() {
        createTitle = ""
        createDescription = ""
        createCountingAction = ""
        createCountingUnit = ""
        createCountingMaxCount = ""
        createProgressSteps = [ProgressStepFormState()]
        createProgressStepErrors = [:]
    }

    private func clearCreateFeedback() {
        createErrorMessage = nil
        createSuccessMessage = nil
    }

    // MARK: - Data Loading

    private func loadLibrary() {
        guard let userId = authService.currentUser?.id else { return }
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let fetched = try AppDatabase.shared.fetchTasks(userId: userId)
                let composites = try AppDatabase.shared.read { db in
                    try CompositeTask
                        .filter(Column("userId") == userId && Column("isDeleted") == false)
                        .order(Column("title"))
                        .fetchAll(db)
                }
                let fetchedSteps = try AppDatabase.shared.fetchAllTaskSteps(userId: userId)
                DispatchQueue.main.async {
                    self.libraryTasks = fetched
                    self.libraryCompositeTasks = composites
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
}

// MARK: - Helpers

/// Makes String conform to Identifiable for use with `.navigationDestination(item:)`.
extension String: @retroactive Identifiable {
    public var id: String { self }
}

#Preview {
    NavigationStack {
        CreateView()
            .environmentObject(AuthService())
    }
}
