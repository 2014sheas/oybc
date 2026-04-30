// Phase 5 will rewrite this playground to support TaskType.compound. Until
// then, gate it out of the build so the rest of the iOS app can compile.
#if false
import SwiftUI
import GRDB

// MARK: - Board Tab

/// Which board is currently visible in the segmented picker.
private enum BoardTab: String, CaseIterable {
    case parent = "Parent Board"
    case subtask = "Subtask Board"
}

// MARK: - Cross-Board Rollup Playground

/// Cross-Board Progress Rollup Playground.
///
/// Demonstrates SF3: completing a subtask on Board B automatically updates the
/// parent task's progress on Board A. Two task types are shown:
///
/// - **Counting** rollup: "Read 25 pages" subtask on Board B rolls up its maxCount
///   into the "Read 100 pages" parent on Board A (capped at parent's maxCount).
/// - **Progress** rollup: Tapping a step-task square on Board B (Vacuum / Dust / Mop)
///   appends that step's ID to the parent "Clean House" task's completedStepIds on Board A.
///
/// A segmented `Picker` switches between the two boards. Tap subtask squares to trigger
/// rollup and watch the parent board update in real time.
struct CrossBoardRollupPlayground: View {
    // MARK: - State

    @State private var isSetUp = false
    @State private var selectedBoard: BoardTab = .parent
    @State private var boardAId: String? = nil
    @State private var boardBId: String? = nil
    @State private var boardATasks: [BoardTask] = []
    @State private var boardBTasks: [BoardTask] = []
    @State private var tasks: [Task] = []
    @State private var taskSteps: [TaskStep] = []
    @State private var successMessage: String? = nil
    @State private var errorMessage: String? = nil
    @State private var isProcessing = false
    @State private var detailBoardTaskId: String? = nil

    // Relationship mappings (populated during setup)
    @State private var countingParentTaskId: String? = nil
    @State private var countingSubtaskTaskId: String? = nil
    @State private var progressParentTaskId: String? = nil
    /// Tuples of (taskId on Board B, stepId on the progress parent's TaskStep).
    @State private var stepTaskIds: [(taskId: String, stepId: String)] = []

    // MARK: - Computed

    /// Lookup dictionary from task ID to Task for O(1) access in view rendering.
    private var taskMap: [String: Task] {
        Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
    }

    /// Total step count for the progress parent (used for "X / 3 steps" display).
    private var totalStepCount: Int { taskSteps.count }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // ── Success / error banners ──
            if let msg = successMessage {
                Text(msg)
                    .font(.subheadline)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.green.opacity(0.15))
                    .foregroundColor(.green)
                    .cornerRadius(8)
            }

            if let msg = errorMessage {
                Text(msg)
                    .font(.subheadline)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.12))
                    .foregroundColor(.red)
                    .cornerRadius(8)
            }

            if !isSetUp {
                notSetUpView
            } else {
                boardsView
            }
        }
        .onAppear {
            ensurePlaygroundUser()
        }
    }

    // MARK: - Not Set Up View

    /// Shown before the demo data has been created.
    @ViewBuilder
    private var notSetUpView: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Tap \"Set Up Demo Boards\" to create two linked boards and see cross-board rollup in action.")
                .font(.subheadline)
                .foregroundColor(.secondary)

            Button(action: setupDemo) {
                Text(isProcessing ? "Setting up..." : "Set Up Demo Boards")
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .frame(maxWidth: .infinity)
                    .padding(.vertical, 8)
            }
            .buttonStyle(.borderedProminent)
            .disabled(isProcessing)
        }
    }

    // MARK: - Boards View

    /// Shown after setup — segmented picker + board content.
    @ViewBuilder
    private var boardsView: some View {
        VStack(alignment: .leading, spacing: 12) {

            // Board picker
            Picker("Board", selection: $selectedBoard) {
                ForEach(BoardTab.allCases, id: \.self) { tab in
                    Text(tab.rawValue).tag(tab)
                }
            }
            .pickerStyle(.segmented)

            // Contextual explanation
            Group {
                if selectedBoard == .parent {
                    Text("Board A — parent tasks. Progress updates automatically when subtasks complete on Board B.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Text("Board B — subtask board. Tap to act · Long-press for quick options")
                        .font(.caption)
                        .foregroundColor(.secondary)
                        .italic()
                }
            }

            // Board square grid
            if selectedBoard == .parent {
                boardSquaresGrid(boardTasks: boardATasks, isSubtaskBoard: false)
            } else {
                boardSquaresGrid(boardTasks: boardBTasks, isSubtaskBoard: true)
            }

            Divider()

            Button(action: resetDemo) {
                Text("Reset Demo")
                    .font(.caption)
                    .foregroundColor(.red)
            }
            .disabled(isProcessing)
        }
        .sheet(isPresented: Binding(
            get: { detailBoardTaskId != nil },
            set: { if !$0 { detailBoardTaskId = nil } }
        )) {
            detailSheet
        }
    }

    // MARK: - Board Grid

    /// Renders board tasks as a bingo-shaped grid of `InteractiveTaskSquareView` squares.
    ///
    /// Board A squares are read-only; Board B squares wire tap handlers to the rollup logic.
    ///
    /// - Parameters:
    ///   - boardTasks: The BoardTask records to display.
    ///   - isSubtaskBoard: Whether this is Board B (subtask board), which enables taps.
    @ViewBuilder
    private func boardSquaresGrid(boardTasks: [BoardTask], isSubtaskBoard: Bool) -> some View {
        LazyVGrid(
            columns: Array(repeating: GridItem(.fixed(90), spacing: 8), count: 3),
            spacing: 8
        ) {
            ForEach(boardTasks, id: \.id) { bt in
                interactiveSquare(boardTask: bt, task: taskMap[bt.taskId], isSubtaskBoard: isSubtaskBoard)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Interactive Square

    /// Builds an `InteractiveTaskSquareView` configured from a BoardTask and its resolved Task.
    ///
    /// Exactly mirrors the `TaskBingoSquareView` interaction pattern from `TaskSquareActionsPlayground`:
    /// - Normal: tap toggles completion; long-press context menu offers Mark Complete/Incomplete and View Details.
    /// - Counting: tap increments +1; long-press context menu offers + Add, - Remove, Reset, View Details.
    /// - Progress: tap opens detail sheet; long-press context menu offers View Steps, Mark All Complete/Incomplete.
    ///
    /// Board A squares are always read-only (no tap handler, no context menu actions).
    ///
    /// - Parameters:
    ///   - boardTask: Provides current progress and completion state from the database.
    ///   - task: The resolved Task for title and type metadata (nil renders "Unknown").
    ///   - isSubtaskBoard: When true, taps and context menu trigger rollup handlers (Board B only).
    @ViewBuilder
    private func interactiveSquare(boardTask: BoardTask, task: Task?, isSubtaskBoard: Bool) -> some View {
        let resolved = task
        let taskType = resolved?.type ?? .normal
        let isCompleted = boardTask.isCompleted

        switch taskType {
        case .normal:
            InteractiveTaskSquareView(
                title: resolved?.title ?? "Unknown",
                taskType: .normal,
                isCompleted: isCompleted,
                onTap: isSubtaskBoard ? { handleStepTaskTap(boardTask: boardTask) } : nil,
                isReadOnly: !isSubtaskBoard
            )
            .contextMenu {
                if isSubtaskBoard {
                    Button(
                        isCompleted ? "Mark Incomplete" : "Mark Complete",
                        systemImage: "checkmark.circle"
                    ) {
                        handleStepTaskTap(boardTask: boardTask)
                    }
                    Button("View Details", systemImage: "info.circle") {
                        detailBoardTaskId = boardTask.id
                    }
                }
            }

        case .counting:
            let current = boardTask.currentCount ?? 0
            let maxVal = resolved?.maxCount ?? 0
            let unitText = resolved?.unit ?? ""
            let actionLabel = resolved?.action ?? "item"
            InteractiveTaskSquareView(
                title: resolved?.title ?? "Unknown",
                taskType: .counting,
                isCompleted: isCompleted,
                currentCount: current,
                maxCount: maxVal,
                unit: unitText,
                onTap: isSubtaskBoard ? { if let t = resolved { handleCountingSubtaskTap(boardTask: boardTask, task: t) } } : nil,
                isReadOnly: !isSubtaskBoard
            )
            .contextMenu {
                if isSubtaskBoard, let t = resolved {
                    Button("+ Add \(actionLabel)", systemImage: "plus") {
                        handleCountingSubtaskTap(boardTask: boardTask, task: t)
                    }
                    .disabled(current >= maxVal || isProcessing)
                    Button("- Remove \(actionLabel)", systemImage: "minus") {
                        handleCountingSubtaskDecrement(boardTask: boardTask, task: t)
                    }
                    .disabled(current == 0 || isProcessing)
                    Button("Reset", systemImage: "arrow.counterclockwise") {
                        // Decrement all the way to zero by treating current count as the decrement amount.
                        // We call handleCountingSubtaskDecrement repeatedly only if count > 0;
                        // for simplicity open the detail sheet so the user can use the minus button.
                        detailBoardTaskId = boardTask.id
                    }
                    .disabled(current == 0)
                    Button("View Details", systemImage: "info.circle") {
                        detailBoardTaskId = boardTask.id
                    }
                }
            }

        case .progress:
            let completedCount = boardTask.completedStepIds?.count ?? 0
            let total = totalStepCount > 0 ? totalStepCount : 3
            let allDone = completedCount >= total && total > 0
            InteractiveTaskSquareView(
                title: resolved?.title ?? "Unknown",
                taskType: .progress,
                isCompleted: isCompleted,
                completedSteps: completedCount,
                totalSteps: total,
                // Progress tasks open the detail sheet on tap (same as TaskSquareActionsPlayground).
                onTap: isSubtaskBoard ? { detailBoardTaskId = boardTask.id } : nil,
                isReadOnly: !isSubtaskBoard
            )
            .contextMenu {
                if isSubtaskBoard {
                    Button("View Steps", systemImage: "list.bullet") {
                        detailBoardTaskId = boardTask.id
                    }
                    Button("Mark All Complete", systemImage: "checkmark.circle.fill") {
                        detailBoardTaskId = boardTask.id
                    }
                    .disabled(allDone)
                    Button("Mark Incomplete", systemImage: "xmark.circle") {
                        detailBoardTaskId = boardTask.id
                    }
                    .disabled(!allDone)
                    Button("View Details", systemImage: "info.circle") {
                        detailBoardTaskId = boardTask.id
                    }
                }
            }
        }
    }

    // MARK: - Tap Handlers

    /// Routes a tap on a Board B square to the appropriate rollup handler.
    ///
    /// - Parameters:
    ///   - boardTask: The tapped BoardTask record.
    ///   - task: The resolved Task for type inspection.
    private func handleSubtaskBoardTap(boardTask: BoardTask, task: Task?) {
        guard let task = task else { return }

        switch task.type {
        case .counting:
            handleCountingSubtaskTap(boardTask: boardTask, task: task)
        case .normal:
            handleStepTaskTap(boardTask: boardTask)
        case .progress:
            // Progress tasks on Board B are not directly tappable
            break
        }
    }

    /// Increments the counting subtask's currentCount by 1 and triggers rollup when it completes.
    ///
    /// Each tap adds 1 to currentCount up to maxCount. When the subtask reaches maxCount it
    /// is marked complete and `calculateCountingRollup` is applied: the subtask's maxCount is
    /// added to the parent BoardTask's currentCount on Board A, capped at the parent's maxCount.
    ///
    /// - Parameters:
    ///   - boardTask: The counting subtask's BoardTask record.
    ///   - task: The counting Task providing maxCount.
    private func handleCountingSubtaskTap(boardTask: BoardTask, task: Task) {
        guard !boardTask.isCompleted, let maxCount = task.maxCount else { return }

        isProcessing = true
        let now = AppDatabase.currentTimestamp()
        let newCount = min((boardTask.currentCount ?? 0) + 1, maxCount)
        let nowCompleted = newCount >= maxCount

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Update counting subtask on Board B
                try AppDatabase.shared.write { db in
                    try db.execute(
                        sql: """
                            UPDATE \(BoardTask.databaseTableName)
                            SET currentCount = ?, isCompleted = ?, completedAt = ?,
                                updatedAt = ?, version = version + 1
                            WHERE id = ?
                            """,
                        arguments: [
                            newCount,
                            nowCompleted ? 1 : 0,
                            nowCompleted ? now : nil,
                            now,
                            boardTask.id
                        ]
                    )
                }

                // Roll up +1 to parent on Board A on every increment
                if let parentTaskId = self.countingParentTaskId,
                   let parentBT = try self.findParentBoardTask(taskId: parentTaskId, boardId: self.boardAId) {
                    let parentMax = self.taskMap[parentTaskId]?.maxCount ?? 0
                    let parentCurrent = parentBT.currentCount ?? 0
                    let rolledUp = min(parentCurrent + 1, parentMax)
                    let parentNowCompleted = rolledUp >= parentMax

                    try AppDatabase.shared.write { db in
                        try db.execute(
                            sql: """
                                UPDATE \(BoardTask.databaseTableName)
                                SET currentCount = ?, isCompleted = ?, completedAt = ?,
                                    updatedAt = ?, version = version + 1
                                WHERE id = ?
                                """,
                            arguments: [
                                rolledUp,
                                parentNowCompleted ? 1 : 0,
                                parentNowCompleted ? now : nil,
                                now,
                                parentBT.id
                            ]
                        )
                    }
                }

                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.showSuccess("Rollup: +1 → parent now \(newCount)/\(maxCount)")
                    self.refreshBoards()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.showError("Failed to update counting task: \(error.localizedDescription)")
                }
            }
        }
    }

    /// Toggles a step-task square on Board B and, when newly completed, appends its
    /// associated stepId to the parent progress task's completedStepIds on Board A.
    ///
    /// - Parameter boardTask: The step-task's BoardTask record.
    private func handleStepTaskTap(boardTask: BoardTask) {
        isProcessing = true
        let now = AppDatabase.currentTimestamp()
        let wasCompleted = boardTask.isCompleted
        let nowCompleted = !wasCompleted

        // Resolve which stepId corresponds to this taskId
        let stepEntry = stepTaskIds.first(where: { $0.taskId == boardTask.taskId })

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Toggle completion on the step-task square (Board B)
                try AppDatabase.shared.write { db in
                    try db.execute(
                        sql: """
                            UPDATE \(BoardTask.databaseTableName)
                            SET isCompleted = ?, completedAt = ?,
                                updatedAt = ?, version = version + 1
                            WHERE id = ?
                            """,
                        arguments: [
                            nowCompleted ? 1 : 0,
                            nowCompleted ? now : nil,
                            now,
                            boardTask.id
                        ]
                    )
                }

                // Rollup to parent on Board A when the step-task is newly completed
                if nowCompleted,
                   let stepId = stepEntry?.stepId,
                   let parentTaskId = self.progressParentTaskId,
                   let parentBT = try self.findParentBoardTask(taskId: parentTaskId, boardId: self.boardAId) {

                    var completedIds = parentBT.completedStepIds ?? []
                    if !completedIds.contains(stepId) {
                        completedIds.append(stepId)
                    }
                    let allStepsDone = completedIds.count >= self.totalStepCount && self.totalStepCount > 0
                    let jsonString: String
                    if let data = try? JSONEncoder().encode(completedIds),
                       let str = String(data: data, encoding: .utf8) {
                        jsonString = str
                    } else {
                        jsonString = "[]"
                    }

                    try AppDatabase.shared.write { db in
                        try db.execute(
                            sql: """
                                UPDATE \(BoardTask.databaseTableName)
                                SET completedStepIds = ?, isCompleted = ?, completedAt = ?,
                                    updatedAt = ?, version = version + 1
                                WHERE id = ?
                                """,
                            arguments: [
                                jsonString,
                                allStepsDone ? 1 : 0,
                                allStepsDone ? now : nil,
                                now,
                                parentBT.id
                            ]
                        )
                    }

                    DispatchQueue.main.async {
                        self.isProcessing = false
                        let shortId = String(stepId.prefix(8))
                        self.showSuccess("Step complete. Added step \(shortId)... to parent.")
                        self.refreshBoards()
                    }
                } else {
                    DispatchQueue.main.async {
                        self.isProcessing = false
                        self.refreshBoards()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.showError("Failed to update step task: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Decrement Handler

    /// Decrements the counting subtask's currentCount by 1 and reverses rollup on the parent.
    ///
    /// Mirrors `handleCountingSubtaskTap` in reverse: subtracts 1 from the subtask on Board B
    /// and subtracts 1 from the parent BoardTask on Board A (floored at 0). The subtask's
    /// completion flag is cleared whenever the count drops below maxCount.
    ///
    /// - Parameters:
    ///   - boardTask: The counting subtask's BoardTask record.
    ///   - task: The counting Task providing maxCount.
    private func handleCountingSubtaskDecrement(boardTask: BoardTask, task: Task) {
        guard let maxCount = task.maxCount else { return }
        let currentCount = boardTask.currentCount ?? 0
        guard currentCount > 0 else { return }

        isProcessing = true
        let now = AppDatabase.currentTimestamp()
        let newCount = currentCount - 1

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Decrement subtask on Board B and clear completion
                try AppDatabase.shared.write { db in
                    try db.execute(
                        sql: """
                            UPDATE \(BoardTask.databaseTableName)
                            SET currentCount = ?, isCompleted = 0, completedAt = NULL,
                                updatedAt = ?, version = version + 1
                            WHERE id = ?
                            """,
                        arguments: [newCount, now, boardTask.id]
                    )
                }

                // Reverse rollup: subtract 1 from parent on Board A, floored at 0
                if let parentTaskId = self.countingParentTaskId,
                   let parentBT = try self.findParentBoardTask(taskId: parentTaskId, boardId: self.boardAId) {
                    let parentCurrent = parentBT.currentCount ?? 0
                    let parentNewCount = max(parentCurrent - 1, 0)
                    let parentMax = self.taskMap[parentTaskId]?.maxCount ?? 0
                    let parentStillComplete = parentNewCount >= parentMax && parentMax > 0

                    try AppDatabase.shared.write { db in
                        try db.execute(
                            sql: """
                                UPDATE \(BoardTask.databaseTableName)
                                SET currentCount = ?, isCompleted = ?, completedAt = ?,
                                    updatedAt = ?, version = version + 1
                                WHERE id = ?
                                """,
                            arguments: [
                                parentNewCount,
                                parentStillComplete ? 1 : 0,
                                parentStillComplete ? now : nil,
                                now,
                                parentBT.id
                            ]
                        )
                    }
                }

                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.showSuccess("Rollup: -1 from parent")
                    self.refreshBoards()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.showError("Failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Detail Sheet

    /// The sheet content shown when `detailBoardTaskId` is non-nil.
    ///
    /// Resolves the BoardTask and Task from current state then delegates to the
    /// type-specific sub-view. The sheet auto-updates because `boardBTasks` is
    /// refreshed after every action via `refreshBoards()`.
    @ViewBuilder
    private var detailSheet: some View {
        if let btId = detailBoardTaskId,
           let bt = (boardATasks + boardBTasks).first(where: { $0.id == btId }),
           let task = taskMap[bt.taskId] {

            let isOnBoardB = boardBTasks.contains(where: { $0.id == btId })

            VStack(spacing: 0) {
                // ── Header ──
                HStack {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(task.title)
                            .font(.headline)
                        Text(detailTypeLabel(for: task.type))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }
                    Spacer()
                    Button("Done") { detailBoardTaskId = nil }
                        .fontWeight(.semibold)
                }
                .padding()
                .background(Color(.systemGroupedBackground))

                Divider()

                // ── Type-specific content ──
                List {
                    switch task.type {
                    case .counting:
                        countingDetailContent(boardTask: bt, task: task, interactive: isOnBoardB)
                    case .normal:
                        normalDetailContent(boardTask: bt, interactive: isOnBoardB)
                    case .progress:
                        progressDetailContent(boardTask: bt)
                    }
                }
                .listStyle(.insetGrouped)
            }
            .presentationDetents([.medium, .large])
        }
    }

    /// Returns a human-readable label for the task type, used in the detail sheet header.
    private func detailTypeLabel(for type: TaskType) -> String {
        switch type {
        case .normal:   return "Normal task"
        case .counting: return "Counting task"
        case .progress: return "Progress task"
        }
    }

    /// Detail content for counting tasks: progress bar, count display, +/- buttons.
    ///
    /// The +1 button calls `handleCountingSubtaskTap`; the -1 button calls
    /// `handleCountingSubtaskDecrement`. Both call `refreshBoards()` on completion so
    /// the sheet displays live-updated state.
    ///
    /// - Parameters:
    ///   - boardTask: The counting subtask's BoardTask (provides currentCount).
    ///   - task: The Task providing maxCount and unit.
    ///   - interactive: When false (Board A) the controls are hidden and count is read-only.
    @ViewBuilder
    private func countingDetailContent(boardTask: BoardTask, task: Task, interactive: Bool) -> some View {
        let current = boardTask.currentCount ?? 0
        let maxVal = task.maxCount ?? 0
        let unitText = task.unit ?? ""

        Section("Progress") {
            ProgressView(
                value: Double(min(current, maxVal)),
                total: Double(max(maxVal, 1))
            )
            .tint(.orange)
            .padding(.vertical, 4)

            Text("\(current) / \(maxVal)\(unitText.isEmpty ? "" : " \(unitText)")")
                .font(.subheadline)
                .foregroundColor(.secondary)

            if interactive {
                HStack(spacing: 24) {
                    // Minus button
                    Button {
                        handleCountingSubtaskDecrement(boardTask: boardTask, task: task)
                    } label: {
                        Image(systemName: "minus.circle")
                            .font(.title)
                            .foregroundColor(current > 0 ? .orange : .secondary)
                    }
                    .disabled(current == 0 || isProcessing)
                    .buttonStyle(.borderless)

                    Spacer()

                    Text("\(current)")
                        .font(.title2.monospacedDigit())
                        .fontWeight(.semibold)

                    Spacer()

                    // Plus button
                    Button {
                        handleCountingSubtaskTap(boardTask: boardTask, task: task)
                    } label: {
                        Image(systemName: "plus.circle.fill")
                            .font(.title)
                            .foregroundColor(current < maxVal ? .orange : .secondary)
                    }
                    .disabled(current >= maxVal || isProcessing)
                    .buttonStyle(.borderless)
                }
                .padding(.vertical, 4)
            }
        }

        if !interactive {
            Section {
                Label("Read-only — this is a parent board square", systemImage: "eye")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        }
    }

    /// Detail content for normal (step-task) tasks: a single toggle button.
    ///
    /// Tapping the button calls `handleStepTaskTap`, which toggles completion and
    /// rolls up the step's ID to the parent progress task on Board A.
    ///
    /// - Parameters:
    ///   - boardTask: The step-task's BoardTask (provides current completion state).
    ///   - interactive: When false (Board A squares) the toggle is suppressed.
    @ViewBuilder
    private func normalDetailContent(boardTask: BoardTask, interactive: Bool) -> some View {
        Section("Completion") {
            if interactive {
                Button {
                    handleStepTaskTap(boardTask: boardTask)
                } label: {
                    Label(
                        boardTask.isCompleted ? "Mark Incomplete" : "Mark Complete",
                        systemImage: boardTask.isCompleted ? "xmark.circle" : "checkmark.circle"
                    )
                    .foregroundColor(boardTask.isCompleted ? .red : .green)
                }
                .disabled(isProcessing)
            } else {
                Label(
                    boardTask.isCompleted ? "Completed" : "Not yet complete",
                    systemImage: boardTask.isCompleted ? "checkmark.circle.fill" : "circle"
                )
                .foregroundColor(boardTask.isCompleted ? .green : .secondary)
            }
        }
    }

    /// Detail content for progress tasks: a read-only list of steps with completion indicators.
    ///
    /// Progress tasks are not directly tappable on Board B — only their linked step-task
    /// squares are. This view shows which steps have been rolled up so far.
    ///
    /// - Parameter boardTask: The progress parent's BoardTask (provides completedStepIds).
    @ViewBuilder
    private func progressDetailContent(boardTask: BoardTask) -> some View {
        let completedIds = boardTask.completedStepIds ?? []

        Section("Steps") {
            if taskSteps.isEmpty {
                Text("No steps found")
                    .foregroundColor(.secondary)
            } else {
                ForEach(taskSteps, id: \.id) { step in
                    let isDone = completedIds.contains(step.id)
                    HStack {
                        Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(isDone ? .green : .secondary)
                        Text(step.title)
                            .foregroundColor(.primary)
                        Spacer()
                    }
                }
            }
        }

        Section {
            Label(
                "\(completedIds.count) of \(taskSteps.count) steps complete",
                systemImage: "list.bullet"
            )
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }

    // MARK: - Setup

    /// Creates all demo boards, tasks, steps, and board-task records in a single transaction.
    ///
    /// Board A ("Parent Board") holds the counting parent "Read 100 pages" and the progress
    /// parent "Clean House". Board B ("Subtask Board") holds the counting subtask "Read 25 pages"
    /// and three step-task squares (Vacuum, Dust, Mop) whose completions roll up to Board A.
    private func setupDemo() {
        isProcessing = true
        let now = AppDatabase.currentTimestamp()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // ── Tasks ──
                let countingParent = Task(
                    id: UUID().uuidString.lowercased(),
                    userId: playgroundUserId,
                    title: "Read 100 pages",
                    description: "Parent counting task",
                    type: .counting,
                    action: "Read",
                    unit: "pages",
                    maxCount: 100,
                    totalCompletions: 0,
                    totalInstances: 0,
                    createdAt: now,
                    updatedAt: now,
                    version: 1,
                    isDeleted: false
                )

                let countingSubtask = Task(
                    id: UUID().uuidString.lowercased(),
                    userId: playgroundUserId,
                    title: "Read 25 pages",
                    description: "Subtask of Read 100 pages",
                    type: .counting,
                    action: "Read",
                    unit: "pages",
                    maxCount: 25,
                    totalCompletions: 0,
                    totalInstances: 0,
                    createdAt: now,
                    updatedAt: now,
                    version: 1,
                    isDeleted: false
                )

                let progressParent = Task(
                    id: UUID().uuidString.lowercased(),
                    userId: playgroundUserId,
                    title: "Clean House",
                    description: "Parent progress task with 3 steps",
                    type: .progress,
                    totalCompletions: 0,
                    totalInstances: 0,
                    createdAt: now,
                    updatedAt: now,
                    version: 1,
                    isDeleted: false
                )

                let vacuumTask = Task(
                    id: UUID().uuidString.lowercased(),
                    userId: playgroundUserId,
                    title: "Vacuum",
                    type: .normal,
                    totalCompletions: 0,
                    totalInstances: 0,
                    createdAt: now,
                    updatedAt: now,
                    version: 1,
                    isDeleted: false
                )

                let dustTask = Task(
                    id: UUID().uuidString.lowercased(),
                    userId: playgroundUserId,
                    title: "Dust",
                    type: .normal,
                    totalCompletions: 0,
                    totalInstances: 0,
                    createdAt: now,
                    updatedAt: now,
                    version: 1,
                    isDeleted: false
                )

                let mopTask = Task(
                    id: UUID().uuidString.lowercased(),
                    userId: playgroundUserId,
                    title: "Mop",
                    type: .normal,
                    totalCompletions: 0,
                    totalInstances: 0,
                    createdAt: now,
                    updatedAt: now,
                    version: 1,
                    isDeleted: false
                )

                // ── Boards ──
                let boardA = Board.makePlayground(
                    id: UUID().uuidString.lowercased(),
                    userId: playgroundUserId,
                    name: "Parent Board",
                    now: now
                )

                let boardB = Board.makePlayground(
                    id: UUID().uuidString.lowercased(),
                    userId: playgroundUserId,
                    name: "Subtask Board",
                    now: now
                )

                // ── TaskSteps for "Clean House" ──
                let step1 = TaskStep(
                    id: UUID().uuidString.lowercased(),
                    taskId: progressParent.id,
                    stepIndex: 0,
                    title: "Vacuum",
                    type: .normal,
                    linkedTaskId: vacuumTask.id,
                    createdAt: now,
                    updatedAt: now,
                    version: 1,
                    isDeleted: false
                )

                let step2 = TaskStep(
                    id: UUID().uuidString.lowercased(),
                    taskId: progressParent.id,
                    stepIndex: 1,
                    title: "Dust",
                    type: .normal,
                    linkedTaskId: dustTask.id,
                    createdAt: now,
                    updatedAt: now,
                    version: 1,
                    isDeleted: false
                )

                let step3 = TaskStep(
                    id: UUID().uuidString.lowercased(),
                    taskId: progressParent.id,
                    stepIndex: 2,
                    title: "Mop",
                    type: .normal,
                    linkedTaskId: mopTask.id,
                    createdAt: now,
                    updatedAt: now,
                    version: 1,
                    isDeleted: false
                )

                // ── Board Tasks ──
                // Board A: countingParent at (0,0), progressParent at (0,1)
                let btA1 = BoardTask.makePlayground(
                    boardId: boardA.id, taskId: countingParent.id,
                    row: 0, col: 0, now: now
                )
                let btA2 = BoardTask.makePlayground(
                    boardId: boardA.id, taskId: progressParent.id,
                    row: 0, col: 1, now: now,
                    initialCompletedStepIds: []
                )

                // Board B: countingSubtask at (0,0), step-tasks at (0,1), (0,2), (1,0)
                let btB1 = BoardTask.makePlayground(
                    boardId: boardB.id, taskId: countingSubtask.id,
                    row: 0, col: 0, now: now,
                    initialCurrentCount: 0
                )
                let btB2 = BoardTask.makePlayground(
                    boardId: boardB.id, taskId: vacuumTask.id,
                    row: 0, col: 1, now: now
                )
                let btB3 = BoardTask.makePlayground(
                    boardId: boardB.id, taskId: dustTask.id,
                    row: 0, col: 2, now: now
                )
                let btB4 = BoardTask.makePlayground(
                    boardId: boardB.id, taskId: mopTask.id,
                    row: 1, col: 0, now: now
                )

                // ── Write everything in one transaction ──
                try AppDatabase.shared.write { db in
                    try countingParent.save(db)
                    try countingSubtask.save(db)
                    try progressParent.save(db)
                    try vacuumTask.save(db)
                    try dustTask.save(db)
                    try mopTask.save(db)
                    try boardA.save(db)
                    try boardB.save(db)
                    try step1.save(db)
                    try step2.save(db)
                    try step3.save(db)
                    try btA1.save(db)
                    try btA2.save(db)
                    try btB1.save(db)
                    try btB2.save(db)
                    try btB3.save(db)
                    try btB4.save(db)
                }

                DispatchQueue.main.async {
                    self.countingParentTaskId = countingParent.id
                    self.countingSubtaskTaskId = countingSubtask.id
                    self.progressParentTaskId = progressParent.id
                    self.stepTaskIds = [
                        (taskId: vacuumTask.id, stepId: step1.id),
                        (taskId: dustTask.id,   stepId: step2.id),
                        (taskId: mopTask.id,    stepId: step3.id)
                    ]
                    self.boardAId = boardA.id
                    self.boardBId = boardB.id
                    self.isSetUp = true
                    self.isProcessing = false
                    self.refreshBoards()
                }
            } catch {
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.showError("Setup failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Reset

    /// Soft-deletes the demo boards and all associated tasks, then resets all state.
    ///
    /// Does not hard-delete — consistent with offline-first soft-delete convention.
    private func resetDemo() {
        isProcessing = true
        let now = AppDatabase.currentTimestamp()
        let boardIds = [boardAId, boardBId].compactMap { $0 }
        let taskIds = [countingParentTaskId, countingSubtaskTaskId, progressParentTaskId]
            .compactMap { $0 } + stepTaskIds.map { $0.taskId }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                for boardId in boardIds {
                    try AppDatabase.shared.write { db in
                        try db.execute(
                            sql: "UPDATE \(Board.databaseTableName) SET isDeleted = 1, deletedAt = ?, updatedAt = ?, version = version + 1 WHERE id = ?",
                            arguments: [now, now, boardId]
                        )
                    }
                }
                for taskId in taskIds {
                    try AppDatabase.shared.write { db in
                        try db.execute(
                            sql: "UPDATE \(Task.databaseTableName) SET isDeleted = 1, deletedAt = ?, updatedAt = ?, version = version + 1 WHERE id = ?",
                            arguments: [now, now, taskId]
                        )
                    }
                }
                DispatchQueue.main.async {
                    self.resetState()
                    self.isProcessing = false
                    self.showSuccess("Demo reset. Tap \"Set Up Demo Boards\" to start again.")
                }
            } catch {
                DispatchQueue.main.async {
                    self.isProcessing = false
                    self.showError("Reset failed: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Data Refresh

    /// Reloads BoardTask records for both boards and refreshes the task/step lookup arrays.
    private func refreshBoards() {
        guard let aId = boardAId, let bId = boardBId else { return }

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let aTasks = try AppDatabase.shared.fetchBoardTasks(boardId: aId)
                let bTasks = try AppDatabase.shared.fetchBoardTasks(boardId: bId)

                let allTaskIds = Set((aTasks + bTasks).map { $0.taskId })
                let allTasks = try AppDatabase.shared.read { db in
                    try Task.filter(keys: Array(allTaskIds)).fetchAll(db)
                }

                let steps: [TaskStep]
                if let progressId = self.progressParentTaskId {
                    steps = try AppDatabase.shared.fetchTaskSteps(taskId: progressId)
                } else {
                    steps = []
                }

                DispatchQueue.main.async {
                    self.boardATasks = aTasks
                    self.boardBTasks = bTasks
                    self.tasks = allTasks
                    self.taskSteps = steps
                }
            } catch {
                DispatchQueue.main.async {
                    self.showError("Failed to refresh boards: \(error.localizedDescription)")
                }
            }
        }
    }

    // MARK: - Helpers

    /// Looks up the BoardTask for a given taskId on a specific board.
    ///
    /// - Parameters:
    ///   - taskId: The task to find.
    ///   - boardId: The board to search within (optional guard for safety).
    /// - Returns: The matching BoardTask, or nil if not found.
    /// - Throws: GRDB database errors.
    private func findParentBoardTask(taskId: String, boardId: String?) throws -> BoardTask? {
        guard let boardId = boardId else { return nil }
        return try AppDatabase.shared.read { db in
            try BoardTask
                .filter(Column("taskId") == taskId && Column("boardId") == boardId)
                .fetchOne(db)
        }
    }

    /// Clears all playground-level state back to defaults.
    private func resetState() {
        isSetUp = false
        selectedBoard = .parent
        boardAId = nil
        boardBId = nil
        boardATasks = []
        boardBTasks = []
        tasks = []
        taskSteps = []
        countingParentTaskId = nil
        countingSubtaskTaskId = nil
        progressParentTaskId = nil
        stepTaskIds = []
    }

    /// Shows a success banner that auto-dismisses after `successDismissSeconds`.
    ///
    /// - Parameter message: The success string to display.
    private func showSuccess(_ message: String) {
        successMessage = message
        errorMessage = nil
        DispatchQueue.main.asyncAfter(deadline: .now() + successDismissSeconds) {
            if self.successMessage == message {
                self.successMessage = nil
            }
        }
    }

    /// Shows an error banner that stays visible until replaced or cleared.
    ///
    /// - Parameter message: The error string to display.
    private func showError(_ message: String) {
        errorMessage = message
        successMessage = nil
    }
}

// MARK: - Board Factory Extension

extension Board {
    /// Creates a Board value with safe defaults suitable for playground demos.
    ///
    /// All required fields use safe defaults (active status, weekly timeframe, 3x3 size,
    /// no center square). This avoids duplicating the large custom Codable init at call sites.
    ///
    /// - Parameters:
    ///   - id: Board UUID string.
    ///   - userId: Owning user ID.
    ///   - name: Board display name.
    ///   - now: ISO8601 timestamp string for all date fields.
    /// - Returns: A fully initialised Board ready to be saved.
    static func makePlayground(id: String, userId: String, name: String, now: String, centerSquareType: String = "none") -> Board {
        // Encode a minimal dict and decode through the model's own Codable path
        let dict: [String: Any] = [
            "id": id,
            "userId": userId,
            "name": name,
            "status": "active",
            "boardSize": 3,
            "timeframe": "weekly",
            "startDate": now,
            "endDate": now,
            "centerSquareType": centerSquareType,
            "isRandomized": false,
            "totalTasks": 0,
            "completedTasks": 0,
            "linesCompleted": 0,
            "createdAt": now,
            "updatedAt": now,
            "version": 1,
            "isDeleted": false
        ]
        // Encoding through Foundation JSON is safe and deterministic for these primitive types.
        // Force-unwrap is intentional: a programming error in the dict above should fail loudly.
        let data = try! JSONSerialization.data(withJSONObject: dict) // swiftlint:disable:this force_try
        return try! JSONDecoder().decode(Board.self, from: data) // swiftlint:disable:this force_try
    }
}

// MARK: - BoardTask Factory Extension

extension BoardTask {
    /// Creates a BoardTask value with safe defaults suitable for playground demos.
    ///
    /// - Parameters:
    ///   - boardId: The owning board's ID.
    ///   - taskId: The task placed at this position.
    ///   - row: Grid row (0-based).
    ///   - col: Grid column (0-based).
    ///   - now: ISO8601 timestamp string.
    ///   - initialCurrentCount: Optional starting count for counting tasks (nil otherwise).
    ///   - initialCompletedStepIds: Optional starting step IDs for progress tasks (nil otherwise).
    /// - Returns: A fully initialised BoardTask ready to be saved.
    static func makePlayground(
        boardId: String,
        taskId: String,
        row: Int,
        col: Int,
        now: String,
        isCenter: Bool = false,
        initialCurrentCount: Int? = nil,
        initialCompletedStepIds: [String]? = nil
    ) -> BoardTask {
        // Post-unification: BoardTask is placement-only (completion lives on
        // Task). The legacy `initialCurrentCount` / `initialCompletedStepIds`
        // parameters are retained for source-compat with existing call sites
        // but are now ignored — caller should set Task.currentCount /
        // compound_children rows separately. Uses the explicit memberwise
        // init added in the compound-tasks-unification refactor.
        _ = initialCurrentCount
        _ = initialCompletedStepIds
        return BoardTask(
            id: UUID().uuidString.lowercased(),
            boardId: boardId,
            taskId: taskId,
            row: row,
            col: col,
            isCenter: isCenter,
            createdAt: now,
            updatedAt: now,
            version: 1
        )
    }
}

// MARK: - TaskStep Memberwise Init Extension

extension TaskStep {
    /// Creates a fully populated TaskStep for use in playground setup.
    ///
    /// TaskStep's synthesised init is the Codable one; this memberwise init avoids a
    /// JSON round-trip at setup call sites.
    ///
    /// - Parameters:
    ///   - id: Unique step ID.
    ///   - taskId: Parent task ID.
    ///   - stepIndex: Zero-based position within the parent task's steps.
    ///   - title: Display name of the step.
    ///   - type: TaskType of the step (usually `.normal`).
    ///   - linkedTaskId: Optional task ID that this step is linked to.
    ///   - createdAt: ISO8601 creation timestamp.
    ///   - updatedAt: ISO8601 last-update timestamp.
    ///   - version: Sync version counter.
    ///   - isDeleted: Soft-delete flag.
    init(
        id: String,
        taskId: String,
        stepIndex: Int,
        title: String,
        type: TaskType,
        linkedTaskId: String? = nil,
        createdAt: String,
        updatedAt: String,
        version: Int,
        isDeleted: Bool
    ) {
        self.id = id
        self.taskId = taskId
        self.stepIndex = stepIndex
        self.title = title
        self.type = type
        self.action = nil
        self.unit = nil
        self.maxCount = nil
        self.linkedTaskId = linkedTaskId
        self.createdAt = createdAt
        self.updatedAt = updatedAt
        self.lastSyncedAt = nil
        self.version = version
        self.isDeleted = isDeleted
        self.deletedAt = nil
    }
}
#endif
