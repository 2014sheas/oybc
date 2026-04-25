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
    @State private var expandedCompoundTaskId: String?
    @State private var derivePartialCountStr: String = ""
    @State private var deriveIsCreating: Bool = false

    // MARK: - Derived

    /// Tuple-shaped projection of the pool used by shared panels
    /// (`BoardCreatorPanelView`) whose APIs predate `BoardPoolEntry`.
    /// Computed once per body evaluation so we don't re-allocate
    /// identical tuple arrays in the same render.
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
                        // allTaskSteps is used only for step-count hints in the board
                        // preview grid. The unified library no longer pre-loads task_steps
                        // in bulk; pass empty — the preview count shows 0 until Phase 6
                        // wires compound children into the preview path.
                        allTaskSteps: [],
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
                _Concurrency.Task { await library.reload(userId: userId) }
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
                        _Concurrency.Task { await library.reload(userId: userId) }
                    }
                )
            },
            onCompositeCreated: { createdTask in
                // Compound tasks aren't added directly to the board pool —
                // users add the compound's individual child tasks from
                // Existing Tasks instead.
                form.successMessage = "Created compound \"\(createdTask.title)\". Add its subtasks from Existing Tasks."
                if let userId = authService.currentUser?.id {
                    _Concurrency.Task { await library.reload(userId: userId) }
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

            // Primitive tasks (normal / counting / progress-as-compound).
            // For .all we exclude composites here since they are shown separately below.
            let filteredPrimitives: [Task] = {
                if existingFilter == .all {
                    return library.libraryTasks.filter { $0.type != .compound || $0.isOrdered == true }
                } else if existingFilter == .composite {
                    return []
                } else {
                    return library.filteredTasks(existingFilter)
                }
            }()
            // Compound (composite) tasks — visible under .all and .composite filters.
            let filteredCompounds: [Task] = {
                if existingFilter == .all || existingFilter == .composite {
                    return library.filteredTasks(.composite)
                } else {
                    return []
                }
            }()

            if filteredPrimitives.isEmpty && filteredCompounds.isEmpty {
                ContentUnavailableView(
                    "No Tasks Yet",
                    systemImage: "plus.square",
                    description: Text("Create your first task above!")
                )
            } else {
                ForEach(filteredPrimitives, id: \.id) { task in
                    existingTaskRow(task)
                    if expandedTaskId == task.id {
                        derivePanel(for: task)
                            .padding(.leading, 8)
                            .transition(.opacity)
                    }
                }
                ForEach(filteredCompounds, id: \.id) { compound in
                    existingCompoundRow(compound)
                    if expandedCompoundTaskId == compound.id {
                        compoundDerivationPanel(for: compound)
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

    /// Row for a compound task (type=.compound && !isOrdered).
    @ViewBuilder
    private func existingCompoundRow(_ compound: Task) -> some View {
        let isExpanded = expandedCompoundTaskId == compound.id

        HStack(spacing: 8) {
            VStack(alignment: .leading, spacing: 2) {
                Text(compound.title)
                    .font(.subheadline)
                    .fontWeight(.medium)
                if let desc = compound.description, !desc.isEmpty {
                    Text(desc)
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            TypeBadgeView(type: "composite", size: .small)

            Button {
                toggleExpandCompound(compound)
            } label: {
                Image(systemName: isExpanded ? "chevron.up.circle" : "arrow.triangle.branch")
                    .font(.system(size: 24))
                    .foregroundColor(isExpanded ? .accentColor : .secondary)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(isExpanded ? "Collapse children" : "Show children")

            // Compound tasks can't be added directly to the pool —
            // users add the compound's individual child tasks instead.
        }
        .padding(10)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }

    // MARK: - Compound derivation panel (replaces legacy CompositeDerivationPanelView)

    /// Inline panel showing the operator + children of a compound task.
    /// Uses `library.compoundChildrenByCompound[id]` — no async fetch needed.
    @ViewBuilder
    private func compoundDerivationPanel(for compound: Task) -> some View {
        let children = library.compoundChildrenByCompound[compound.id] ?? []
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text(compound.title)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Spacer()
                TypeBadgeView(type: "composite", size: .small)
            }

            if children.isEmpty {
                Text("No children found for this compound task.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                // Operator summary
                if let opType = compound.operatorType {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Operator")
                            .font(.caption)
                            .foregroundColor(.secondary)
                        HStack {
                            Text(operatorSummaryLabel(opType, threshold: compound.threshold, childCount: children.count))
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

                // Children rows
                VStack(alignment: .leading, spacing: 6) {
                    Text("\(children.count) child task\(children.count == 1 ? "" : "s")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                    ForEach(children, id: \.id) { child in
                        compoundChildRow(child)
                    }
                }
            }
        }
        .padding(12)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }

    @ViewBuilder
    private func compoundChildRow(_ child: CompoundChild) -> some View {
        let childTask = library.task(byId: child.childTaskId)
        let inPool = childTask.map { pool.isInPool(taskId: $0.id) } ?? false

        HStack {
            Text("\u{00B7}")
                .foregroundColor(.secondary)

            if let task = childTask {
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

                if inPool {
                    Text("In Pool \u{2713}")
                        .font(.caption)
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(Color.green.opacity(0.2))
                        .foregroundColor(.green)
                        .cornerRadius(4)
                } else {
                    Button("Add to Pool") {
                        pool.addToPool(taskId: task.id, title: task.title, type: task.type.rawValue)
                    }
                    .font(.caption)
                    .buttonStyle(.bordered)
                }
            } else {
                Text("Unknown task (id: \(child.childTaskId))")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
                Spacer()
            }
        }
        .padding(8)
        .background(Color(.systemGray5))
        .cornerRadius(6)
    }

    private func operatorSummaryLabel(_ type: OperatorType, threshold: Int?, childCount: Int) -> String {
        switch type {
        case .and:  return "All of"
        case .or:   return "Any of"
        case .mOfN: return "At least \(threshold ?? 0) of \(childCount)"
        }
    }

    // MARK: - Derive panel (for primitive task types)

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
                    taskSteps: loadedProgressSteps(for: task.id),
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

            case .compound:
                EmptyView()  // Compound expansion is handled by compoundDerivationPanel
            }
        }
    }

    /// Fetches task steps for a progress task synchronously from the
    /// in-memory library. Steps live in `task_steps` table; we load
    /// them on demand here to avoid coupling ProgressDerivationPanelView
    /// to the library view model.
    private func loadedProgressSteps(for taskId: String) -> [TaskStep] {
        (try? AppDatabase.shared.read { db in
            try TaskStep
                .filter(Column("taskId") == taskId && Column("isDeleted") == false)
                .order(Column("stepIndex"))
                .fetchAll(db)
        }) ?? []
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
            derivePartialCountStr = ""
        } else {
            expandedTaskId = task.id
            expandedCompoundTaskId = nil
            derivePartialCountStr = ""
        }
    }

    private func toggleExpandCompound(_ compound: Task) {
        if expandedCompoundTaskId == compound.id {
            expandedCompoundTaskId = nil
        } else {
            expandedCompoundTaskId = compound.id
            expandedTaskId = nil
            derivePartialCountStr = ""
            // Children are already available in library.compoundChildrenByCompound —
            // no async fetch needed.
        }
    }

    private func clearExpandedState() {
        expandedTaskId = nil
        expandedCompoundTaskId = nil
        derivePartialCountStr = ""
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
                    _Concurrency.Task { await self.library.reload(userId: userId) }
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
                    _Concurrency.Task { await self.library.reload(userId: userId) }
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
