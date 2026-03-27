import SwiftUI
import GRDB

// MARK: - Board Browse Playground

/// Board Browse → Subtask Derivation Playground.
///
/// Lets users browse existing boards, select one to view its tasks as a grid of
/// `InteractiveTaskSquareView` tiles, then tap a tile to open the appropriate
/// derivation panel below the grid. Derived subtasks and extracted steps are
/// staged in the Board Task Pool at the bottom of the view.
///
/// UI flow: Board List (text rows) → Select Board → Task Grid (tiles) → Select Tile →
///          Derivation Panel (below grid) → Pool.
///
/// - Counting tasks: Uses `CountingDerivationPanelView` for partial count allocation.
/// - Progress tasks: Uses `ProgressDerivationPanelView` for per-step extraction.
/// - Composite tasks: Uses `CompositeDerivationPanelView` for leaf node inspection.
/// - Normal tasks: Shown as not subdivisible.
struct BoardBrowsePlayground: View {

    // MARK: - State

    @State private var boards: [Board] = []
    @State private var selectedBoardId: String? = nil
    @State private var boardTasks: [BoardTask] = []
    @State private var allTasks: [Task] = []
    @State private var compositeTasks: [CompositeTask] = []
    @State private var compositeNodes: [CompositeNode] = []
    @State private var taskSteps: [TaskStep] = []
    @State private var selectedTaskId: String? = nil
    @State private var partialCountStr: String = ""
    @State private var isCreating: Bool = false
    @State private var isSettingUp: Bool = false
    @State private var creationSuccess: String? = nil
    @State private var boardPool: [(taskId: String, title: String, type: String)] = []
    @State private var loadError: String? = nil

    // MARK: - Computed

    /// The board currently selected by the user.
    private var selectedBoard: Board? {
        guard let id = selectedBoardId else { return nil }
        return boards.first(where: { $0.id == id })
    }

    /// The task currently selected within the board's task grid.
    private var selectedTask: Task? {
        guard let id = selectedTaskId else { return nil }
        return allTasks.first(where: { $0.id == id })
    }

    /// The composite task currently selected (keyed off `selectedTaskId` for simplicity;
    /// composite tasks use their own table but share the same selection slot).
    private var selectedCompositeTask: CompositeTask? {
        guard let id = selectedTaskId else { return nil }
        return compositeTasks.first(where: { $0.id == id })
    }

    /// O(1) lookup dictionary from task ID to Task, used during grid rendering.
    private var taskMap: [String: Task] {
        Dictionary(uniqueKeysWithValues: allTasks.map { ($0.id, $0) })
    }

    /// Board tasks sorted by row then column for a natural grid reading order.
    private var sortedBoardTasks: [BoardTask] {
        boardTasks.sorted {
            $0.row == $1.row ? $0.col < $1.col : $0.row < $1.row
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

            // ── Error banner ──
            if let error = loadError {
                Text(error)
                    .font(.caption)
                    .foregroundColor(.red)
            }

            // ── Section: Board List ──
            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Boards")
                        .font(.headline)
                    Spacer()
                    Button(isSettingUp ? "Creating..." : "+ Create Demo Board") {
                        createDemoBoard()
                    }
                    .font(.caption)
                    .buttonStyle(.borderedProminent)
                    .controlSize(.small)
                    .disabled(isSettingUp)
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
                                selectedTaskId = nil
                                taskSteps = []
                                compositeNodes = []
                            } else if let board = boards.first(where: { $0.id == newValue }) {
                                selectBoard(board)
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
                        tasksGridSection
                            .transition(.opacity)
                    }
                }
            }

            // ── Board Task Pool ──
            Divider()
            poolSection
        }
        .onAppear {
            ensurePlaygroundUser()
            loadData()
        }
    }

    // MARK: - Tasks Grid Section

    /// A `LazyVGrid` of `InteractiveTaskSquareView` tiles for the selected board's tasks,
    /// followed by the derivation panel for the currently selected task.
    @ViewBuilder
    private var tasksGridSection: some View {
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
                // ── Task grid ──
                let size = selectedBoard?.boardSize ?? 3
                let columns = Array(repeating: GridItem(.fixed(90), spacing: 8), count: size)
                let boardTaskMap = Dictionary(
                    uniqueKeysWithValues: boardTasks.map { ("\($0.row)-\($0.col)", $0) }
                )
                LazyVGrid(columns: columns, spacing: 8) {
                    ForEach(0..<(size * size), id: \.self) { index in
                        let row = index / size
                        let col = index % size
                        if let bt = boardTaskMap["\(row)-\(col)"] {
                            taskSquare(for: bt)
                        } else {
                            // Empty cell — show "FREE" only at center when board uses a free center type
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

                // ── Derivation panel (below grid, for selected task) ──
                if let task = selectedTask {
                    taskDerivationPanel(for: task)
                        .transition(.opacity)
                } else if let ct = selectedCompositeTask {
                    CompositeDerivationPanelView(
                        compositeTask: ct,
                        compositeNodes: compositeNodes,
                        tasks: allTasks,
                        compositeTasks: compositeTasks,
                        boardPool: boardPool,
                        onAddLeafToPool: { taskId, title, type in
                            addToPool(taskId: taskId, title: title, type: type)
                            showSuccess("Added to board pool: \"\(title)\"")
                        }
                    )
                    .transition(.opacity)
                }
            }
        }
        .padding(10)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }

    // MARK: - Task Square

    /// Builds an `InteractiveTaskSquareView` tile for the given BoardTask.
    ///
    /// Tapping selects the task for derivation (does not toggle completion). A blue border
    /// overlay indicates the currently selected square.
    ///
    /// - Parameter boardTask: The BoardTask to render.
    @ViewBuilder
    private func taskSquare(for boardTask: BoardTask) -> some View {
        let isSelected = selectedTaskId == boardTask.taskId

        if let task = taskMap[boardTask.taskId] {
            // Regular task square
            regularTaskSquare(boardTask: boardTask, task: task, isSelected: isSelected)
        } else if let ct = compositeTasks.first(where: { $0.id == boardTask.taskId }) {
            // Composite task square — rendered as a normal-type square with the composite title
            ZStack {
                InteractiveTaskSquareView(
                    title: ct.title,
                    taskType: .normal,
                    isCompleted: boardTask.isCompleted,
                    onTap: { selectCompositeTask(ct) }
                )

                if isSelected {
                    RoundedRectangle(cornerRadius: 8)
                        .stroke(Color.blue, lineWidth: 3)
                        .frame(width: 90, height: 90)
                        .allowsHitTesting(false)
                }
            }
            .frame(width: 90, height: 90)
        } else {
            // Unknown task — placeholder square
            InteractiveTaskSquareView(
                title: "Unknown",
                taskType: .normal,
                isCompleted: false
            )
        }
    }

    /// Builds the correct `InteractiveTaskSquareView` for a regular (non-composite) task.
    ///
    /// - Parameters:
    ///   - boardTask: Provides current progress state from the database.
    ///   - task: The resolved Task for title, type, and metadata.
    ///   - isSelected: When true, renders a blue border overlay.
    @ViewBuilder
    private func regularTaskSquare(boardTask: BoardTask, task: Task, isSelected: Bool) -> some View {
        ZStack {
            // In Board Browse, tapping selects for derivation — not completion/increment.
            // onTap is omitted so InteractiveTaskSquareView renders as read-only;
            // the ZStack-level .onTapGesture below handles selection for all types.
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
                let stepsForTask = taskSteps.filter { $0.taskId == task.id }
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

            // Transparent tap target on top — intercepts taps before they reach
            // InteractiveTaskSquareView's internal gesture (which blocks progress taps).
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture { selectTask(task) }
        }
        .frame(width: 90, height: 90)
    }

    // MARK: - Derivation Panel Dispatch

    /// Returns the appropriate derivation panel for the given regular task type.
    ///
    /// - Parameter task: The selected Task.
    @ViewBuilder
    private func taskDerivationPanel(for task: Task) -> some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Derivation Panel")
                .font(.headline)

            switch task.type {
            case .normal:
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
                    allTasks: allTasks,
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
            }
        }
    }

    // MARK: - Pool Section

    /// The Board Task Pool staging area at the bottom of the view.
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
                Text("No tasks in the pool yet. Use the buttons above to add subtasks.")
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

    // MARK: - Selection

    /// Selects a board, loads its tasks and all task steps for progress tasks on that board.
    ///
    /// - Parameter board: The Board the user tapped.
    private func selectBoard(_ board: Board) {
        if selectedBoardId == board.id {
            // Deselect on re-tap
            selectedBoardId = nil
            boardTasks = []
            selectedTaskId = nil
            taskSteps = []
            compositeNodes = []
            return
        }
        selectedBoardId = board.id
        selectedTaskId = nil
        taskSteps = []
        compositeNodes = []
        partialCountStr = ""
        loadBoardTasks(boardId: board.id)
    }

    /// Selects a regular task for derivation.
    ///
    /// Does NOT clear `taskSteps` — those are eagerly loaded by `loadBoardTasks`
    /// and the grid needs them to render step counts for all progress tasks.
    ///
    /// - Parameter task: The Task the user tapped.
    private func selectTask(_ task: Task) {
        if selectedTaskId == task.id {
            selectedTaskId = nil
            compositeNodes = []
            return
        }
        selectedTaskId = task.id
        compositeNodes = []
        partialCountStr = ""
    }

    /// Selects a composite task and loads its nodes.
    ///
    /// - Parameter ct: The CompositeTask the user tapped.
    private func selectCompositeTask(_ ct: CompositeTask) {
        if selectedTaskId == ct.id {
            selectedTaskId = nil
            compositeNodes = []
            return
        }
        selectedTaskId = ct.id
        compositeNodes = []
        loadNodes(for: ct.id)
    }

    // MARK: - Data Loading

    /// Loads all boards, tasks, and composite tasks for the playground user.
    private func loadData() {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let fetchedBoards = try AppDatabase.shared.fetchBoards(userId: playgroundUserId)
                let fetchedTasks = try AppDatabase.shared.fetchTasks(userId: playgroundUserId)
                let fetchedComposites = try AppDatabase.shared.read { db in
                    try CompositeTask
                        .filter(Column("userId") == playgroundUserId && Column("isDeleted") == false)
                        .order(Column("title"))
                        .fetchAll(db)
                }
                DispatchQueue.main.async {
                    self.boards = fetchedBoards
                    self.allTasks = fetchedTasks
                    self.compositeTasks = fetchedComposites
                    self.loadError = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.loadError = "Failed to load data: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Loads BoardTask records for the selected board, then eagerly loads steps for all
    /// progress tasks on that board so progress fractions display correctly in the grid.
    ///
    /// - Parameter boardId: The board whose tasks should be loaded.
    private func loadBoardTasks(boardId: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let fetched = try AppDatabase.shared.fetchBoardTasks(boardId: boardId)

                // Identify progress task IDs by querying the DB directly (avoids race
                // with the in-memory allTasks array which may not be refreshed yet).
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
                    self.taskSteps = allSteps
                    self.loadError = nil
                }
            } catch {
                DispatchQueue.main.async {
                    self.loadError = "Failed to load board tasks: \(error.localizedDescription)"
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

    // MARK: Demo Board

    /// Creates a fully populated 3x3 demo board with a mix of counting, progress, and normal tasks.
    ///
    /// The board uses 8 randomly selected tasks from a fixed 9-task pool on non-center positions;
    /// the center square is a free space. The new board is auto-selected after creation.
    private func createDemoBoard() {
        isSettingUp = true

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let now = AppDatabase.currentTimestamp()

                // ── Task definitions ──────────────────────────────────────────────

                // Counting: Read 50 pages
                let readTask = Task(
                    id: AppDatabase.generateUUID(),
                    userId: playgroundUserId,
                    title: "Read 50 pages",
                    type: .counting,
                    action: "Read",
                    unit: "pages",
                    maxCount: 50,
                    totalCompletions: 0,
                    totalInstances: 0,
                    createdAt: now,
                    updatedAt: now,
                    version: 1,
                    isDeleted: false
                )

                // Counting: Walk 10 km
                let walkTask = Task(
                    id: AppDatabase.generateUUID(),
                    userId: playgroundUserId,
                    title: "Walk 10 km",
                    type: .counting,
                    action: "Walk",
                    unit: "km",
                    maxCount: 10,
                    totalCompletions: 0,
                    totalInstances: 0,
                    createdAt: now,
                    updatedAt: now,
                    version: 1,
                    isDeleted: false
                )

                // Progress: Weekly Workout
                let workoutTask = Task(
                    id: AppDatabase.generateUUID(),
                    userId: playgroundUserId,
                    title: "Weekly Workout",
                    type: .progress,
                    totalCompletions: 0,
                    totalInstances: 0,
                    createdAt: now,
                    updatedAt: now,
                    version: 1,
                    isDeleted: false
                )
                let workoutSteps = [
                    TaskStep(id: AppDatabase.generateUUID(), taskId: workoutTask.id,
                             stepIndex: 0, title: "Monday run", type: .normal,
                             createdAt: now, updatedAt: now, version: 1, isDeleted: false),
                    TaskStep(id: AppDatabase.generateUUID(), taskId: workoutTask.id,
                             stepIndex: 1, title: "Wednesday weights", type: .normal,
                             createdAt: now, updatedAt: now, version: 1, isDeleted: false),
                    TaskStep(id: AppDatabase.generateUUID(), taskId: workoutTask.id,
                             stepIndex: 2, title: "Friday yoga", type: .normal,
                             createdAt: now, updatedAt: now, version: 1, isDeleted: false),
                ]

                // Progress: Clean House
                let cleanTask = Task(
                    id: AppDatabase.generateUUID(),
                    userId: playgroundUserId,
                    title: "Clean House",
                    type: .progress,
                    totalCompletions: 0,
                    totalInstances: 0,
                    createdAt: now,
                    updatedAt: now,
                    version: 1,
                    isDeleted: false
                )
                let cleanSteps = [
                    TaskStep(id: AppDatabase.generateUUID(), taskId: cleanTask.id,
                             stepIndex: 0, title: "Vacuum", type: .normal,
                             createdAt: now, updatedAt: now, version: 1, isDeleted: false),
                    TaskStep(id: AppDatabase.generateUUID(), taskId: cleanTask.id,
                             stepIndex: 1, title: "Dust", type: .normal,
                             createdAt: now, updatedAt: now, version: 1, isDeleted: false),
                    TaskStep(id: AppDatabase.generateUUID(), taskId: cleanTask.id,
                             stepIndex: 2, title: "Mop", type: .normal,
                             createdAt: now, updatedAt: now, version: 1, isDeleted: false),
                ]

                // Normal tasks
                let normalTitles = ["Meditate", "Call a friend", "Cook dinner", "Write in journal", "Read a chapter"]
                let normalTasks = normalTitles.map { title in
                    Task(
                        id: AppDatabase.generateUUID(),
                        userId: playgroundUserId,
                        title: title,
                        type: .normal,
                        totalCompletions: 0,
                        totalInstances: 0,
                        createdAt: now,
                        updatedAt: now,
                        version: 1,
                        isDeleted: false
                    )
                }

                let allDemoTasks: [Task] = [readTask, walkTask, workoutTask, cleanTask] + normalTasks

                // ── Shuffle and pick 8 for a 3x3 board (center = free space) ─────

                let shuffled = Shuffle.fisherYatesShuffle(allDemoTasks)
                let boardSize = 3
                let boardId = AppDatabase.generateUUID()

                // ── Compute board name ────────────────────────────────────────────

                let existingCount = try AppDatabase.shared.fetchBoards(userId: playgroundUserId).count
                let boardName = "Demo Board \(existingCount + 1)"

                let board = Board.makePlayground(id: boardId, userId: playgroundUserId, name: boardName, now: now, centerSquareType: "free")

                // ── Persist everything in a single write transaction ──────────────

                try AppDatabase.shared.write { db in
                    try board.save(db)

                    // Save all tasks
                    for task in allDemoTasks {
                        try task.save(db)
                    }

                    // Save progress task steps
                    for step in workoutSteps + cleanSteps {
                        try step.save(db)
                    }

                    // Place 8 tasks on non-center positions
                    var taskIndex = 0
                    for row in 0..<boardSize {
                        for col in 0..<boardSize {
                            let isCenter = row == 1 && col == 1
                            if isCenter { continue }
                            guard taskIndex < shuffled.count else { break }
                            let bt = BoardTask.makePlayground(
                                boardId: boardId,
                                taskId: shuffled[taskIndex].id,
                                row: row,
                                col: col,
                                now: now
                            )
                            try bt.save(db)
                            taskIndex += 1
                        }
                    }
                }

                DispatchQueue.main.async {
                    self.isSettingUp = false
                    self.showSuccess("Created \"\(boardName)\" with 8 tasks")
                    self.loadData()
                    // After loadData completes asynchronously we auto-select; defer slightly
                    // so the boards array is populated first.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.4) {
                        if let newBoard = self.boards.first(where: { $0.id == boardId }) {
                            self.selectBoard(newBoard)
                        } else {
                            // boards not yet refreshed; store ID and eagerly load tasks
                            self.selectedBoardId = boardId
                            self.loadBoardTasks(boardId: boardId)
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isSettingUp = false
                    self.loadError = "Failed to create demo board: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Creates a new counting subtask derived from the parent task and adds it to the pool.
    ///
    /// Uses `count` as the `maxCount`. Title is auto-generated as "\(action) \(count) \(unit)".
    /// Refreshes the task library on success.
    ///
    /// - Parameters:
    ///   - parentTask: The counting Task from which the subtask is derived.
    ///   - count: The validated partial count from `CountingDerivationPanelView`.
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
                    self.loadData()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isCreating = false
                    self.loadError = "Failed to create subtask: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Extracts a progress task step into a standalone task and links them in a single transaction.
    ///
    /// Refreshes the task library and the step list for the parent task on success.
    ///
    /// - Parameters:
    ///   - step: The TaskStep to extract.
    ///   - parentTask: The progress Task that owns the step.
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
                    try db.execute(
                        sql: "UPDATE \(TaskStep.databaseTableName) SET linkedTaskId = ?, updatedAt = ? WHERE id = ?",
                        arguments: [newTask.id, now, step.id]
                    )
                }
                DispatchQueue.main.async {
                    self.isCreating = false
                    self.addToPool(taskId: newTask.id, title: newTask.title, type: newTask.type.rawValue)
                    self.showSuccess("Added to board pool: \"\(newTask.title)\"")
                    self.loadData()
                    if let boardId = self.selectedBoardId {
                        self.loadBoardTasks(boardId: boardId)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isCreating = false
                    self.loadError = "Failed to extract step: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Pool Helpers

    /// Adds a task entry to the board pool. Skips duplicates.
    private func addToPool(taskId: String, title: String, type: String) {
        guard !boardPool.contains(where: { $0.taskId == taskId }) else { return }
        boardPool.append((taskId: taskId, title: title, type: type))
    }

    /// Shows a success banner that auto-dismisses after `successDismissSeconds`.
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
}
