import SwiftUI
import GRDB

// MARK: - Sync Queue Helpers (private to this file)

/// Encodes a `Codable` value to a JSON string for storage in the sync queue payload.
///
/// - Parameter value: The value to encode.
/// - Returns: A JSON string, or an empty JSON object string `"{}"` on failure.
private func bpvEncodeSyncPayload<T: Codable>(_ value: T) -> String {
    guard
        let data = try? JSONEncoder().encode(value),
        let string = String(data: data, encoding: .utf8)
    else { return "{}" }
    return string
}

/// Builds a `SyncQueueItem` for a local write that should be synced to Firestore.
///
/// - Parameters:
///   - entityType: The Firestore collection name (e.g. `"boards"`, `"boardTasks"`).
///   - entityId: The primary key of the entity.
///   - operationType: `.create`, `.update`, or `.delete`.
///   - payload: A `Codable` value whose JSON representation is stored as the payload.
///   - now: The current ISO8601 timestamp.
/// - Returns: A new `SyncQueueItem` with `status = .pending`.
private func bpvMakeSyncItem<T: Codable>(
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
        payload: bpvEncodeSyncPayload(payload),
        status: .pending,
        retryCount: 0,
        lastError: nil,
        createdAt: now,
        lastAttemptAt: nil,
        completedAt: nil,
        priority: 1
    )
}

// MARK: - BoardPlayView

/// Full interactive bingo board play screen.
///
/// Displays the board's task grid with per-type tap handlers (normal toggle, counting
/// increment/decrement, progress step sheet). After every tap the full orchestration
/// pipeline runs: board auto-activation, bingo detection, stat updates, and GREENLOG
/// auto-completion. A transient flash banner surfaces bingo and GREENLOG events.
/// Expired boards are locked (taps ignored). A stats bar shows task progress and bingo count.
///
/// - Parameter boardId: Primary key of the board to display.
struct BoardPlayView: View {

    // MARK: - Parameters

    let boardId: String
    @EnvironmentObject var authService: AuthService

    // MARK: - State

    @State private var board: Board?
    @State private var boardTasks: [BoardTask] = []
    @State private var allTasks: [Task] = []
    @State private var allTaskSteps: [TaskStep] = []

    @State private var isProcessing = false
    @State private var bingoMessage: String?
    @State private var detailBoardTaskId: String?

    // MARK: - Computed

    /// O(1) task lookup by task ID.
    private var taskMap: [String: Task] {
        Dictionary(uniqueKeysWithValues: allTasks.map { ($0.id, $0) })
    }

    /// Board tasks sorted row-major (ascending row then col).
    private var sortedBoardTasks: [BoardTask] {
        boardTasks.sorted { $0.row == $1.row ? $0.col < $1.col : $0.row < $1.row }
    }

    /// Grid column count from the board's `boardSize`, defaulting to 3.
    private var gridSize: Int {
        board?.boardSize ?? 3
    }

    /// Position lookup for fast grid rendering: "row-col" → BoardTask.
    private var btByPosition: [String: BoardTask] {
        var map: [String: BoardTask] = [:]
        for bt in boardTasks {
            map["\(bt.row)-\(bt.col)"] = bt
        }
        return map
    }

    /// Whether the current board has passed its `endDate` (non-Custom timeframe only).
    private var isBoardLocked: Bool {
        guard let b = board else { return false }
        return isBoardExpired(b)
    }

    // MARK: - Body

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 16) {

                // ── Flash message banner ──
                if let msg = bingoMessage {
                    Text(msg)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(
                            msg == "GREENLOG!"
                                ? Color.green.opacity(0.2)
                                : Color.accentColor.opacity(0.15)
                        )
                        .foregroundColor(msg == "GREENLOG!" ? .green : .accentColor)
                        .cornerRadius(8)
                        .padding(.horizontal)
                }

                // ── Stats bar ──
                if let b = board {
                    statsBar(board: b)
                        .padding(.horizontal)
                }

                // ── Grid ──
                if board != nil {
                    gridSection
                        .padding(.horizontal)
                }

                // ── Expiry banner ──
                if isBoardLocked, let b = board {
                    let expiredDate = DateFormatting.displayDate(from: b.endDate)
                    Text("Board expired on \(expiredDate) — interactions disabled")
                        .font(.subheadline)
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(Color.red.opacity(0.12))
                        .foregroundColor(.red)
                        .cornerRadius(8)
                        .padding(.horizontal)
                }
            }
            .padding(.vertical)
        }
        .navigationTitle(board?.name ?? "Board")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            loadBoard()
            loadBoardTasks()
            loadTaskData()
        }
        .sheet(isPresented: Binding(
            get: { detailBoardTaskId != nil },
            set: { if !$0 { detailBoardTaskId = nil } }
        )) {
            detailSheet
        }
    }

    // MARK: - Stats Bar

    /// Horizontal stats row: progress fraction, bingo line count, status badge.
    ///
    /// - Parameter board: The current board record.
    @ViewBuilder
    private func statsBar(board: Board) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("\(board.completedTasks)/\(board.totalTasks) tasks · \(board.linesCompleted) \(board.linesCompleted == 1 ? "bingo" : "bingos")")
                        .font(.caption)
                        .foregroundColor(.secondary)

                    // Expiry label
                    let expiry = getExpiryLabel(board)
                    Text(expiry)
                        .font(.caption2)
                        .foregroundColor(isBoardExpired(board) ? .red : .secondary)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                BoardStatusBadgeView(status: board.status)
            }

            ProgressView(
                value: board.totalTasks > 0
                    ? Double(board.completedTasks) / Double(board.totalTasks)
                    : 0
            )
            .tint(
                board.completedTasks == board.totalTasks && board.totalTasks > 0
                    ? .green
                    : .accentColor
            )
        }
    }

    // MARK: - Grid Section

    @ViewBuilder
    private var gridSection: some View {
        let columns = Array(repeating: GridItem(.fixed(90), spacing: 8), count: gridSize)

        // Centre the grid horizontally on wide screens.
        HStack {
            Spacer(minLength: 0)
            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(0..<(gridSize * gridSize), id: \.self) { index in
                    let row = index / gridSize
                    let col = index % gridSize
                    let isCenter = gridSize % 2 == 1
                        && row == gridSize / 2
                        && col == gridSize / 2

                    if let bt = btByPosition["\(row)-\(col)"] {
                        playSquare(boardTask: bt)
                    } else if isCenter,
                              let b = board,
                              (b.centerSquareType == .free || b.centerSquareType == .customFree) {
                        // FREE center — always completed, non-interactive.
                        InteractiveTaskSquareView(
                            title: "FREE",
                            taskType: .normal,
                            isCompleted: true,
                            isReadOnly: true
                        )
                    } else {
                        // Empty placeholder to preserve grid alignment
                        Color.clear
                            .frame(width: 90, height: 90)
                    }
                }
            }
            Spacer(minLength: 0)
        }
    }

    /// Renders a tappable `InteractiveTaskSquareView` cell for a non-center board task.
    ///
    /// - Normal: tap toggles completion; context menu for explicit mark/unmark + details.
    /// - Counting: tap increments +1; context menu for +/- and details.
    /// - Progress: tap opens the step detail sheet; context menu for complete-all / reset.
    ///
    /// All taps are no-ops while `isBoardLocked` or `isProcessing` is true.
    ///
    /// - Parameter boardTask: The `BoardTask` to render.
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
                    guard !isBoardLocked else { return }
                    handleNormalTap(boardTask: boardTask)
                }
            )
            .contextMenu {
                Button(
                    isCompleted ? "Mark Incomplete" : "Mark Complete",
                    systemImage: isCompleted ? "xmark.circle" : "checkmark.circle"
                ) {
                    guard !isBoardLocked else { return }
                    handleNormalTap(boardTask: boardTask)
                }
                .disabled(isProcessing || isBoardLocked)

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
                    guard !isBoardLocked else { return }
                    if let t = task { handleCountingTap(boardTask: boardTask, task: t) }
                }
            )
            .contextMenu {
                if let t = task {
                    Button("+ Add \(actionLabel)", systemImage: "plus") {
                        guard !isBoardLocked else { return }
                        handleCountingTap(boardTask: boardTask, task: t)
                    }
                    .disabled(current >= maxVal || isProcessing || isBoardLocked)

                    Button("- Remove \(actionLabel)", systemImage: "minus") {
                        guard !isBoardLocked else { return }
                        handleCountingDecrement(boardTask: boardTask, task: t)
                    }
                    .disabled(current == 0 || isProcessing || isBoardLocked)

                    Button("View Details", systemImage: "info.circle") {
                        detailBoardTaskId = boardTask.id
                    }
                }
            }

        case .progress:
            let completedStepsCount = boardTask.completedStepIds?.count ?? 0
            let stepsForTask = allTaskSteps.filter { $0.taskId == boardTask.taskId }
            let totalSteps = stepsForTask.isEmpty ? 1 : stepsForTask.count

            ZStack {
                InteractiveTaskSquareView(
                    title: task?.title ?? "Unknown",
                    taskType: .progress,
                    isCompleted: isCompleted,
                    completedSteps: completedStepsCount,
                    totalSteps: totalSteps
                )
                // Transparent overlay captures taps — InteractiveTaskSquareView
                // blocks its own onTap for .progress type.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard !isBoardLocked else { return }
                        detailBoardTaskId = boardTask.id
                    }
            }
            .frame(width: 90, height: 90)
            .contextMenu {
                Button("View Steps", systemImage: "list.bullet") {
                    detailBoardTaskId = boardTask.id
                }
                Button("Mark All Complete", systemImage: "checkmark.circle.fill") {
                    guard !isBoardLocked else { return }
                    handleProgressCompleteAll(boardTask: boardTask)
                }
                .disabled(isCompleted || isProcessing || isBoardLocked)

                Button("Mark Incomplete", systemImage: "xmark.circle") {
                    guard !isBoardLocked else { return }
                    handleProgressReset(boardTask: boardTask)
                }
                .disabled(!isCompleted || isProcessing || isBoardLocked)
            }
        }
    }

    // MARK: - Detail Sheet

    /// Modal sheet for viewing and toggling task details (steps for progress, counter for counting).
    @ViewBuilder
    private var detailSheet: some View {
        if let btId = detailBoardTaskId,
           let bt = boardTasks.first(where: { $0.id == btId }),
           let task = taskMap[bt.taskId] {
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

    /// Human-readable label for a task type shown in the detail sheet header.
    ///
    /// - Parameter type: The `TaskType` to describe.
    /// - Returns: A short description string.
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
            .disabled(isProcessing || isBoardLocked)
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
                .disabled(current == 0 || isProcessing || isBoardLocked)
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
                .disabled(current >= maxVal || isProcessing || isBoardLocked)
                .buttonStyle(.borderless)
            }
            .padding(.vertical, 4)
        }
    }

    @ViewBuilder
    private func progressDetailContent(boardTask: BoardTask, task: Task) -> some View {
        let completedIds = boardTask.completedStepIds ?? []
        let stepsForTask = allTaskSteps.filter { $0.taskId == task.id }

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
                    .disabled(isProcessing || isBoardLocked)
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

    // MARK: - Tap Handlers

    /// Toggles completion of a normal task square and runs the full bingo orchestration.
    ///
    /// - Parameter boardTask: The tapped `BoardTask`.
    private func handleNormalTap(boardTask: BoardTask) {
        guard !isProcessing else { return }
        let now = AppDatabase.currentTimestamp()
        let newCompleted = !boardTask.isCompleted

        var updated = boardTask
        updated.isCompleted = newCompleted
        updated.completedAt = newCompleted ? now : nil
        updated.updatedAt = now
        updated.version += 1

        runOrchestration(updatedBoardTask: updated)
    }

    /// Increments a counting task's `currentCount` by 1, marking complete at `maxCount`.
    ///
    /// - Parameters:
    ///   - boardTask: The counting task's `BoardTask` record.
    ///   - task: The `Task` providing `maxCount`.
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

    /// Decrements a counting task's `currentCount` by 1 and un-marks completion.
    ///
    /// - Parameters:
    ///   - boardTask: The counting task's `BoardTask` record.
    ///   - task: The `Task` providing metadata (kept for symmetry with increment handler).
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

    /// Toggles a single progress step for a board task and recomputes task completion.
    ///
    /// - Parameters:
    ///   - boardTask: The progress task's `BoardTask` record.
    ///   - step: The `TaskStep` being toggled.
    ///   - isDone: Current state of the step (`true` = already complete, will be un-checked).
    private func handleProgressStepTap(boardTask: BoardTask, step: TaskStep, isDone: Bool) {
        guard !isProcessing else { return }
        let now = AppDatabase.currentTimestamp()

        var currentIds = boardTask.completedStepIds ?? []
        if isDone {
            currentIds.removeAll(where: { $0 == step.id })
        } else {
            currentIds.append(step.id)
        }

        let stepsForTask = allTaskSteps.filter { $0.taskId == boardTask.taskId }
        let nowCompleted = !stepsForTask.isEmpty && currentIds.count >= stepsForTask.count

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
    /// - Parameter boardTask: The progress task's `BoardTask` record.
    private func handleProgressCompleteAll(boardTask: BoardTask) {
        guard !isProcessing else { return }
        let now = AppDatabase.currentTimestamp()
        let stepsForTask = allTaskSteps.filter { $0.taskId == boardTask.taskId }
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
    /// - Parameter boardTask: The progress task's `BoardTask` record.
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

    /// Runs the full task-completion orchestration in a single DB write transaction.
    ///
    /// Steps:
    /// 1. Auto-activates a DRAFT board on first interaction.
    /// 2. Persists the updated `BoardTask` and queues a sync entry.
    /// 3. Reloads all `BoardTask` records and builds the row-major completion grid.
    /// 4. Calls `BingoDetection.detectBingos` to find completed lines.
    /// 5. Diffs new vs previous `completedLineIds` to find gained and lost bingos.
    /// 6. Updates board stats: `completedTasks`, `linesCompleted`, `completedLineIds`, `updatedAt`, `version`.
    /// 7. Auto-completes the board on GREENLOG; reverts COMPLETED → ACTIVE when no longer GREENLOG.
    /// 8. Queues board sync entry, then refreshes UI state on the main thread.
    ///
    /// Uses `_Concurrency.Task` to avoid shadowing by the GRDB `Task` model.
    ///
    /// - Parameter updatedBoardTask: The already-mutated `BoardTask` to persist.
    private func runOrchestration(updatedBoardTask: BoardTask) {
        guard let board = board else { return }
        isProcessing = true
        let now = AppDatabase.currentTimestamp()
        let previousLineIds = Set(board.completedLineIds ?? [])
        let size = board.boardSize

        _Concurrency.Task.detached(priority: .userInitiated) {
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
                        // No separate sync item here — the final board save below
                        // includes the activated status and avoids redundant queue entries.
                    }

                    // 2. Persist the updated board task.
                    try updatedBoardTask.save(db)
                    try bpvMakeSyncItem(
                        entityType: "boardTasks",
                        entityId: updatedBoardTask.id,
                        operationType: .update,
                        payload: updatedBoardTask,
                        now: now
                    ).save(db)

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

                    // 6. Update board stats, refreshing from DB to avoid stale reads.
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

                    // 7. Auto-complete on GREENLOG; revert when no longer complete.
                    var boardWasReactivated = false
                    if result.isGreenlog, updatedBoard.status == .active {
                        updatedBoard.status = .completed
                        updatedBoard.completedAt = now
                    } else if !result.isGreenlog, updatedBoard.status == .completed {
                        updatedBoard.status = .active
                        updatedBoard.completedAt = nil
                        boardWasReactivated = true
                    }

                    // Determine flash message priority:
                    // reactivated > lostBingos > greenlog > newBingos.
                    if boardWasReactivated {
                        newBingoMsg = "Board reactivated — no longer complete"
                    } else if !lostBingos.isEmpty {
                        newBingoMsg = "Bingo lost: \(lostBingos.sorted().joined(separator: ", "))"
                    } else if result.isGreenlog {
                        newBingoMsg = "GREENLOG!"
                    } else if !brandNewLines.isEmpty {
                        newBingoMsg = "Bingo! (\(brandNewLines.sorted().joined(separator: ", ")))"
                    }

                    // 8. Persist board and queue sync.
                    try updatedBoard.save(db)
                    try bpvMakeSyncItem(
                        entityType: "boards",
                        entityId: updatedBoard.id,
                        operationType: .update,
                        payload: updatedBoard,
                        now: now
                    ).save(db)
                }

                // Refresh UI on main thread.
                await MainActor.run {
                    isProcessing = false
                    loadBoard()
                    loadBoardTasks()
                    if let msg = newBingoMsg {
                        bingoMessage = msg
                        let dismissAfter: Double = 3.0
                        _Concurrency.Task.detached { @MainActor in
                            try? await _Concurrency.Task.sleep(nanoseconds: UInt64(dismissAfter * 1_000_000_000))
                            // Only dismiss if this is still the same message
                            if bingoMessage == msg {
                                bingoMessage = nil
                            }
                        }
                    }
                }
            } catch {
                print("⚠️ BoardPlayView orchestration error: \(error)")
                await MainActor.run {
                    isProcessing = false
                    bingoMessage = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Data Loading

    /// Reloads the board record from GRDB and updates `board` on the main thread.
    private func loadBoard() {
        _Concurrency.Task.detached(priority: .userInitiated) {
            let fetched = try? AppDatabase.shared.fetchBoard(id: boardId)
            await MainActor.run { board = fetched }
        }
    }

    /// Reloads all board tasks for the current board from GRDB.
    private func loadBoardTasks() {
        _Concurrency.Task.detached(priority: .userInitiated) {
            let fetched = (try? AppDatabase.shared.fetchBoardTasks(boardId: boardId)) ?? []
            await MainActor.run { boardTasks = fetched }
        }
    }

    /// Loads all tasks and task steps for the authenticated user into memory.
    ///
    /// Task steps are fetched for the authenticated user if available, otherwise skipped.
    private func loadTaskData() {
        let userId = authService.currentUser?.id
        _Concurrency.Task.detached(priority: .userInitiated) {
            let tasks = userId.flatMap { id in
                try? AppDatabase.shared.fetchTasks(userId: id)
            } ?? []
            let steps = userId.flatMap { id in
                try? AppDatabase.shared.fetchAllTaskSteps(userId: id)
            } ?? []
            await MainActor.run {
                allTasks = tasks
                allTaskSteps = steps
            }
        }
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        BoardPlayView(boardId: "example-board-id-123")
            .environmentObject(AuthService())
    }
}
