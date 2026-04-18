import SwiftUI
import GRDB

// MARK: - Local Enums

/// The two tab modes for the Create page.
private enum CreateMode: String, CaseIterable {
    case create = "Create New"
    case existing = "Existing Tasks"
}

// MARK: - CreateView

/// CreateView — Production task pool builder + board creation.
///
/// Two-tab interface:
/// - **Create New**: form for Normal/Counting/Progress tasks, plus
///   `CompositeTaskWizardView`. Newly created tasks are added directly
///   to the pool.
/// - **Existing Tasks**: filterable task library with expand/collapse
///   derivation panels.
///
/// The Board Task Pool section is always visible at the bottom. When
/// the pool has enough tasks, `BoardCreatorPanelView` lets the user
/// configure and create a board, then navigates to `BoardPlayView`.
///
/// State owners:
/// - `BoardPoolViewModel`    — pool entries + add/remove/clear.
/// - `TaskLibraryViewModel`  — user's library + derive-panel state.
/// - `CreateFormViewModel`   — Create-New form: fields, validation,
///   submit, reset.
/// - `@State` (inline)       — UI-only: mode, expand, filter,
///   partial-count, derive-in-flight.
struct CreateView: View {

    // MARK: - Dependencies

    @EnvironmentObject var authService: AuthService

    // MARK: - View models

    @State private var pool = BoardPoolViewModel()
    @State private var library = TaskLibraryViewModel()
    @State private var form = CreateFormViewModel()

    // MARK: - Navigation + UI-only state

    @State private var navigateToBoardId: BoardNavID?
    @State private var mode: CreateMode = .create
    @State private var existingFilter: LibraryFilter = .all
    @State private var expandedTaskId: String?
    @State private var expandedCompositeTaskId: String?
    @State private var derivePartialCountStr: String = ""
    @State private var deriveIsCreating: Bool = false

    // MARK: - Derived

    /// Tuple-shaped projection of the pool used by shared panels
    /// (`BoardCreatorPanelView`, `CompositeDerivationPanelView`,
    /// `ProgressDerivationPanelView`) whose APIs predate
    /// `BoardPoolEntry`. Computed once per body evaluation so we
    /// don't re-allocate identical tuple arrays three times in the
    /// same render.
    private var poolAsTuples: [(taskId: String, title: String, type: String)] {
        pool.pool.map { (taskId: $0.taskId, title: $0.title, type: $0.type) }
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {
                modePicker

                switch mode {
                case .create:   createTab
                case .existing: existingTab
                }

                Divider()
                poolSection

                if !pool.pool.isEmpty, let userId = authService.currentUser?.id {
                    Divider()
                    BoardCreatorPanelView(
                        boardPool: poolAsTuples,
                        libraryTasks: library.libraryTasks,
                        allTaskSteps: library.allLibraryTaskSteps,
                        userId: userId,
                        initialPreferences: authService.userPreferences,
                        onBoardCreated: { boardId in
                            navigateToBoardId = BoardNavID(id: boardId)
                        }
                    )
                }
            }
            .padding(.horizontal)
        }
        .navigationTitle("Create")
        .navigationDestination(item: $navigateToBoardId) { nav in
            BoardPlayView(boardId: nav.id)
        }
        .onAppear {
            if let userId = authService.currentUser?.id {
                library.loadLibrary(userId: userId)
            }
        }
    }

    // MARK: - Mode picker

    @ViewBuilder
    private var modePicker: some View {
        HStack {
            Picker("Mode", selection: $mode) {
                ForEach(CreateMode.allCases, id: \.self) { m in
                    Text(m.rawValue).tag(m)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: mode) {
                form.clearFeedback()
            }

            if !pool.pool.isEmpty {
                Text("Pool: \(pool.pool.count)")
                    .font(.caption)
                    .fontWeight(.bold)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 5)
                    .background(Color.accentColor)
                    .foregroundColor(.white)
                    .clipShape(Capsule())
            }
        }
    }

    // MARK: - Create Tab

    @ViewBuilder
    private var createTab: some View {
        CreateNewTaskFormView(
            form: form,
            userId: authService.currentUser?.id,
            onSubmit: {
                guard let userId = authService.currentUser?.id else { return }
                form.handleCreateAndAddToPool(
                    userId: userId,
                    onTaskCreated: { taskId, title, type in
                        pool.addToPool(taskId: taskId, title: title, type: type)
                    },
                    onLibraryReloadRequested: {
                        library.loadLibrary(userId: userId)
                    }
                )
            },
            onCompositeCreated: { compositeTask in
                // Composites aren't added directly to the board pool —
                // BoardTask.taskId references the tasks table, not
                // compositeTasks. Users add the composite's individual
                // leaf/subtasks from Existing Tasks.
                form.successMessage = "Created composite \"\(compositeTask.title)\". Add its subtasks from Existing Tasks."
                if let userId = authService.currentUser?.id {
                    library.loadLibrary(userId: userId)
                }
            }
        )
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
                    ForEach(LibraryFilter.allCases, id: \.self) { f in
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

            if let error = library.loadError {
                Text(error)
                    .foregroundColor(.red)
                    .font(.caption)
            }

            let filteredTasks = library.filteredTasks(filter: existingFilter)
            let filteredComposites = library.filteredComposites(filter: existingFilter)

            if filteredTasks.isEmpty && filteredComposites.isEmpty {
                ContentUnavailableView(
                    "No Tasks Yet",
                    systemImage: "plus.square",
                    description: Text("Create your first task above!")
                )
            } else {
                ForEach(filteredTasks, id: \.id) { task in
                    existingTaskRow(task)
                    if expandedTaskId == task.id {
                        derivePanel(for: task)
                            .padding(.leading, 8)
                            .transition(.opacity)
                    }
                }
                ForEach(filteredComposites, id: \.id) { ct in
                    existingCompositeRow(ct)
                    if expandedCompositeTaskId == ct.id {
                        CompositeDerivationPanelView(
                            compositeTask: ct,
                            compositeNodes: library.deriveCompositeNodes,
                            tasks: library.libraryTasks,
                            compositeTasks: library.libraryCompositeTasks,
                            boardPool: poolAsTuples,
                            onAddLeafToPool: { taskId, title, type in
                                pool.addToPool(taskId: taskId, title: title, type: type)
                            }
                        )
                        .padding(.leading, 8)
                        .transition(.opacity)
                    }
                }
            }
        }
    }

    // MARK: - Existing rows

    @ViewBuilder
    private func existingTaskRow(_ task: Task) -> some View {
        let inPool = pool.isInPool(taskId: task.id)
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
                    pool.addToPool(taskId: task.id, title: task.title, type: task.type.rawValue)
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

    @ViewBuilder
    private func existingCompositeRow(_ ct: CompositeTask) -> some View {
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

            // Composites can't be added directly to the pool —
            // BoardTask.taskId references the tasks table, not
            // compositeTasks. Users expand the composite and add its
            // individual leaf/subtasks instead.
        }
        .padding(10)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }

    // MARK: - Derive panel

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
                    taskSteps: library.deriveTaskSteps,
                    allTasks: library.libraryTasks,
                    boardPool: poolAsTuples,
                    isCreating: deriveIsCreating,
                    onExtractStep: { step, parentTask in
                        extractStepAsTask(step: step, parentTask: parentTask)
                    },
                    onAddStepToPool: { linkedTask in
                        pool.addToPool(
                            taskId: linkedTask.id,
                            title: linkedTask.title,
                            type: linkedTask.type.rawValue
                        )
                    }
                )
            }
        }
    }

    // MARK: - Pool section

    @ViewBuilder
    private var poolSection: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Board Task Pool")
                    .font(.headline)
                if !pool.pool.isEmpty {
                    Text("\(pool.pool.count)")
                        .font(.caption)
                        .fontWeight(.bold)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .cornerRadius(10)
                }
            }

            if pool.pool.isEmpty {
                Text("No tasks in the pool yet. Use the tabs above to add tasks.")
                    .foregroundColor(.secondary)
                    .font(.subheadline)
            } else {
                ForEach(pool.pool, id: \.taskId) { entry in
                    PoolItemView(title: entry.title, type: entry.type) {
                        pool.removeFromPool(taskId: entry.taskId)
                    }
                }

                Button("Clear Pool") {
                    pool.clearPool()
                }
                .font(.caption)
                .foregroundColor(.red)
            }
        }
    }

    // MARK: - Existing-tab actions

    private func toggleExpandTask(_ task: Task) {
        if expandedTaskId == task.id {
            expandedTaskId = nil
            library.clearDeriveState()
            derivePartialCountStr = ""
        } else {
            expandedTaskId = task.id
            expandedCompositeTaskId = nil
            library.clearDeriveState()
            derivePartialCountStr = ""
            if task.type == .progress {
                library.loadDeriveSteps(for: task.id)
            }
        }
    }

    private func toggleExpandComposite(_ ct: CompositeTask) {
        if expandedCompositeTaskId == ct.id {
            expandedCompositeTaskId = nil
            library.clearDeriveState()
        } else {
            expandedCompositeTaskId = ct.id
            expandedTaskId = nil
            library.clearDeriveState()
            derivePartialCountStr = ""
            library.loadDeriveNodes(for: ct.id)
        }
    }

    private func clearExpandedState() {
        expandedTaskId = nil
        expandedCompositeTaskId = nil
        derivePartialCountStr = ""
        library.clearDeriveState()
    }

    /// Creates a counting subtask from an existing counting parent
    /// (e.g. a "partial" of "Run 26 miles" → "Run 5 miles").
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
                    self.pool.addToPool(taskId: newTask.id, title: title, type: TaskType.counting.rawValue)
                    self.derivePartialCountStr = ""
                    self.library.loadLibrary(userId: userId)
                }
            } catch {
                DispatchQueue.main.async {
                    self.deriveIsCreating = false
                    self.library.loadError = "Failed to create subtask: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Extracts a progress step into a standalone task and links the
    /// step's `linkedTaskId` to it. If the step is already linked,
    /// just adds the linked task to the pool.
    private func extractStepAsTask(step: TaskStep, parentTask: Task) {
        guard let userId = authService.currentUser?.id else { return }

        if let linkedId = step.linkedTaskId,
           let linkedTask = library.libraryTasks.first(where: { $0.id == linkedId }) {
            pool.addToPool(taskId: linkedTask.id, title: linkedTask.title, type: linkedTask.type.rawValue)
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
                    self.pool.addToPool(taskId: newTask.id, title: newTask.title, type: newTask.type.rawValue)
                    self.library.loadLibrary(userId: userId)
                    self.library.loadDeriveSteps(for: parentTask.id)
                }
            } catch {
                DispatchQueue.main.async {
                    self.deriveIsCreating = false
                    self.library.loadError = "Failed to extract step: \(error.localizedDescription)"
                }
            }
        }
    }
}

// MARK: - Helpers

/// Local navigation wrapper — avoids adding a global `Identifiable`
/// conformance to `String`, which would affect the entire module.
private struct BoardNavID: Identifiable, Hashable {
    let id: String
}

#Preview {
    NavigationStack {
        CreateView()
            .environmentObject(AuthService())
    }
}
