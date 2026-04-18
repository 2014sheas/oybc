import SwiftUI
import GRDB

// MARK: - Sync Queue Helpers (private to this file)

/// Encodes a `Codable` value to a JSON string for storage in the sync queue payload.
///
/// - Parameter value: The value to encode.
/// - Returns: A JSON string, or an empty JSON object string `"{}"` on failure.
private func encodeSyncPayload<T: Codable>(_ value: T) -> String {
    guard
        let data = try? JSONEncoder().encode(value),
        let string = String(data: data, encoding: .utf8)
    else { return "{}" }
    return string
}

/// Builds a `SyncQueueItem` for a local write that should be synced to Firestore.
///
/// - Parameters:
///   - entityType: The Firestore collection name (e.g. `"boards"`, `"tasks"`).
///   - entityId: The primary key of the entity.
///   - operationType: `.create`, `.update`, or `.delete`.
///   - payload: A `Codable` value whose JSON representation is stored as the payload.
///   - now: The current ISO8601 timestamp.
/// - Returns: A new `SyncQueueItem` with `status = .pending`.
private func makeSyncItem<T: Codable>(
    entityType: String,
    entityId: String,
    operationType: SyncOperationType,
    payload: T,
    now: String
) -> SyncQueueItem {
    SyncQueueItem(
        id: AppDatabase.generateUUID(),
        entityType: entityType,
        entityId: entityId,
        operationType: operationType,
        payload: encodeSyncPayload(payload),
        status: .pending,
        retryCount: 0,
        lastError: nil,
        createdAt: now,
        lastAttemptAt: nil,
        completedAt: nil,
        priority: 1
    )
}

// MARK: - Board Lifecycle Playground

/// Board Lifecycle Playground.
///
/// Demonstrates the full board lifecycle end-to-end:
///
/// 1. **Board List** — shows all boards for the playground user with status badges,
///    completion progress fractions, and bingo line counts. Tap any row to select it
///    for play. "Create Demo Board" seeds a 3×3 board with a FREE center and 8 tasks.
///
/// 2. **Board Play** — interactive bingo grid for the selected board.  Tapping squares
///    drives task completion which runs `BingoDetection.detectBingos` after every action.
///    New bingo lines surface as transient messages. When the last square is checked the
///    board auto-transitions to `.completed` (GREENLOG state).
///
/// **Status transitions demonstrated**:
/// - DRAFT → ACTIVE on first interaction.
/// - ACTIVE → COMPLETED on full-board greenlog.
struct BoardLifecyclePlayground: View {

    // MARK: - Parameters

    /// Week-start value used for timeframe boundary math. Defaults to
    /// `.defaults.weekStartDay.rawValue` so this view works in previews and
    /// playground surfaces that aren't behind the auth shell. Production
    /// callers (e.g. `PlaygroundView` rendered inside the signed-in
    /// `ProfileView`) pass `authService.userPreferences.weekStartDay.rawValue`.
    var weekStartDay: String = UserPreferences.defaults.weekStartDay.rawValue

    // MARK: - State

    @State private var boards: [Board] = []
    @State private var selectedBoardId: String? = nil
    @State private var boardTasks: [BoardTask] = []
    @State private var tasks: [Task] = []
    @State private var taskSteps: [TaskStep] = []

    @State private var isCreatingDemo = false
    @State private var isProcessing = false
    @State private var errorMessage: String? = nil
    @State private var bingoMessage: String? = nil
    @State private var detailBoardTaskId: String? = nil

    // MARK: - Computed

    /// The board currently selected for play.
    private var selectedBoard: Board? {
        guard let id = selectedBoardId else { return nil }
        return boards.first(where: { $0.id == id })
    }

    /// O(1) task lookup by ID.
    private var taskMap: [String: Task] {
        Dictionary(uniqueKeysWithValues: tasks.map { ($0.id, $0) })
    }

    /// Board tasks for the selected board sorted by row then column.
    private var sortedBoardTasks: [BoardTask] {
        boardTasks.sorted { $0.row == $1.row ? $0.col < $1.col : $0.row < $1.row }
    }

    /// Grid size for the selected board (falls back to 3).
    private var gridSize: Int {
        selectedBoard?.boardSize ?? 3
    }

    /// Whether the currently selected board has expired (past its end date, non-Custom timeframe).
    private var isSelectedBoardExpired: Bool {
        guard let board = selectedBoard else { return false }
        return isBoardExpired(board)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // ── Error banner ──
            if let msg = errorMessage {
                Text(msg)
                    .font(.subheadline)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.12))
                    .foregroundColor(.red)
                    .cornerRadius(8)
            }

            // ── Bingo message banner ──
            if let msg = bingoMessage {
                Text(msg)
                    .font(.subheadline)
                    .fontWeight(.semibold)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(msg == "GREENLOG!" ? Color.green.opacity(0.2) : Color.accentColor.opacity(0.15))
                    .foregroundColor(msg == "GREENLOG!" ? .green : .accentColor)
                    .cornerRadius(8)
            }

            boardListSection

            if selectedBoard != nil {
                Divider()
                boardPlaySection
            }
        }
        .onAppear {
            ensurePlaygroundUser()
            loadBoards()
        }
        .sheet(isPresented: Binding(
            get: { detailBoardTaskId != nil },
            set: { if !$0 { detailBoardTaskId = nil } }
        )) {
            detailSheet
        }
    }

    // MARK: - Board List Section

    @ViewBuilder
    private var boardListSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack {
                Text("Board List")
                    .font(.headline)
                Spacer()
                Button {
                    createDemoBoard()
                } label: {
                    Text(isCreatingDemo ? "Creating..." : "Create Demo Board")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .padding(.horizontal, 12)
                        .padding(.vertical, 6)
                        .background(Color.accentColor)
                        .foregroundColor(.white)
                        .clipShape(Capsule())
                }
                .disabled(isCreatingDemo || isProcessing)
            }

            if boards.isEmpty {
                Text("No boards yet — tap \"Create Demo Board\" to get started.")
                    .font(.subheadline)
                    .foregroundColor(.secondary)
            } else {
                ForEach(boards, id: \.id) { board in
                    boardRow(board)
                }
            }
        }
    }

    /// A single board row showing name, status badge, progress, and bingo count.
    ///
    /// - Parameter board: The board to display.
    @ViewBuilder
    private func boardRow(_ board: Board) -> some View {
        let isSelected = board.id == selectedBoardId
        let total = board.totalTasks
        let completed = board.completedTasks

        Button {
            selectBoard(board)
        } label: {
            HStack(spacing: 10) {
                VStack(alignment: .leading, spacing: 4) {
                    Text(board.name)
                        .font(.subheadline)
                        .fontWeight(.medium)
                        .foregroundColor(.primary)

                    // Timeframe label (e.g. "Week of Mar 23 – 29, 2026")
                    if board.timeframe != .custom {
                        Text(boardTimeframeLabel(for: board))
                            .font(.caption)
                            .foregroundColor(.secondary)
                    }

                    HStack(spacing: 8) {
                        // Progress fraction
                        Text("\(completed)/\(total) tasks")
                            .font(.caption)
                            .foregroundColor(.secondary)

                        if board.linesCompleted > 0 {
                            Text("\(board.linesCompleted) \(board.linesCompleted == 1 ? "bingo" : "bingos")")
                                .font(.caption)
                                .foregroundColor(.accentColor)
                        }

                        // Expiry indicator
                        let expiryLabel = getExpiryLabel(board)
                        let expired = isBoardExpired(board)
                        Text(expiryLabel)
                            .font(.caption)
                            .foregroundColor(expired ? .red : .secondary)
                    }

                    // Progress bar
                    ProgressView(value: total > 0 ? Double(completed) / Double(total) : 0)
                        .tint(completed == total && total > 0 ? .green : .accentColor)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                statusBadge(for: board.status)
            }
            .padding(10)
            .background(isSelected ? Color.accentColor.opacity(0.12) : Color(.systemGray6))
            .cornerRadius(8)
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.accentColor : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
    }

    /// A colored badge displaying the board's status.
    ///
    /// - Parameter status: The `BoardStatus` to render.
    @ViewBuilder
    private func statusBadge(for status: BoardStatus) -> some View {
        let (label, bg): (String, Color) = {
            switch status {
            case .draft:      return ("DRAFT", Color(.systemGray4))
            case .active:     return ("ACTIVE", Color.accentColor)
            case .completed:  return ("COMPLETED", Color.green)
            case .archived:   return ("ARCHIVED", Color.orange)
            }
        }()

        Text(label)
            .font(.caption2)
            .fontWeight(.bold)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(bg)
            .foregroundColor(status == .draft ? .primary : .white)
            .clipShape(Capsule())
    }

    // MARK: - Board Play Section

    @ViewBuilder
    private var boardPlaySection: some View {
        if let board = selectedBoard {
        VStack(alignment: .leading, spacing: 12) {
            // ── Header ──
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(board.name)
                        .font(.headline)
                    Text("\(board.completedTasks)/\(board.totalTasks) tasks · \(board.linesCompleted) \(board.linesCompleted == 1 ? "line" : "lines")")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                statusBadge(for: board.status)
            }

            // ── Grid ──
            let columnCount = gridSize
            LazyVGrid(
                columns: Array(repeating: GridItem(.fixed(90), spacing: 8), count: columnCount),
                spacing: 8
            ) {
                ForEach(sortedBoardTasks, id: \.id) { bt in
                    if bt.isCenter {
                        // FREE center square — always completed, not interactive
                        InteractiveTaskSquareView(
                            title: "FREE",
                            taskType: .normal,
                            isCompleted: true,
                            isReadOnly: true
                        )
                    } else {
                        playSquare(boardTask: bt)
                    }
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // ── Expired banner ──
            if isSelectedBoardExpired {
                let expiredDate = board.endDate.prefix(10)
                Text("Board expired on \(expiredDate)")
                    .font(.subheadline)
                    .padding(10)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.red.opacity(0.12))
                    .foregroundColor(.red)
                    .cornerRadius(8)
            }

            // ── Reset ──
            Button {
                resetSelectedBoard()
            } label: {
                Text("Reset Board Progress")
                    .font(.caption)
                    .foregroundColor(.red)
            }
            .disabled(isProcessing)
        }
        }
    }

    /// Builds a tappable `InteractiveTaskSquareView` for a non-center board task.
    ///
    /// - Normal: tap toggles completion.
    /// - Counting: tap increments +1.
    /// - Progress: tap opens the detail sheet for step checkboxes.
    ///
    /// - Parameter boardTask: The BoardTask to render.
    @ViewBuilder
    private func playSquare(boardTask: BoardTask) -> some View {
        let task = taskMap[boardTask.taskId]
        let taskType = task?.type ?? .normal
        let isCompleted = boardTask.isCompleted

        switch taskType {
        case .normal:
            InteractiveTaskSquareView(
                title: task?.title ?? "Unknown",
                taskType: .normal,
                isCompleted: isCompleted,
                onTap: {
                    guard !isSelectedBoardExpired else { return }
                    handleNormalTap(boardTask: boardTask)
                }
            )
            .contextMenu {
                Button(
                    isCompleted ? "Mark Incomplete" : "Mark Complete",
                    systemImage: "checkmark.circle"
                ) {
                    guard !isSelectedBoardExpired else { return }
                    handleNormalTap(boardTask: boardTask)
                }
                .disabled(isProcessing || isSelectedBoardExpired)
                Button("View Details", systemImage: "info.circle") {
                    detailBoardTaskId = boardTask.id
                }
            }

        case .counting:
            let current = boardTask.currentCount ?? 0
            let maxVal = task?.maxCount ?? 0
            let unitText = task?.unit ?? ""
            let actionLabel = task?.action ?? "item"
            InteractiveTaskSquareView(
                title: task?.title ?? "Unknown",
                taskType: .counting,
                isCompleted: isCompleted,
                currentCount: current,
                maxCount: maxVal,
                unit: unitText,
                onTap: {
                    guard !isSelectedBoardExpired else { return }
                    if let t = task { handleCountingTap(boardTask: boardTask, task: t) }
                }
            )
            .contextMenu {
                if let t = task {
                    Button("+ Add \(actionLabel)", systemImage: "plus") {
                        guard !isSelectedBoardExpired else { return }
                        handleCountingTap(boardTask: boardTask, task: t)
                    }
                    .disabled(current >= maxVal || isProcessing || isSelectedBoardExpired)
                    Button("- Remove \(actionLabel)", systemImage: "minus") {
                        guard !isSelectedBoardExpired else { return }
                        handleCountingDecrement(boardTask: boardTask, task: t)
                    }
                    .disabled(current == 0 || isProcessing || isSelectedBoardExpired)
                    Button("View Details", systemImage: "info.circle") {
                        detailBoardTaskId = boardTask.id
                    }
                }
            }

        case .progress:
            let completedStepsCount = boardTask.completedStepIds?.count ?? 0
            let stepsForTask = taskSteps.filter { $0.taskId == boardTask.taskId }
            let total = stepsForTask.count > 0 ? stepsForTask.count : 1
            ZStack {
                InteractiveTaskSquareView(
                    title: task?.title ?? "Unknown",
                    taskType: .progress,
                    isCompleted: isCompleted,
                    completedSteps: completedStepsCount,
                    totalSteps: total
                )
                // Transparent overlay intercepts taps — InteractiveTaskSquareView
                // internally blocks onTap for progress type via isTappable guard.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard !isSelectedBoardExpired else { return }
                        detailBoardTaskId = boardTask.id
                    }
            }
            .frame(width: 90, height: 90)
            .contextMenu {
                Button("View Steps", systemImage: "list.bullet") {
                    detailBoardTaskId = boardTask.id
                }
                Button("Mark All Complete", systemImage: "checkmark.circle.fill") {
                    guard !isSelectedBoardExpired else { return }
                    handleProgressCompleteAll(boardTask: boardTask)
                }
                .disabled(isCompleted || isProcessing || isSelectedBoardExpired)
                Button("Mark Incomplete", systemImage: "xmark.circle") {
                    guard !isSelectedBoardExpired else { return }
                    handleProgressReset(boardTask: boardTask)
                }
                .disabled(!isCompleted || isProcessing || isSelectedBoardExpired)
            }
        }
    }

    // MARK: - Detail Sheet

    @ViewBuilder
    private var detailSheet: some View {
        if let btId = detailBoardTaskId,
           let bt = boardTasks.first(where: { $0.id == btId }),
           let task = taskMap[bt.taskId] {
            VStack(spacing: 0) {
                // Header
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

                List {
                    switch task.type {
                    case .normal:
                        normalDetailContent(boardTask: bt)
                    case .counting:
                        countingDetailContent(boardTask: bt, task: task)
                    case .progress:
                        progressDetailContent(boardTask: bt, task: task)
                    }
                }
                .listStyle(.insetGrouped)
            }
            .presentationDetents([.medium, .large])
        }
    }

    /// Human-readable label for task type used in the detail sheet header.
    private func detailTypeLabel(for type: TaskType) -> String {
        switch type {
        case .normal:   return "Normal task"
        case .counting: return "Counting task"
        case .progress: return "Progress task"
        }
    }

    @ViewBuilder
    private func normalDetailContent(boardTask: BoardTask) -> some View {
        Section("Completion") {
            Button {
                handleNormalTap(boardTask: boardTask)
                detailBoardTaskId = nil
            } label: {
                Label(
                    boardTask.isCompleted ? "Mark Incomplete" : "Mark Complete",
                    systemImage: boardTask.isCompleted ? "xmark.circle" : "checkmark.circle"
                )
                .foregroundColor(boardTask.isCompleted ? .red : .green)
            }
            .disabled(isProcessing)
        }
    }

    @ViewBuilder
    private func countingDetailContent(boardTask: BoardTask, task: Task) -> some View {
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

            HStack(spacing: 24) {
                Button {
                    handleCountingDecrement(boardTask: boardTask, task: task)
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

                Button {
                    handleCountingTap(boardTask: boardTask, task: task)
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

    @ViewBuilder
    private func progressDetailContent(boardTask: BoardTask, task: Task) -> some View {
        let completedIds = boardTask.completedStepIds ?? []
        let stepsForTask = taskSteps.filter { $0.taskId == task.id }

        Section("Steps") {
            if stepsForTask.isEmpty {
                Text("No steps found")
                    .foregroundColor(.secondary)
            } else {
                ForEach(stepsForTask, id: \.id) { step in
                    let isDone = completedIds.contains(step.id)
                    Button {
                        handleProgressStepTap(boardTask: boardTask, step: step, isDone: isDone)
                    } label: {
                        HStack {
                            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(isDone ? .green : .secondary)
                            Text(step.title)
                                .foregroundColor(.primary)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isProcessing)
                }
            }
        }

        Section {
            Label(
                "\(completedIds.count) of \(stepsForTask.count) steps complete",
                systemImage: "list.bullet"
            )
            .font(.caption)
            .foregroundColor(.secondary)
        }
    }

    // MARK: - Expiry & Timeframe Helpers
    //
    // Delegates to shared utilities in PlaygroundUtils.swift:
    //   - isBoardExpired(_:)
    //   - getExpiryLabel(_:)
    //   - playgroundTimeframeLabel(timeframe:startDate:)
    //   - parseISO8601Date(_:)

    /// Returns the timeframe label for a board's list row, or empty string if Custom.
    private func boardTimeframeLabel(for board: Board) -> String {
        guard board.timeframe != .custom else { return "" }
        guard let start = parseISO8601Date(board.startDate) else { return "" }
        return playgroundTimeframeLabel(timeframe: board.timeframe, startDate: start)
    }

    // MARK: - Tap Handlers

    /// Toggles completion of a normal task square and runs the full bingo orchestration.
    ///
    /// - Parameter boardTask: The tapped BoardTask.
    private func handleNormalTap(boardTask: BoardTask) {
        guard !isProcessing else { return }
        let newCompleted = !boardTask.isCompleted
        let now = AppDatabase.currentTimestamp()

        var updated = boardTask
        updated.isCompleted = newCompleted
        updated.completedAt = newCompleted ? now : nil
        updated.updatedAt = now
        updated.version += 1

        runOrchestration(updatedBoardTask: updated)
    }

    /// Increments a counting task's currentCount by 1 and marks complete at maxCount.
    ///
    /// - Parameters:
    ///   - boardTask: The counting task's BoardTask record.
    ///   - task: The Task providing maxCount.
    private func handleCountingTap(boardTask: BoardTask, task: Task) {
        guard !isProcessing, !boardTask.isCompleted, let maxCount = task.maxCount else { return }
        let now = AppDatabase.currentTimestamp()
        let newCount = min((boardTask.currentCount ?? 0) + 1, maxCount)
        let nowCompleted = newCount >= maxCount

        var updated = boardTask
        updated.currentCount = newCount
        updated.isCompleted = nowCompleted
        updated.completedAt = nowCompleted ? now : nil
        updated.updatedAt = now
        updated.version += 1

        runOrchestration(updatedBoardTask: updated)
    }

    /// Decrements a counting task's currentCount by 1 and un-marks completion.
    ///
    /// - Parameters:
    ///   - boardTask: The counting task's BoardTask record.
    ///   - task: The Task providing unit metadata (unused here but kept for symmetry).
    private func handleCountingDecrement(boardTask: BoardTask, task: Task) {
        guard !isProcessing else { return }
        let now = AppDatabase.currentTimestamp()
        let newCount = max((boardTask.currentCount ?? 0) - 1, 0)

        var updated = boardTask
        updated.currentCount = newCount
        updated.isCompleted = false
        updated.completedAt = nil
        updated.updatedAt = now
        updated.version += 1

        runOrchestration(updatedBoardTask: updated)
    }

    /// Toggles a single progress step for a board task and recomputes completion.
    ///
    /// - Parameters:
    ///   - boardTask: The progress task's BoardTask record.
    ///   - step: The `TaskStep` being toggled.
    ///   - isDone: The current state of the step (true = already complete).
    private func handleProgressStepTap(boardTask: BoardTask, step: TaskStep, isDone: Bool) {
        guard !isProcessing else { return }
        let now = AppDatabase.currentTimestamp()

        var currentIds = boardTask.completedStepIds ?? []
        if isDone {
            currentIds.removeAll(where: { $0 == step.id })
        } else {
            currentIds.append(step.id)
        }

        let stepsForTask = taskSteps.filter { $0.taskId == boardTask.taskId }
        let nowCompleted = currentIds.count >= stepsForTask.count && !stepsForTask.isEmpty

        var updated = boardTask
        updated.completedStepIds = currentIds
        updated.isCompleted = nowCompleted
        updated.completedAt = nowCompleted ? now : nil
        updated.updatedAt = now
        updated.version += 1

        runOrchestration(updatedBoardTask: updated)
    }

    /// Marks all steps for a progress task as complete.
    ///
    /// - Parameter boardTask: The progress task's BoardTask record.
    private func handleProgressCompleteAll(boardTask: BoardTask) {
        guard !isProcessing else { return }
        let now = AppDatabase.currentTimestamp()
        let stepsForTask = taskSteps.filter { $0.taskId == boardTask.taskId }
        let allIds = stepsForTask.map { $0.id }

        var updated = boardTask
        updated.completedStepIds = allIds
        updated.isCompleted = !allIds.isEmpty
        updated.completedAt = !allIds.isEmpty ? now : nil
        updated.updatedAt = now
        updated.version += 1

        runOrchestration(updatedBoardTask: updated)
    }

    /// Clears all completed step IDs and marks the progress task incomplete.
    ///
    /// - Parameter boardTask: The progress task's BoardTask record.
    private func handleProgressReset(boardTask: BoardTask) {
        guard !isProcessing else { return }
        let now = AppDatabase.currentTimestamp()

        var updated = boardTask
        updated.completedStepIds = []
        updated.isCompleted = false
        updated.completedAt = nil
        updated.updatedAt = now
        updated.version += 1

        runOrchestration(updatedBoardTask: updated)
    }

    // MARK: - Orchestration

    /// Runs the full task-completion orchestration in a single DB transaction.
    ///
    /// Steps:
    /// 1. Auto-activates the board if it is still DRAFT.
    /// 2. Saves the updated BoardTask.
    /// 3. Reloads all BoardTasks to rebuild the completion grid.
    /// 4. Runs `BingoDetection.detectBingos`.
    /// 5. Diffs new completed lines against the board's previous `completedLineIds`.
    /// 6. Updates board stats: `completedTasks`, `linesCompleted`, `completedLineIds`, `updatedAt`.
    /// 7. Auto-completes the board on greenlog.
    /// 8. Returns to the main thread to refresh state and display a bingo message.
    ///
    /// - Parameter updatedBoardTask: The already-mutated BoardTask to persist.
    private func runOrchestration(updatedBoardTask: BoardTask) {
        guard let board = selectedBoard else { return }
        isProcessing = true
        let now = AppDatabase.currentTimestamp()
        let previousLineIds = Set(board.completedLineIds ?? [])
        let size = board.boardSize

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                var newBingoMsg: String? = nil

                try AppDatabase.shared.write { db in
                    // 1. Auto-activate DRAFT boards on first interaction.
                    if board.status == .draft {
                        var activated = board
                        activated.status = .active
                        activated.updatedAt = now
                        activated.version += 1
                        try activated.save(db)
                        try makeSyncItem(entityType: "boards", entityId: activated.id,
                                         operationType: .update, payload: activated, now: now).save(db)
                    }

                    // 2. Persist the updated board task.
                    try updatedBoardTask.save(db)
                    try makeSyncItem(entityType: "boardTasks", entityId: updatedBoardTask.id,
                                     operationType: .update, payload: updatedBoardTask, now: now).save(db)

                    // 3. Reload all board tasks to build the completion grid.
                    let allBoardTasks = try BoardTask
                        .filter(Column("boardId") == board.id)
                        .fetchAll(db)

                    // 4. Build flat boolean grid (row-major).
                    var grid = [Bool](repeating: false, count: size * size)
                    for bt in allBoardTasks {
                        let idx = bt.row * size + bt.col
                        guard idx >= 0, idx < grid.count else { continue }
                        grid[idx] = bt.isCompleted
                    }

                    // Handle FREE/CUSTOM_FREE center auto-completion (no BoardTask at center)
                    if size % 2 == 1 {
                        let centerIdx = size * size / 2
                        let hasCenterTask = allBoardTasks.contains { $0.row == size / 2 && $0.col == size / 2 }
                        if !hasCenterTask && (board.centerSquareType == .free || board.centerSquareType == .customFree) {
                            grid[centerIdx] = true
                        }
                    }

                    // 5. Detect bingos.
                    let result = BingoDetection.detectBingos(completionGrid: grid, gridSize: size)

                    // Diff for new and lost lines.
                    let newLineIds = Set(result.completedLines)
                    let brandNewLines = newLineIds.subtracting(previousLineIds)
                    let lostBingos = previousLineIds.filter { !newLineIds.contains($0) }

                    // Count all completed BoardTasks + add FREE center if auto-completed (no BoardTask).
                    var completedCount = allBoardTasks.filter { $0.isCompleted }.count
                    let totalCount = size * size
                    if size % 2 == 1 {
                        let hasCenterTask = allBoardTasks.contains { $0.row == size / 2 && $0.col == size / 2 }
                        if !hasCenterTask && (board.centerSquareType == .free || board.centerSquareType == .customFree) {
                            completedCount += 1
                        }
                    }

                    // 6. Update board stats.
                    var updatedBoard: Board
                    if let fresh = try Board.fetchOne(db, key: board.id) {
                        updatedBoard = fresh
                    } else {
                        updatedBoard = board
                    }
                    updatedBoard.completedTasks = completedCount
                    updatedBoard.totalTasks = totalCount
                    updatedBoard.linesCompleted = result.completedLines.count
                    updatedBoard.completedLineIds = result.completedLines.isEmpty ? nil : result.completedLines
                    updatedBoard.updatedAt = now
                    updatedBoard.version += 1

                    // 7. Auto-complete board on greenlog; revert COMPLETED → ACTIVE when no longer greenlog.
                    var boardWasReactivated = false
                    if result.isGreenlog, updatedBoard.status == .active {
                        updatedBoard.status = .completed
                        updatedBoard.completedAt = now
                    } else if !result.isGreenlog, updatedBoard.status == .completed {
                        updatedBoard.status = .active
                        updatedBoard.completedAt = nil
                        boardWasReactivated = true
                    }

                    // Determine flash message: reactivated > lostBingos > greenlog > newBingos.
                    if boardWasReactivated {
                        newBingoMsg = "Board reactivated — no longer complete"
                    } else if !lostBingos.isEmpty {
                        newBingoMsg = "Bingo lost: \(lostBingos.sorted().joined(separator: ", "))"
                    } else if result.isGreenlog {
                        newBingoMsg = "GREENLOG!"
                    } else if !brandNewLines.isEmpty {
                        newBingoMsg = "Bingo! (\(brandNewLines.sorted().joined(separator: ", ")))"
                    }

                    try updatedBoard.save(db)
                    try makeSyncItem(entityType: "boards", entityId: updatedBoard.id,
                                     operationType: .update, payload: updatedBoard, now: now).save(db)
                }

                // 8. Refresh UI state on main thread.
                DispatchQueue.main.async {
                    isProcessing = false
                    loadBoards()
                    if let boardId = selectedBoardId {
                        loadBoardTasks(boardId: boardId)
                    }
                    if let msg = newBingoMsg {
                        bingoMessage = msg
                        DispatchQueue.main.asyncAfter(deadline: .now() + successDismissSeconds) {
                            bingoMessage = nil
                        }
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    isProcessing = false
                    errorMessage = "Failed to update task: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Demo Board Creation

    /// Creates a fully populated 3×3 demo board with a FREE center and 8 tasks.
    ///
    /// Uses a canonical task mix: counting, progress (with linked steps),
    /// and normal tasks. The board starts in DRAFT status and
    /// auto-activates on first interaction.
    private func createDemoBoard() {
        isCreatingDemo = true

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let now = AppDatabase.currentTimestamp()
                let boardId = AppDatabase.generateUUID()

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

                let existingCount = try AppDatabase.shared.fetchBoards(userId: playgroundUserId).count
                let boardName = "Demo Board \(existingCount + 1)"

                // Board starts in DRAFT status — transitions to ACTIVE on first interaction.
                // Use local ISO format for calendar-bound dates (startDate/endDate)
                let localFormatter = DateFormatter()
                localFormatter.locale = Locale(identifier: "en_US_POSIX")
                localFormatter.timeZone = TimeZone.current
                localFormatter.dateFormat = "yyyy-MM-dd'T'HH:mm:ss.SSS"
                let startDate = Date()
                let localStart = localFormatter.string(from: startDate)
                let cal = Calendar.current
                let targetEndDate = cal.date(byAdding: .day, value: 30, to: startDate)!
                let endOfTargetDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: targetEndDate))!.addingTimeInterval(-0.001)
                let localEnd = localFormatter.string(from: endOfTargetDay)

                let boardDict: [String: Any] = [
                    "id": boardId,
                    "userId": playgroundUserId,
                    "name": boardName,
                    "status": "draft",
                    "boardSize": 3,
                    "timeframe": "custom",
                    "startDate": localStart,
                    "endDate": localEnd,
                    "centerSquareType": "free",
                    "isRandomized": true,
                    "totalTasks": 9,
                    "completedTasks": 0,
                    "linesCompleted": 0,
                    "createdAt": now,
                    "updatedAt": now,
                    "version": 1,
                    "isDeleted": false
                ]
                let boardData = try! JSONSerialization.data(withJSONObject: boardDict) // swiftlint:disable:this force_try
                let board = try! JSONDecoder().decode(Board.self, from: boardData) // swiftlint:disable:this force_try

                try AppDatabase.shared.write { db in
                    try board.save(db)
                    try makeSyncItem(entityType: "boards", entityId: board.id,
                                     operationType: .create, payload: board, now: now).save(db)

                    for task in allDemoTasks {
                        try task.save(db)
                        try makeSyncItem(entityType: "tasks", entityId: task.id,
                                         operationType: .create, payload: task, now: now).save(db)
                    }
                    for stepTask in workoutStepTasks + cleanStepTasks {
                        try stepTask.save(db)
                        try makeSyncItem(entityType: "tasks", entityId: stepTask.id,
                                         operationType: .create, payload: stepTask, now: now).save(db)
                    }
                    for step in workoutSteps + cleanSteps {
                        try step.save(db)
                        try makeSyncItem(entityType: "taskSteps", entityId: step.id,
                                         operationType: .create, payload: step, now: now).save(db)
                    }

                    // Place a FREE center square at (1,1).
                    let centerTaskId = AppDatabase.generateUUID()
                    let freeTask = Task(
                        id: centerTaskId, userId: playgroundUserId,
                        title: "FREE", type: .normal,
                        totalCompletions: 0, totalInstances: 0,
                        createdAt: now, updatedAt: now, version: 1, isDeleted: false
                    )
                    try freeTask.save(db)
                    try makeSyncItem(entityType: "tasks", entityId: freeTask.id,
                                     operationType: .create, payload: freeTask, now: now).save(db)
                    let centerBt = BoardTask.makePlayground(
                        boardId: boardId, taskId: centerTaskId,
                        row: 1, col: 1, now: now, isCenter: true
                    )
                    try centerBt.save(db)
                    try makeSyncItem(entityType: "boardTasks", entityId: centerBt.id,
                                     operationType: .create, payload: centerBt, now: now).save(db)

                    // Fill remaining 8 positions with shuffled tasks.
                    var taskIndex = 0
                    for row in 0..<3 {
                        for col in 0..<3 {
                            let isCenter = row == 1 && col == 1
                            if isCenter { continue }
                            guard taskIndex < shuffled.count else { break }
                            let bt = BoardTask.makePlayground(
                                boardId: boardId, taskId: shuffled[taskIndex].id,
                                row: row, col: col, now: now
                            )
                            try bt.save(db)
                            try makeSyncItem(entityType: "boardTasks", entityId: bt.id,
                                             operationType: .create, payload: bt, now: now).save(db)
                            taskIndex += 1
                        }
                    }
                }

                DispatchQueue.main.async {
                    isCreatingDemo = false
                    loadBoards()
                    // Auto-select the new board after boards have loaded.
                    DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
                        selectedBoardId = boardId
                        loadBoardTasks(boardId: boardId)
                        loadTaskSteps()
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    isCreatingDemo = false
                    errorMessage = "Failed to create demo board: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Board Reset

    /// Resets all BoardTask completion state for the selected board back to zero.
    ///
    /// Clears `isCompleted`, `completedAt`, `currentCount`, and `completedStepIds` for
    /// every non-center square, then resets board stats and status to active.
    private func resetSelectedBoard() {
        guard let board = selectedBoard, !isProcessing else { return }
        isProcessing = true
        let now = AppDatabase.currentTimestamp()

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try AppDatabase.shared.write { db in
                    let allBts = try BoardTask
                        .filter(Column("boardId") == board.id)
                        .fetchAll(db)

                    for bt in allBts {
                        if bt.isCenter { continue }
                        var reset = bt
                        reset.isCompleted = false
                        reset.completedAt = nil
                        reset.currentCount = nil
                        reset.completedStepIds = []
                        reset.updatedAt = now
                        reset.version += 1
                        try reset.save(db)
                        try makeSyncItem(entityType: "boardTasks", entityId: reset.id,
                                         operationType: .update, payload: reset, now: now).save(db)
                    }

                    var resetBoard = board
                    resetBoard.completedTasks = 0
                    resetBoard.linesCompleted = 0
                    resetBoard.completedLineIds = nil
                    resetBoard.completedAt = nil
                    resetBoard.status = .active
                    resetBoard.updatedAt = now
                    resetBoard.version += 1
                    try resetBoard.save(db)
                    try makeSyncItem(entityType: "boards", entityId: resetBoard.id,
                                     operationType: .update, payload: resetBoard, now: now).save(db)
                }
                DispatchQueue.main.async {
                    isProcessing = false
                    bingoMessage = nil
                    loadBoards()
                    if let boardId = selectedBoardId {
                        loadBoardTasks(boardId: boardId)
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    isProcessing = false
                    errorMessage = "Reset failed: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Selection

    /// Selects a board for play and loads its tasks and steps.
    ///
    /// Activates the board immediately if it is still in DRAFT status, matching
    /// the web behaviour where selection implies the player is ready to play.
    /// Also clears any open detail sheet so stale state from a previous board
    /// does not bleed through.
    ///
    /// - Parameter board: The board to select.
    private func selectBoard(_ board: Board) {
        guard board.id != selectedBoardId else { return }
        selectedBoardId = board.id
        bingoMessage = nil
        detailBoardTaskId = nil
        loadBoardTasks(boardId: board.id)
        loadTaskSteps()

        guard board.status == .draft else { return }
        let now = AppDatabase.currentTimestamp()
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                try AppDatabase.shared.write { db in
                    var activated = board
                    activated.status = .active
                    activated.updatedAt = now
                    activated.version += 1
                    try activated.save(db)
                    try makeSyncItem(entityType: "boards", entityId: activated.id,
                                     operationType: .update, payload: activated, now: now).save(db)
                }
                DispatchQueue.main.async {
                    loadBoards()
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = "Failed to activate board: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Data Loading

    /// Loads all non-deleted boards for the playground user.
    private func loadBoards() {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let loaded = try AppDatabase.shared.fetchBoards(userId: playgroundUserId)
                DispatchQueue.main.async {
                    boards = loaded
                    // Keep selected board in sync if it was just updated.
                    if let selectedId = selectedBoardId,
                       !loaded.contains(where: { $0.id == selectedId }) {
                        selectedBoardId = nil
                    }
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = "Failed to load boards: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Loads all BoardTask records for a specific board, then resolves their Tasks.
    ///
    /// - Parameter boardId: The board whose tasks should be loaded.
    private func loadBoardTasks(boardId: String) {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let bts = try AppDatabase.shared.fetchBoardTasks(boardId: boardId)
                let taskIds = Array(Set(bts.compactMap { $0.taskId as String? }))
                let loadedTasks: [Task] = try AppDatabase.shared.read { db in
                    try Task
                        .filter(taskIds.contains(Column("id")))
                        .fetchAll(db)
                }
                DispatchQueue.main.async {
                    boardTasks = bts
                    tasks = loadedTasks
                }
            } catch {
                DispatchQueue.main.async {
                    errorMessage = "Failed to load board tasks: \(error.localizedDescription)"
                }
            }
        }
    }

    /// Loads all TaskStep records for progress tasks on the current board.
    private func loadTaskSteps() {
        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let loaded = try AppDatabase.shared.fetchAllTaskSteps(userId: playgroundUserId)
                DispatchQueue.main.async {
                    taskSteps = loaded
                }
            } catch {
                // Non-fatal — progress detail will show "No steps found"
            }
        }
    }
}
