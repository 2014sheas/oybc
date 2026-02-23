import SwiftUI

/// Feature item structure for collapsible sections
struct Feature: Identifiable {
    let id: String
    let title: String
    let content: AnyView
}

// MARK: - Progress Step Form State

/// Form state for a single step in a progress task creation form.
struct ProgressStepFormState: Identifiable {
    let id = UUID()
    var title: String = ""
    var type: TaskType = .normal
    var action: String = ""
    var unit: String = ""
    var maxCount: String = ""
}

// MARK: - Progress Task Creation Playground

/// PROGRESS Task Creation form and task list for Playground testing.
///
/// Allows creating PROGRESS tasks with a title, optional description, and
/// one or more steps (each of which can be normal or counting). Validates
/// input, persists task and steps to local database in a single transaction,
/// and displays created progress tasks with their steps.
struct ProgressTaskCreationPlayground: View {
    @State private var title = ""
    @State private var taskDescription = ""
    @State private var steps: [ProgressStepFormState] = [ProgressStepFormState()]
    @State private var isSubmitting = false
    @State private var successMessage: String?
    @State private var errorMessage: String?
    @State private var createdTasks: [(task: Task, steps: [TaskStep])] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // -- Creation Form --
            VStack(alignment: .leading, spacing: 12) {
                // Title field (required)
                TextField("Progress task title", text: $title)
                    .textFieldStyle(.roundedBorder)

                // Description field (optional)
                TextField("Description (optional)", text: $taskDescription, axis: .vertical)
                    .textFieldStyle(.roundedBorder)
                    .lineLimit(3...)

                // Steps section
                VStack(alignment: .leading, spacing: 8) {
                    Text("Steps")
                        .font(.headline)

                    ForEach(steps.indices, id: \.self) { i in
                        VStack(alignment: .leading, spacing: 8) {
                            HStack {
                                Text("Step \(i + 1)")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                Spacer()
                                if steps.count > 1 {
                                    Button("Remove") {
                                        steps.remove(at: i)
                                    }
                                    .foregroundColor(.red)
                                    .font(.caption)
                                }
                            }

                            TextField("Step title", text: $steps[i].title)
                                .textFieldStyle(.roundedBorder)

                            Picker("Type", selection: $steps[i].type) {
                                Text("Normal").tag(TaskType.normal)
                                Text("Counting").tag(TaskType.counting)
                            }
                            .pickerStyle(.segmented)

                            if steps[i].type == .counting {
                                TextField("Action (e.g. Read)", text: $steps[i].action)
                                    .textFieldStyle(.roundedBorder)
                                TextField("Unit (e.g. pages)", text: $steps[i].unit)
                                    .textFieldStyle(.roundedBorder)
                                TextField("Max count", text: $steps[i].maxCount)
                                    .textFieldStyle(.roundedBorder)
                                    .keyboardType(.numberPad)
                            }
                        }
                        .padding(8)
                        .background(Color(.systemGray5))
                        .cornerRadius(6)
                    }

                    Button("Add Step") {
                        steps.append(ProgressStepFormState())
                    }
                    .font(.subheadline)
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
                Button("Create Progress Task") {
                    handleCreateProgressTask()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isSubmitting)
            }

            Divider()

            // -- Progress Task List --
            VStack(alignment: .leading, spacing: 8) {
                if createdTasks.isEmpty {
                    Text("No progress tasks created yet.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(createdTasks, id: \.task.id) { entry in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(entry.task.title)
                                    .font(.headline)
                                Spacer()
                                Text("PROGRESS")
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.purple.opacity(0.2))
                                    .cornerRadius(4)
                            }
                            if let desc = entry.task.description {
                                Text(desc)
                                    .font(.body)
                            }
                            ForEach(entry.steps.sorted(by: { $0.stepIndex < $1.stepIndex }), id: \.id) { step in
                                HStack(spacing: 4) {
                                    Text("\(step.stepIndex + 1).")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                    Text(step.title)
                                        .font(.subheadline)
                                    if step.type == .counting {
                                        Text("COUNTING")
                                            .font(.caption2)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Color.orange.opacity(0.2))
                                            .cornerRadius(3)
                                        if let action = step.action, let maxCount = step.maxCount, let unit = step.unit {
                                            Text("\(action) \(maxCount) \(unit)")
                                                .font(.caption)
                                                .foregroundColor(.secondary)
                                        }
                                    } else {
                                        Text("NORMAL")
                                            .font(.caption2)
                                            .padding(.horizontal, 4)
                                            .padding(.vertical, 1)
                                            .background(Color.blue.opacity(0.2))
                                            .cornerRadius(3)
                                    }
                                }
                            }
                            Text("Created: \(formatDate(entry.task.createdAt))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(12)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                    }
                }
            }
        }
        .onAppear {
            ensurePlaygroundUser()
            loadProgressTasks()
        }
    }

    // MARK: - Actions

    /// Validates input and creates a PROGRESS task with steps in the local database.
    ///
    /// Saves the parent task and all steps in a single database transaction.
    /// Database write is dispatched to a background thread to avoid blocking the main thread.
    private func handleCreateProgressTask() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedTitle.isEmpty else {
            errorMessage = "Title is required"
            return
        }

        for (i, step) in steps.enumerated() {
            guard !step.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                errorMessage = "Step \(i + 1) title is required"
                return
            }
            if step.type == .counting {
                guard !step.action.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    errorMessage = "Step \(i + 1): Action is required for counting steps"
                    return
                }
                guard !step.unit.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else {
                    errorMessage = "Step \(i + 1): Unit is required for counting steps"
                    return
                }
                guard let count = Int(step.maxCount.trimmingCharacters(in: .whitespacesAndNewlines)), count > 0 else {
                    errorMessage = "Step \(i + 1): Max count must be a positive number"
                    return
                }
            }
        }

        isSubmitting = true
        errorMessage = nil

        let now = AppDatabase.currentTimestamp()
        let taskId = AppDatabase.generateUUID()

        let newTask = Task(
            id: taskId,
            userId: "playground-user-1",
            title: trimmedTitle,
            description: taskDescription.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
                ? nil
                : taskDescription.trimmingCharacters(in: .whitespacesAndNewlines),
            type: .progress,
            totalCompletions: 0,
            totalInstances: 0,
            createdAt: now,
            updatedAt: now,
            version: 1,
            isDeleted: false
        )

        var taskSteps: [TaskStep] = []
        for (index, stepForm) in steps.enumerated() {
            let step = TaskStep(
                id: AppDatabase.generateUUID(),
                taskId: taskId,
                stepIndex: index,
                title: stepForm.title.trimmingCharacters(in: .whitespacesAndNewlines),
                type: stepForm.type,
                action: stepForm.type == .counting
                    ? stepForm.action.trimmingCharacters(in: .whitespacesAndNewlines)
                    : nil,
                unit: stepForm.type == .counting
                    ? stepForm.unit.trimmingCharacters(in: .whitespacesAndNewlines)
                    : nil,
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
            taskSteps.append(step)
        }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try AppDatabase.shared.write { db in
                    try newTask.save(db)
                    for step in taskSteps {
                        try step.save(db)
                    }
                }
                DispatchQueue.main.async {
                    self.title = ""
                    self.taskDescription = ""
                    self.steps = [ProgressStepFormState()]
                    self.isSubmitting = false
                    self.successMessage = "Progress task created!"
                    self.loadProgressTasks()
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self.successMessage = nil
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Failed to create task: \(error.localizedDescription)"
                    self.isSubmitting = false
                }
            }
        }
    }

    /// Ensures the playground user exists in the users table (required by FK constraint on tasks).
    private func ensurePlaygroundUser() {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                if try AppDatabase.shared.fetchUser(id: "playground-user-1") == nil {
                    let user = User(
                        id: "playground-user-1",
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

    /// Loads progress tasks for the playground user from the local database.
    private func loadProgressTasks() {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let allTasks = try AppDatabase.shared.fetchTasks(userId: "playground-user-1")
                let progressTasks = allTasks.filter { $0.type == .progress }

                var result: [(task: Task, steps: [TaskStep])] = []
                for task in progressTasks {
                    let taskSteps = try AppDatabase.shared.fetchTaskSteps(taskId: task.id)
                    result.append((task: task, steps: taskSteps))
                }

                DispatchQueue.main.async {
                    self.createdTasks = result
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Failed to load tasks"
                }
            }
        }
    }

    private static let isoFormatter = ISO8601DateFormatter()
    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// Formats an ISO8601 string into a medium-style date with time for display.
    ///
    /// - Parameter iso: An ISO8601 date string.
    /// - Returns: A human-readable date string with time, or the original string if parsing fails.
    private func formatDate(_ iso: String) -> String {
        guard let date = Self.isoFormatter.date(from: iso) else { return iso }
        return Self.displayFormatter.string(from: date)
    }
}

// MARK: - Counter Task Creation Playground

/// COUNTING Task Creation form and task list for Playground testing.
///
/// Allows creating COUNTING tasks with action, unit, maxCount, optional title,
/// and optional description. Validates input, persists to local database, and
/// displays created counter tasks.
struct CounterTaskCreationPlayground: View {
    @State private var action = ""
    @State private var unit = ""
    @State private var maxCountText = ""
    @State private var title = ""
    @State private var taskDescription = ""
    @State private var errorMessage: String?
    @State private var showSuccess = false
    @State private var tasks: [Task] = []

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // -- Creation Form --
            VStack(alignment: .leading, spacing: 12) {
                // Action field (required)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Action (e.g. Run, Read, Drink)", text: $action)
                        .textFieldStyle(.roundedBorder)
                }

                // Max Count field (required)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Max Count (e.g. 10)", text: $maxCountText)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad)
                }

                // Unit field (required)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Unit (e.g. miles, books, glasses)", text: $unit)
                        .textFieldStyle(.roundedBorder)
                }

                // Title field (optional)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Title (auto-generated if blank)", text: $title)
                        .textFieldStyle(.roundedBorder)
                }

                // Description field (optional)
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Description (optional)", text: $taskDescription, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...)
                }

                // Error message
                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }

                // Success message
                if showSuccess {
                    Text("Counter task created!")
                        .foregroundColor(.green)
                        .font(.caption)
                }

                // Create button
                Button("Create Counter Task") {
                    handleCreateCounterTask()
                }
                .buttonStyle(.borderedProminent)
            }

            Divider()

            // -- Counter Task List --
            VStack(alignment: .leading, spacing: 8) {
                if tasks.isEmpty {
                    Text("No counter tasks created yet.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(tasks, id: \.id) { task in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(task.title)
                                    .font(.headline)
                                Spacer()
                                Text("COUNTING")
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.orange.opacity(0.2))
                                    .cornerRadius(4)
                            }
                            if let action = task.action, let maxCount = task.maxCount, let unit = task.unit {
                                Text("\(action) \(maxCount) \(unit)")
                                    .font(.subheadline)
                                    .foregroundColor(.secondary)
                            }
                            if let desc = task.description {
                                Text(desc)
                                    .font(.body)
                            }
                            Text("Created: \(formatDate(task.createdAt))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(12)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                    }
                }
            }
        }
        .onAppear {
            ensurePlaygroundUser()
            loadCounterTasks()
        }
    }

    // MARK: - Actions

    /// Validates input and creates a COUNTING task in the local database.
    ///
    /// Auto-generates title from action/maxCount/unit if title is left blank.
    /// Database write is dispatched to a background thread to avoid blocking the main thread.
    private func handleCreateCounterTask() {
        let trimmedAction = action.trimmingCharacters(in: .whitespaces)
        let trimmedUnit = unit.trimmingCharacters(in: .whitespaces)
        let trimmedMaxCount = maxCountText.trimmingCharacters(in: .whitespaces)
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)

        guard !trimmedAction.isEmpty else {
            errorMessage = "Action is required"
            return
        }
        guard !trimmedUnit.isEmpty else {
            errorMessage = "Unit is required"
            return
        }
        guard !trimmedMaxCount.isEmpty else {
            errorMessage = "Max count is required"
            return
        }
        guard let maxCount = Int(trimmedMaxCount), maxCount > 0 else {
            errorMessage = "Max count must be a positive number"
            return
        }

        errorMessage = nil

        // Mirror of generateCounterTaskTitle in packages/shared/src/algorithms/taskTitle.ts
        let resolvedTitle = trimmedTitle.isEmpty
            ? "\(trimmedAction) \(maxCount) \(trimmedUnit)"
            : trimmedTitle

        let newTask = Task(
            id: AppDatabase.generateUUID(),
            userId: "playground-user-1",
            title: resolvedTitle,
            description: taskDescription.isEmpty ? nil : taskDescription,
            type: .counting,
            action: trimmedAction,
            unit: trimmedUnit,
            maxCount: maxCount,
            totalCompletions: 0,
            totalInstances: 0,
            createdAt: AppDatabase.currentTimestamp(),
            updatedAt: AppDatabase.currentTimestamp(),
            version: 1,
            isDeleted: false
        )

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try AppDatabase.shared.saveTask(newTask)
                DispatchQueue.main.async {
                    self.action = ""
                    self.unit = ""
                    self.maxCountText = ""
                    self.title = ""
                    self.taskDescription = ""
                    self.showSuccess = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self.showSuccess = false
                    }
                    self.loadCounterTasks()
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Failed to create task: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Ensures the playground user exists in the users table (required by FK constraint on tasks).
    private func ensurePlaygroundUser() {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                if try AppDatabase.shared.fetchUser(id: "playground-user-1") == nil {
                    let user = User(
                        id: "playground-user-1",
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

    /// Loads counting tasks for the playground user from the local database.
    private func loadCounterTasks() {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let fetched = try AppDatabase.shared.fetchTasks(userId: "playground-user-1")
                let counterTasks = fetched.filter { $0.type == .counting }
                DispatchQueue.main.async {
                    self.tasks = counterTasks
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Failed to load tasks"
                }
            }
        }
    }

    private static let isoFormatter = ISO8601DateFormatter()
    private static let displayFormatter: DateFormatter = {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .short
        return f
    }()

    /// Formats an ISO8601 string into a medium-style date with time for display.
    ///
    /// - Parameter iso: An ISO8601 date string.
    /// - Returns: A human-readable date string with time, or the original string if parsing fails.
    private func formatDate(_ iso: String) -> String {
        guard let date = Self.isoFormatter.date(from: iso) else { return iso }
        return Self.displayFormatter.string(from: date)
    }
}

// MARK: - Task Creation Playground

/// NORMAL Task Creation form and task list for Playground testing.
///
/// Allows creating NORMAL tasks with title and optional description,
/// validates input, persists to local database, and displays created tasks.
struct TaskCreationPlayground: View {
    @State private var title = ""
    @State private var taskDescription = ""
    @State private var errorMessage: String?
    @State private var showSuccess = false
    @State private var tasks: [Task] = []
    @FocusState private var focusedField: TaskField?

    enum TaskField { case title, description }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            // -- Creation Form --
            VStack(alignment: .leading, spacing: 12) {
                // Title field
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Task Title", text: $title)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .title)
                        .submitLabel(.next)
                        .onSubmit { focusedField = .description }
                    Text("\(title.count)/200")
                        .font(.caption)
                        .foregroundColor(title.count > 200 ? .red : .secondary)
                }

                // Description field
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Task Description", text: $taskDescription, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .focused($focusedField, equals: .description)
                        .lineLimit(5...)
                        .submitLabel(.done)
                        .onSubmit { focusedField = nil }
                    Text("\(taskDescription.count)/1000")
                        .font(.caption)
                        .foregroundColor(taskDescription.count > 1000 ? .red : .secondary)
                }

                // Error message
                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }

                // Success message
                if showSuccess {
                    Text("Task created!")
                        .foregroundColor(.green)
                        .font(.caption)
                }

                // Create button
                Button("Create Task") {
                    handleCreateTask()
                }
                .buttonStyle(.borderedProminent)
            }

            Divider()

            // -- Task List --
            VStack(alignment: .leading, spacing: 8) {
                if tasks.isEmpty {
                    Text("No tasks created yet.")
                        .foregroundColor(.secondary)
                } else {
                    ForEach(tasks, id: \.id) { task in
                        VStack(alignment: .leading, spacing: 4) {
                            HStack {
                                Text(task.title)
                                    .font(.headline)
                                Spacer()
                                Text("NORMAL")
                                    .font(.caption)
                                    .padding(.horizontal, 6)
                                    .padding(.vertical, 2)
                                    .background(Color.blue.opacity(0.2))
                                    .cornerRadius(4)
                            }
                            if let desc = task.description {
                                Text(desc)
                                    .font(.body)
                            }
                            Text("Created: \(formatDate(task.createdAt))")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                        .padding(12)
                        .background(Color(.systemGray6))
                        .cornerRadius(8)
                    }
                }
            }
        }
        .onAppear {
            ensurePlaygroundUser()
            loadTasks()
        }
    }

    // MARK: - Actions

    /// Validates input and creates a NORMAL task in the local database.
    ///
    /// Database write is dispatched to a background thread to avoid blocking the main thread.
    /// UI state updates are dispatched back to the main thread after the write completes.
    private func handleCreateTask() {
        let trimmedTitle = title.trimmingCharacters(in: .whitespaces)

        guard !trimmedTitle.isEmpty else {
            errorMessage = "Title is required"
            return
        }
        guard title.count <= 200 else {
            errorMessage = "Title must be 200 characters or less"
            return
        }
        guard taskDescription.count <= 1000 else {
            errorMessage = "Description must be 1000 characters or less"
            return
        }

        errorMessage = nil

        let newTask = Task(
            id: AppDatabase.generateUUID(),
            userId: "playground-user-1",
            title: trimmedTitle,
            description: taskDescription.isEmpty ? nil : taskDescription,
            type: .normal,
            totalCompletions: 0,
            totalInstances: 0,
            createdAt: AppDatabase.currentTimestamp(),
            updatedAt: AppDatabase.currentTimestamp(),
            version: 1,
            isDeleted: false
        )

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try AppDatabase.shared.saveTask(newTask)
                DispatchQueue.main.async {
                    self.title = ""
                    self.taskDescription = ""
                    self.showSuccess = true
                    DispatchQueue.main.asyncAfter(deadline: .now() + 3) {
                        self.showSuccess = false
                    }
                    self.loadTasks()
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Failed to create task: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Ensures the playground user exists in the users table (required by FK constraint on tasks).
    private func ensurePlaygroundUser() {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                if try AppDatabase.shared.fetchUser(id: "playground-user-1") == nil {
                    let user = User(
                        id: "playground-user-1",
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
                // Non-fatal: surface error so tasks will fail visibly rather than silently
                DispatchQueue.main.async {
                    self.errorMessage = "Setup error: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Loads all non-deleted tasks for the playground user from the local database.
    private func loadTasks() {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let fetched = try AppDatabase.shared.fetchTasks(userId: "playground-user-1")
                DispatchQueue.main.async {
                    self.tasks = fetched
                }
            } catch {
                DispatchQueue.main.async {
                    self.errorMessage = "Failed to load tasks"
                }
            }
        }
    }

    /// Formats an ISO8601 string into a medium-style date with time for display.
    ///
    /// - Parameter iso: An ISO8601 date string.
    /// - Returns: A human-readable date string with time, or the original string if parsing fails.
    private func formatDate(_ iso: String) -> String {
        let formatter = ISO8601DateFormatter()
        guard let date = formatter.date(from: iso) else { return iso }
        let display = DateFormatter()
        display.dateStyle = .medium
        display.timeStyle = .short
        return display.string(from: date)
    }
}

/// Playground View
///
/// A dedicated space for testing new features before integrating them into the main app.
/// Features are displayed in collapsible sections using DisclosureGroup.
struct PlaygroundView: View {
    /// Features under test - new features will be added here (newest first)
    private let features: [Feature] = [
        Feature(
            id: "progress-task-creation",
            title: "Progress Task Creation",
            content: AnyView(ProgressTaskCreationPlayground())
        ),
        Feature(
            id: "counter-task-creation",
            title: "Counter Task Creation",
            content: AnyView(CounterTaskCreationPlayground())
        ),
        Feature(
            id: "task-creation",
            title: "NORMAL Task Creation",
            content: AnyView(TaskCreationPlayground())
        ),
        Feature(
            id: "center-space-free",
            title: "Center Space: True Free Space (5x5)",
            content: AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    Text("Center is auto-completed, shows \"FREE SPACE\", locked (cannot toggle off), counts toward bingo.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    BingoBoard(gridSize: 5, squareSize: 58, centerSquareType: .free)
                        .frame(maxWidth: .infinity)
                }
            )
        ),
        Feature(
            id: "center-space-custom-free",
            title: "Center Space: Customizable Free Space (5x5)",
            content: AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    Text("Center is auto-completed with custom text, locked, counts toward bingo.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    BingoBoard(gridSize: 5, squareSize: 58, centerSquareType: .customFree, centerSquareCustomName: "My Goal!")
                        .frame(maxWidth: .infinity)
                }
            )
        ),
        Feature(
            id: "center-space-chosen",
            title: "Center Space: User-Chosen Center (5x5)",
            content: AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    Text("Center has a fixed task (e.g., \"My Special Task\"), NOT auto-completed, can toggle like any square.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    BingoBoard(gridSize: 5, squareSize: 58, centerSquareType: .chosen)
                        .frame(maxWidth: .infinity)
                }
            )
        ),
        Feature(
            id: "center-space-none",
            title: "Center Space: No Center Space (5x5)",
            content: AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    Text("Center is an ordinary square, no special treatment.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    BingoBoard(gridSize: 5, squareSize: 58, centerSquareType: .none)
                        .frame(maxWidth: .infinity)
                }
            )
        ),
        Feature(
            id: "center-space-3x3",
            title: "Center Space: Works on 3x3 Too!",
            content: AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    Text("True Free Space works on smaller odd-sized boards (center is index 4 on 3x3).")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    BingoBoard(gridSize: 3, squareSize: 80, centerSquareType: .free)
                        .frame(maxWidth: .infinity)
                }
            )
        ),
        Feature(
            id: "bingo-square",
            title: "Bingo Square",
            content: AnyView(
                VStack(alignment: .leading, spacing: 12) {
                    Text("A single bingo board square that toggles between incomplete and completed states. Tap to toggle.")
                        .font(.body)
                        .foregroundColor(.secondary)

                    VStack(alignment: .leading, spacing: 16) {
                        VStack(alignment: .leading) {
                            BingoSquare()
                            Text("Default (100pt)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        VStack(alignment: .leading) {
                            BingoSquare(size: 150)
                            Text("Large (150pt)")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }

                        VStack(alignment: .leading) {
                            BingoSquare(initialCompleted: true)
                            Text("Initially Completed")
                                .font(.caption)
                                .foregroundColor(.secondary)
                        }
                    }
                }
            )
        ),
        Feature(
            id: "bingo-board",
            title: "5x5 Bingo Board Grid",
            content: AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    Text("A 5x5 bingo board grid with 25 toggleable squares. The center square (Task 13) has special styling with an orange border and star marker.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    BingoBoard(gridSize: 5, squareSize: 58)
                        .frame(maxWidth: .infinity)
                }
            )
        ),
        Feature(
            id: "bingo-board-3x3",
            title: "3x3 Mini Board",
            content: AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    Text("A compact 3x3 mini bingo board with 9 toggleable squares. The center square (Task 5) has special styling.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    BingoBoard(gridSize: 3, squareSize: 80)
                        .frame(maxWidth: .infinity)
                }
            )
        ),
        Feature(
            id: "bingo-board-4x4",
            title: "4x4 Standard Board",
            content: AnyView(
                VStack(alignment: .leading, spacing: 8) {
                    Text("A 4x4 standard bingo board with 16 toggleable squares. Even-sized grids have no center square.")
                        .font(.subheadline)
                        .foregroundColor(.secondary)

                    BingoBoard(gridSize: 4, squareSize: 70)
                        .frame(maxWidth: .infinity)
                }
            )
        )
    ]

    @State private var expandedFeatureIds: Set<String> = []
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: 20) {
                    // Header
                    VStack(alignment: .leading, spacing: 8) {
                        Text("Feature Playground")
                            .font(.largeTitle)
                            .fontWeight(.bold)

                        Text("Isolated space for testing features before integrating them into the main app.")
                            .font(.body)
                            .foregroundColor(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    .padding(.bottom, 8)

                    // Features — plain state-driven expand/collapse, no DisclosureGroup gesture overhead
                    VStack(alignment: .leading, spacing: 12) {
                        Text("Features Under Test")
                            .font(.title2)
                            .fontWeight(.semibold)

                        ForEach(features) { feature in
                            VStack(alignment: .leading, spacing: 0) {
                                Button {
                                    if expandedFeatureIds.contains(feature.id) {
                                        expandedFeatureIds.remove(feature.id)
                                    } else {
                                        expandedFeatureIds.insert(feature.id)
                                    }
                                } label: {
                                    HStack {
                                        Text(feature.title)
                                            .font(.headline)
                                            .foregroundColor(.primary)
                                        Spacer()
                                        Image(systemName: expandedFeatureIds.contains(feature.id) ? "chevron.up" : "chevron.down")
                                            .foregroundColor(.secondary)
                                            .font(.subheadline)
                                    }
                                    .padding(.vertical, 8)
                                    .contentShape(Rectangle())
                                }
                                .buttonStyle(.plain)

                                if expandedFeatureIds.contains(feature.id) {
                                    feature.content
                                        .padding(.top, 4)
                                        .padding(.horizontal, 4)
                                        .padding(.bottom, 8)
                                }
                            }
                            .padding(12)
                            .background(
                                RoundedRectangle(cornerRadius: 10)
                                    .fill(Color(.systemGray6))
                            )
                        }
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .scrollDismissesKeyboard(.interactively)
            .navigationTitle("Playground")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Done") { dismiss() }
                }
            }
        }
    }
}

#Preview {
    NavigationStack {
        PlaygroundView()
    }
}
