import SwiftUI

// MARK: - PlaygroundTaskType

/// Wrapper type for the task-type picker that includes Composite alongside the three TaskType cases.
///
/// Composite tasks are NOT a `TaskType`; they live in their own `composite_tasks` table.
/// This enum lets the playground picker treat all four as a single selection.
private enum PlaygroundTaskType: String, CaseIterable {
    case normal = "Normal"
    case counting = "Counting"
    case progress = "Progress"
    case composite = "Composite"
}

// MARK: - Unified Task Creator Playground

/// Unified Task Creator + Task Library for Playground testing.
///
/// Provides a single form that handles Normal, Counting, Progress, and Composite task
/// creation, plus a filterable library showing all tasks for the test user.
///
/// - Normal: title + optional description only.
/// - Counting: shared fields + action, unit, maxCount.
/// - Progress: shared fields + steps section (each step is Normal or Counting).
/// - Composite: title + flat subtask list with operator (via CompositeTaskFormView).
///
/// On valid submission the task (and steps for Progress) are written to the local
/// database via AppDatabase.shared, then the library is refreshed automatically.
struct UnifiedTaskCreatorPlayground: View {
    // MARK: - Form State

    @State private var playgroundTaskType: PlaygroundTaskType = .normal

    /// Maps the current `playgroundTaskType` to the corresponding `TaskType` for
    /// Normal / Counting / Progress logic. Returns `nil` for `.composite`.
    private var selectedType: TaskType? {
        switch playgroundTaskType {
        case .normal:    return .normal
        case .counting:  return .counting
        case .progress:  return .progress
        case .composite: return nil
        }
    }

    // Shared fields
    @State private var title = ""
    @State private var taskDescription = ""

    // Counting-specific fields
    @State private var countingAction = ""
    @State private var countingUnit = ""
    @State private var countingMaxCount = ""

    // Progress-specific fields
    @State private var progressSteps: [ProgressStepFormState] = [ProgressStepFormState()]

    // Submission state
    @State private var isSubmitting = false
    @State private var successMessage: String?
    @State private var errorMessage: String?
    @State private var progressStepErrors: [UUID: ProgressStepFormErrors] = [:]

    // MARK: - Library State

    @State private var libraryTasks: [Task] = []
    @State private var librarySteps: [String: [TaskStep]] = [:]
    @State private var libraryCompositeTasks: [CompositeTask] = []
    @State private var selectedFilter: TaskType? = nil  // nil = All; use isCompositeFilter for composite
    @State private var isCompositeFilter: Bool = false

    // MARK: - Computed

    private var filteredTasks: [Task] {
        if isCompositeFilter { return [] }
        guard let filter = selectedFilter else { return libraryTasks }
        return libraryTasks.filter { $0.type == filter }
    }

    private var filteredCompositeTasks: [CompositeTask] {
        guard isCompositeFilter || selectedFilter == nil else { return [] }
        return libraryCompositeTasks
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // ── Creation Form ──
            VStack(alignment: .leading, spacing: 12) {
                Text("Create Task")
                    .font(.headline)

                // Task type picker
                Picker("Task Type", selection: $playgroundTaskType) {
                    ForEach(PlaygroundTaskType.allCases, id: \.self) { pt in
                        Text(pt.rawValue).tag(pt)
                    }
                }
                .pickerStyle(.segmented)
                .onChange(of: playgroundTaskType) {
                    errorMessage = nil
                }

                if playgroundTaskType == .composite {
                    // Composite task creation is fully handled by CompositeTaskFormView
                    CompositeTaskFormView()
                } else {
                    // Title (required for Normal/Progress; optional/auto-generated for Counting)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField(
                            selectedType == .counting ? "Title (auto-generated if blank)" : "Title (required)",
                            text: $title
                        )
                        .textFieldStyle(.roundedBorder)
                        Text("\(title.count)/200")
                            .font(.caption)
                            .foregroundColor(title.count > 200 ? .red : .secondary)
                    }

                    // Description (optional, max 1000)
                    VStack(alignment: .leading, spacing: 4) {
                        TextField("Description (optional)", text: $taskDescription, axis: .vertical)
                            .textFieldStyle(.roundedBorder)
                            .lineLimit(3...)
                        Text("\(taskDescription.count)/1000")
                            .font(.caption)
                            .foregroundColor(taskDescription.count > 1000 ? .red : .secondary)
                    }

                    // Counting-specific fields
                    if selectedType == .counting {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Counting Details")
                                .font(.subheadline)
                                .fontWeight(.semibold)

                            VStack(alignment: .leading, spacing: 4) {
                                TextField("Action (e.g. Run, Read)", text: $countingAction)
                                    .textFieldStyle(.roundedBorder)
                                Text("\(countingAction.count)/50")
                                    .font(.caption)
                                    .foregroundColor(countingAction.count > 50 ? .red : .secondary)
                            }

                            TextField("Max Count (positive integer)", text: $countingMaxCount)
                                .textFieldStyle(.roundedBorder)
                                .keyboardType(.numberPad)

                            VStack(alignment: .leading, spacing: 4) {
                                TextField("Unit (e.g. miles, pages)", text: $countingUnit)
                                    .textFieldStyle(.roundedBorder)
                                Text("\(countingUnit.count)/50")
                                    .font(.caption)
                                    .foregroundColor(countingUnit.count > 50 ? .red : .secondary)
                            }
                        }
                        .padding(8)
                        .background(Color(.systemGray5))
                        .cornerRadius(6)
                    }

                    // Progress-specific fields
                    if selectedType == .progress {
                        VStack(alignment: .leading, spacing: 8) {
                            Text("Steps")
                                .font(.subheadline)
                                .fontWeight(.semibold)

                            ForEach(progressSteps.indices, id: \.self) { i in
                                ProgressStepRowView(
                                    index: i,
                                    step: $progressSteps[i],
                                    stepCount: progressSteps.count,
                                    errors: progressStepErrors[progressSteps[i].id],
                                    onRemove: { progressSteps.remove(at: i) }
                                )
                            }

                            Button("Add Step") {
                                progressSteps.append(ProgressStepFormState())
                            }
                            .font(.subheadline)
                        }
                    }

                    // Error message
                    if let error = errorMessage {
                        Text(error)
                            .foregroundColor(.red)
                            .font(.caption)
                    }

                    // Success message
                    if let success = successMessage {
                        Text(success)
                            .foregroundColor(.green)
                            .font(.caption)
                    }

                    // Create button
                    Button("Create Task") {
                        handleCreateTask()
                    }
                    .buttonStyle(.borderedProminent)
                    .disabled(isSubmitting)
                }
            }

            Divider()

            // ── Task Library ──
            VStack(alignment: .leading, spacing: 8) {
                Text("Task Library")
                    .font(.headline)

                // Type filter
                ScrollView(.horizontal, showsIndicators: false) {
                    HStack(spacing: 8) {
                        filterButton(label: "All", filter: nil)
                        filterButton(label: "Normal", filter: .normal)
                        filterButton(label: "Counting", filter: .counting)
                        filterButton(label: "Progress", filter: .progress)
                        compositeFilterButton
                    }
                }

                if filteredTasks.isEmpty && filteredCompositeTasks.isEmpty {
                    Text("No tasks yet — create one above")
                        .foregroundColor(.secondary)
                        .font(.subheadline)
                } else {
                    ForEach(filteredTasks, id: \.id) { task in
                        taskRow(task)
                    }
                    ForEach(filteredCompositeTasks, id: \.id) { ct in
                        compositeRow(ct)
                    }
                }
            }
        }
        .onAppear {
            ensurePlaygroundUser()
            loadLibrary()
        }
    }

    // MARK: - Sub-views

    /// Renders a filter toggle button for the Task Library type picker.
    ///
    /// - Parameters:
    ///   - label: The display label for this filter.
    ///   - filter: The TaskType to filter by, or nil for "All".
    @ViewBuilder
    private var compositeFilterButton: some View {
        Button("Composite") {
            isCompositeFilter = true
            selectedFilter = nil
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isCompositeFilter ? Color.indigo : Color(.systemGray5))
        .foregroundColor(isCompositeFilter ? .white : .primary)
        .cornerRadius(6)
    }

    private func filterButton(label: String, filter: TaskType?) -> some View {
        let isActive = !isCompositeFilter && selectedFilter == filter
        Button(label) {
            selectedFilter = filter
            isCompositeFilter = false
        }
        .font(.caption)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
        .background(isActive ? Color.accentColor : Color(.systemGray5))
        .foregroundColor(isActive ? .white : .primary)
        .cornerRadius(6)
    }

    /// Renders a single task row in the Task Library.
    ///
    /// - Parameter task: The Task to display.
    @ViewBuilder
    private func taskRow(_ task: Task) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(task.title)
                    .font(.headline)
                Spacer()
                typeBadge(for: task.type)
            }
            if let desc = task.description, !desc.isEmpty {
                Text(desc)
                    .font(.body)
                    .foregroundColor(.secondary)
            }
            switch task.type {
            case .counting:
                if let action = task.action, let unit = task.unit, let maxCount = task.maxCount {
                    Text("\(action) \(unit) (max: \(maxCount))")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                }
            case .progress:
                let steps = librarySteps[task.id] ?? []
                if steps.isEmpty {
                    Text("No steps")
                        .font(.subheadline)
                        .foregroundColor(.secondary)
                } else {
                    VStack(alignment: .leading, spacing: 3) {
                        ForEach(steps.sorted(by: { $0.stepIndex < $1.stepIndex }), id: \.id) { step in
                            HStack(spacing: 4) {
                                Text("\(step.stepIndex + 1).")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                Text(step.title)
                                    .font(.subheadline)
                                Spacer()
                                typeBadge(for: step.type)
                            }
                            if step.type == .counting,
                               let action = step.action,
                               let maxCount = step.maxCount,
                               let unit = step.unit {
                                Text("\(action) \(maxCount) \(unit)")
                                    .font(.caption)
                                    .foregroundColor(.secondary)
                                    .padding(.leading, 16)
                            }
                        }
                    }
                }
            case .normal:
                EmptyView()
            }
        }
        .padding(12)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }

    /// Renders a single composite task row in the Task Library.
    ///
    /// - Parameter ct: The CompositeTask to display.
    @ViewBuilder
    private func compositeRow(_ ct: CompositeTask) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text(ct.title)
                    .font(.headline)
                Spacer()
                Text("COMPOSITE")
                    .font(.caption)
                    .padding(.horizontal, 6)
                    .padding(.vertical, 2)
                    .background(Color.indigo.opacity(0.2))
                    .cornerRadius(4)
            }
            if let desc = ct.description, !desc.isEmpty {
                Text(desc)
                    .font(.body)
                    .foregroundColor(.secondary)
            }
        }
        .padding(12)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }

    /// Renders a colored type badge label.
    ///
    /// - Parameter type: The TaskType to render a badge for.
    @ViewBuilder
    private func typeBadge(for type: TaskType) -> some View {
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

    // MARK: - Actions

    /// Validates all form fields for the current task type and writes to the database.
    ///
    /// Normal: title required, char limits enforced.
    /// Counting: shared fields + action/unit (required, ≤50), maxCount (positive integer).
    /// Progress: shared fields + at least one step; each step title required; counting steps need action/unit/maxCount.
    private func handleCreateTask() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)
        let trimmedDesc = taskDescription.trimmingCharacters(in: .whitespacesAndNewlines)

        // Composite tasks are handled by CompositeTaskFormView, not this method
        guard let resolvedTaskType = selectedType else { return }

        // Title required for Normal and Progress; optional for Counting (auto-generated)
        if resolvedTaskType != .counting {
            guard !trimmedTitle.isEmpty else {
                errorMessage = "Title is required"
                return
            }
        }
        guard trimmedTitle.count <= 200 else {
            errorMessage = "Title must be 200 characters or less"
            return
        }
        guard trimmedDesc.count <= 1000 else {
            errorMessage = "Description must be 1000 characters or less"
            return
        }

        // Type-specific validation
        switch resolvedTaskType {
        case .normal:
            break // No extra fields

        case .counting:
            let trimmedAction = countingAction.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedUnit = countingUnit.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedMax = countingMaxCount.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !trimmedAction.isEmpty else {
                errorMessage = "Action is required for Counting tasks"
                return
            }
            guard trimmedAction.count <= 50 else {
                errorMessage = "Action must be 50 characters or less"
                return
            }
            guard !trimmedUnit.isEmpty else {
                errorMessage = "Unit is required for Counting tasks"
                return
            }
            guard trimmedUnit.count <= 50 else {
                errorMessage = "Unit must be 50 characters or less"
                return
            }
            guard let _ = Int(trimmedMax), (Int(trimmedMax) ?? 0) > 0 else {
                errorMessage = "Max Count must be a positive integer"
                return
            }

        case .progress:
            var newStepErrors: [UUID: ProgressStepFormErrors] = [:]
            for step in progressSteps {
                var stepErr = ProgressStepFormErrors()
                if step.type != .counting && step.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    stepErr.title = "Step title is required"
                }
                if step.type == .counting {
                    if step.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        stepErr.action = "Action is required"
                    }
                    if step.unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                        stepErr.unit = "Unit is required"
                    }
                    let count = Int(step.maxCount.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                    if count <= 0 { stepErr.maxCount = "Must be a positive number" }
                }
                if stepErr.hasErrors { newStepErrors[step.id] = stepErr }
            }
            progressStepErrors = newStepErrors
            if !newStepErrors.isEmpty {
                errorMessage = "Please fix the errors below"
                return
            }
        }

        isSubmitting = true
        errorMessage = nil

        let now = AppDatabase.currentTimestamp()
        let taskId = AppDatabase.generateUUID()

        // For Counting tasks, auto-generate title from action/maxCount/unit if left blank
        // Mirror of generateCounterTaskTitle in packages/shared/src/algorithms/taskTitle.ts
        let resolvedTitle: String
        if resolvedTaskType == .counting && trimmedTitle.isEmpty {
            let trimmedAction = countingAction.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedUnit = countingUnit.trimmingCharacters(in: .whitespacesAndNewlines)
            let maxCount = Int(countingMaxCount.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            resolvedTitle = "\(trimmedAction) \(maxCount) \(trimmedUnit)"
        } else {
            resolvedTitle = trimmedTitle
        }

        let newTask = buildTask(
            id: taskId,
            resolvedTaskType: resolvedTaskType,
            trimmedTitle: resolvedTitle,
            trimmedDesc: trimmedDesc.isEmpty ? nil : trimmedDesc,
            now: now
        )
        let newSteps: [TaskStep] = resolvedTaskType == .progress
            ? buildSteps(taskId: taskId, now: now)
            : []

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                if newSteps.isEmpty {
                    try AppDatabase.shared.saveTask(newTask)
                } else {
                    try AppDatabase.shared.write { db in
                        try newTask.save(db)
                        for step in newSteps {
                            try step.save(db)
                        }
                    }
                }
                DispatchQueue.main.async {
                    resetForm()
                    successMessage = "Task created successfully!"
                    loadLibrary()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        successMessage = nil
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = "Failed to create task: \(error.localizedDescription)"
                    isSubmitting = false
                }
            }
        }
    }

    /// Builds a Task value from validated form state.
    ///
    /// - Parameters:
    ///   - id: Pre-generated UUID string.
    ///   - resolvedTaskType: The concrete TaskType (never nil; caller has already guarded).
    ///   - trimmedTitle: Validated, trimmed title.
    ///   - trimmedDesc: Validated, trimmed description (nil if empty).
    ///   - now: ISO8601 timestamp for createdAt/updatedAt.
    /// - Returns: A Task ready to persist.
    private func buildTask(id: String, resolvedTaskType: TaskType, trimmedTitle: String, trimmedDesc: String?, now: String) -> Task {
        switch resolvedTaskType {
        case .normal:
            return Task(
                id: id,
                userId: playgroundUserId,
                title: trimmedTitle,
                description: trimmedDesc,
                type: .normal,
                totalCompletions: 0,
                totalInstances: 0,
                createdAt: now,
                updatedAt: now,
                version: 1,
                isDeleted: false
            )
        case .counting:
            let trimmedAction = countingAction.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedUnit = countingUnit.trimmingCharacters(in: .whitespacesAndNewlines)
            let maxCount = Int(countingMaxCount.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
            return Task(
                id: id,
                userId: playgroundUserId,
                title: trimmedTitle,
                description: trimmedDesc,
                type: .counting,
                action: trimmedAction,
                unit: trimmedUnit,
                maxCount: maxCount,
                totalCompletions: 0,
                totalInstances: 0,
                createdAt: now,
                updatedAt: now,
                version: 1,
                isDeleted: false
            )
        case .progress:
            return Task(
                id: id,
                userId: playgroundUserId,
                title: trimmedTitle,
                description: trimmedDesc,
                type: .progress,
                totalCompletions: 0,
                totalInstances: 0,
                createdAt: now,
                updatedAt: now,
                version: 1,
                isDeleted: false
            )
        }
    }

    /// Builds TaskStep values from validated progress step form state.
    ///
    /// - Parameters:
    ///   - taskId: The parent task ID.
    ///   - now: ISO8601 timestamp.
    /// - Returns: Array of TaskStep values ready to persist.
    private func buildSteps(taskId: String, now: String) -> [TaskStep] {
        return progressSteps.enumerated().map { index, stepForm in
            let trimmedAction = stepForm.action.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedUnit = stepForm.unit.trimmingCharacters(in: .whitespacesAndNewlines)
            let trimmedStepTitle = stepForm.title.trimmingCharacters(in: .whitespacesAndNewlines)
            let resolvedStepTitle: String
            if stepForm.type == .counting && trimmedStepTitle.isEmpty {
                let maxCount = Int(stepForm.maxCount.trimmingCharacters(in: .whitespacesAndNewlines)) ?? 0
                resolvedStepTitle = "\(trimmedAction) \(maxCount) \(trimmedUnit)"
            } else {
                resolvedStepTitle = trimmedStepTitle
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

    /// Resets all form fields to their initial state after a successful submission.
    private func resetForm() {
        playgroundTaskType = .normal
        title = ""
        taskDescription = ""
        countingAction = ""
        countingUnit = ""
        countingMaxCount = ""
        progressSteps = [ProgressStepFormState()]
        progressStepErrors = [:]
        isSubmitting = false
    }

    /// Ensures the playground user exists in the users table (required by FK constraint on tasks).
    private func ensurePlaygroundUser() {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                if try AppDatabase.shared.fetchUser(id: playgroundUserId) == nil {
                    let user = User(
                        id: playgroundUserId,
                        email: "playground@oybc.local",
                        displayName: "Playground User",
                        photoURL: nil,
                        createdAt: AppDatabase.currentTimestamp(),
                        updatedAt: AppDatabase.currentTimestamp(),
                        lastSyncedAt: nil,
                        version: 1
                    )
                    try AppDatabase.shared.saveUser(user)
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Setup error: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Loads all tasks and composite tasks for the playground user from the local database.
    private func loadLibrary() {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let fetched = try AppDatabase.shared.fetchTasks(userId: playgroundUserId)
                var steps: [String: [TaskStep]] = [:]
                for task in fetched where task.type == .progress {
                    steps[task.id] = try AppDatabase.shared.fetchTaskSteps(taskId: task.id)
                }
                let composites = try AppDatabase.shared.read { db in
                    try CompositeTask
                        .filter(Column("userId") == playgroundUserId && Column("isDeleted") == false)
                        .order(Column("updatedAt").desc)
                        .fetchAll(db)
                }
                DispatchQueue.main.async {
                    self.libraryTasks = fetched
                    self.librarySteps = steps
                    self.libraryCompositeTasks = composites
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Failed to load tasks"
                }
            }
        }
    }
}
