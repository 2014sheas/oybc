import SwiftUI
import GRDB

/// A reusable panel for creating a new board from a pre-assembled task pool.
///
/// Presents board configuration controls (size, center type, name, randomisation),
/// a task-count indicator, and a "Create Board" button. After creation a read-only
/// `InteractiveTaskSquareView` grid previews the resulting board layout.
///
/// - Parameters:
///   - boardPool: Ordered list of `(taskId, title, type)` tuples to assign to the board.
///   - libraryTasks: All regular `Task` records — used to resolve task metadata for the preview.
///   - allTaskSteps: All `TaskStep` records available for progress-fraction calculation in the preview.
///   - onBoardCreated: Optional callback invoked with the new board's ID after a successful save.
struct BoardCreatorPanelView: View {

    // MARK: - Parameters

    let boardPool: [(taskId: String, title: String, type: String)]
    let libraryTasks: [Task]
    var allTaskSteps: [TaskStep] = []
    var onBoardCreated: ((String) -> Void)? = nil

    // MARK: - State

    @State private var boardName: String = ""
    @State private var boardSize: Int = 3
    @State private var centerType: CenterSquareType = .free
    @State private var centerCustomName: String = ""
    @State private var centerTaskId: String? = nil
    @State private var isRandomized: Bool = true
    @State private var isCreating: Bool = false
    @State private var createdBoardId: String? = nil
    @State private var previewBoardTasks: [BoardTask] = []
    @State private var successMessage: String? = nil
    @State private var errorMessage: String? = nil

    // MARK: - Derived Properties

    /// Whether the current board size has a physical centre cell.
    private var isOddBoard: Bool { boardSize % 2 != 0 }

    /// Whether the board will reserve the centre cell for a non-task square.
    private var hasCenterSquare: Bool { isOddBoard && centerType != .none }

    /// Number of pool tasks that will be placed on the board.
    ///
    /// For CHOSEN center type the chosen task itself comes from the pool, so all
    /// boardSize² positions draw from the pool. For FREE / CUSTOM_FREE the centre
    /// cell is auto-filled and does not consume a pool task.
    private var tasksNeeded: Int {
        if isOddBoard && centerType == .chosen {
            return boardSize * boardSize
        }
        return boardSize * boardSize - (hasCenterSquare ? 1 : 0)
    }

    /// Whether the pool has enough tasks for the selected configuration.
    private var hasEnoughTasks: Bool { boardPool.count >= tasksNeeded }

    /// Human-readable label for the centre-square type picker.
    private func centerTypeLabel(_ ct: CenterSquareType) -> String {
        switch ct {
        case .free:        return "Free Space"
        case .customFree:  return "Custom Free"
        case .chosen:      return "Chosen Task"
        case .none:        return "None"
        }
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {

            Text("Create Board from Pool")
                .font(.headline)

            if createdBoardId != nil {
                // ── Success state: persistent banner + preview ──
                boardCreatedBanner
                if !previewBoardTasks.isEmpty {
                    Divider()
                    boardPreview
                }
            } else {
                // ── Configuration form ──

                // ── Board size ──
                VStack(alignment: .leading, spacing: 4) {
                    Text("Board Size")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                    Picker("Board Size", selection: $boardSize) {
                        Text("3×3").tag(3)
                        Text("4×4").tag(4)
                        Text("5×5").tag(5)
                    }
                    .pickerStyle(.segmented)
                    .onChange(of: boardSize) {
                        // Reset center type to .free for odd boards, .none for even
                        if boardSize % 2 == 0 {
                            centerType = .none
                        } else {
                            centerType = .free
                        }
                        resetOutcome()
                    }
                }

                // ── Center square type (odd sizes only) ──
                if isOddBoard {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Centre Square")
                            .font(.subheadline)
                            .fontWeight(.semibold)
                        Picker("Centre Square", selection: $centerType) {
                            ForEach([CenterSquareType.free, .customFree, .chosen, .none], id: \.self) { ct in
                                Text(centerTypeLabel(ct)).tag(ct)
                            }
                        }
                        .pickerStyle(.menu)
                        .onChange(of: centerType) { resetOutcome() }

                        if centerType == .customFree {
                            TextField("Custom name", text: $centerCustomName)
                                .textFieldStyle(.roundedBorder)
                        }

                        // ── Chosen center task selector ──
                        if centerType == .chosen {
                            VStack(alignment: .leading, spacing: 4) {
                                Text("Center Task")
                                    .font(.subheadline)
                                    .fontWeight(.semibold)
                                Picker("Center Task", selection: $centerTaskId) {
                                    Text("— Select a pool task —").tag(String?.none)
                                    ForEach(boardPool, id: \.taskId) { entry in
                                        Text("\(entry.title) (\(entry.type))").tag(String?.some(entry.taskId))
                                    }
                                }
                                .pickerStyle(.menu)
                            }
                        }
                    }
                }

                // ── Board name ──
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Board name (required)", text: $boardName)
                        .textFieldStyle(.roundedBorder)
                    Text("\(boardName.count)/200")
                        .font(.caption)
                        .foregroundColor(boardName.count > 200 ? .red : .secondary)
                }

                // ── Randomise toggle ──
                Toggle("Randomise task order", isOn: $isRandomized)
                    .font(.subheadline)
                    .onChange(of: isRandomized) { resetOutcome() }

                // ── Task-count indicator ──
                HStack(spacing: 6) {
                    Image(systemName: hasEnoughTasks ? "checkmark.circle.fill" : "exclamationmark.circle.fill")
                        .foregroundColor(hasEnoughTasks ? .green : .red)
                    Text("Pool has \(boardPool.count) task\(boardPool.count == 1 ? "" : "s") — need \(tasksNeeded)")
                        .font(.subheadline)
                        .foregroundColor(hasEnoughTasks ? .green : .red)
                }

                // ── Error feedback ──
                if let error = errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }

                // ── Create button ──
                Button(isCreating ? "Creating…" : "Create Board") {
                    createBoard()
                }
                .buttonStyle(.borderedProminent)
                .disabled(isCreating || !hasEnoughTasks)
            }
        }
    }

    // MARK: - Board Created Banner

    /// Persistent green banner shown after a successful board creation.
    /// Cleared only when the user taps "Create Another".
    @ViewBuilder
    private var boardCreatedBanner: some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundColor(.green)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Board Created!")
                    .font(.subheadline)
                    .fontWeight(.bold)
                    .foregroundColor(.green)
                if let message = successMessage {
                    Text(message)
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
            Spacer()
        }
        .padding(12)
        .background(Color.green.opacity(0.10))
        .overlay(
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.green.opacity(0.35), lineWidth: 1)
        )
        .cornerRadius(8)
    }

    // MARK: - Board Preview

    /// Read-only grid preview of the newly created board, with a "Create Another" button below.
    @ViewBuilder
    private var boardPreview: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Board Preview")
                .font(.subheadline)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)

            let size = boardSize
            let columns = Array(repeating: GridItem(.fixed(90), spacing: 8), count: size)
            let taskMap = previewTaskMap

            LazyVGrid(columns: columns, spacing: 8) {
                ForEach(0..<(size * size), id: \.self) { index in
                    let row = index / size
                    let col = index % size
                    let isCenterCell = row == size / 2 && col == size / 2 && size % 2 == 1

                    // For CHOSEN, the center cell has a real BoardTask — let it fall through
                    // to the previewSquare path below. Only render the static free cell for
                    // FREE and CUSTOM_FREE center types.
                    if isCenterCell && (centerType == .free || centerType == .customFree) {
                        centerSquarePreviewCell
                    } else if let bt = taskMap["\(row)-\(col)"] {
                        previewSquare(for: bt)
                    } else {
                        // Should not appear in normal use — placeholder
                        RoundedRectangle(cornerRadius: 8)
                            .fill(Color(.systemGray5))
                            .frame(width: 90, height: 90)
                    }
                }
            }

            Button("Create Another Board") {
                resetAll()
            }
            .buttonStyle(.bordered)
            .frame(maxWidth: .infinity)
            .padding(.top, 4)
        }
    }

    /// O(1) `"row-col"` → `BoardTask` lookup for the preview grid.
    private var previewTaskMap: [String: BoardTask] {
        Dictionary(uniqueKeysWithValues: previewBoardTasks.map { ("\($0.row)-\($0.col)", $0) })
    }

    /// Read-only square rendered for the centre free / customFree cell in the preview.
    /// Not called for `.chosen` (that centre cell has a real `BoardTask`).
    @ViewBuilder
    private var centerSquarePreviewCell: some View {
        let label: String = {
            switch centerType {
            case .free:             return "FREE"
            case .customFree:       return centerCustomName.isEmpty ? "FREE" : centerCustomName
            case .chosen, .none:    return "FREE"
            }
        }()
        ZStack {
            RoundedRectangle(cornerRadius: 8)
                .fill(Color.green.opacity(0.15))
            RoundedRectangle(cornerRadius: 8)
                .stroke(Color.green.opacity(0.4), lineWidth: 1.5)
            Text(label)
                .font(.system(size: 13, weight: .bold))
                .foregroundColor(.green)
        }
        .frame(width: 90, height: 90)
    }

    /// Renders a read-only `InteractiveTaskSquareView` for a single board task in the preview.
    ///
    /// - Parameter bt: The `BoardTask` record to render.
    @ViewBuilder
    private func previewSquare(for bt: BoardTask) -> some View {
        if let task = libraryTasks.first(where: { $0.id == bt.taskId }) {
            switch task.type {
            case .normal:
                InteractiveTaskSquareView(
                    title: task.title,
                    taskType: .normal,
                    isCompleted: bt.isCompleted,
                    isReadOnly: true
                )

            case .counting:
                InteractiveTaskSquareView(
                    title: task.title,
                    taskType: .counting,
                    isCompleted: bt.isCompleted,
                    currentCount: bt.currentCount ?? 0,
                    maxCount: task.maxCount ?? 0,
                    unit: task.unit ?? "",
                    isReadOnly: true
                )

            case .progress:
                let stepsForTask = allTaskSteps.filter { $0.taskId == task.id }
                let completedCount = bt.completedStepIds?.count ?? 0
                InteractiveTaskSquareView(
                    title: task.title,
                    taskType: .progress,
                    isCompleted: bt.isCompleted,
                    completedSteps: completedCount,
                    totalSteps: stepsForTask.count,
                    isReadOnly: true
                )
            }
        } else {
            // Composite or unknown — render as normal type
            let title = boardPool.first(where: { $0.taskId == bt.taskId })?.title ?? "Task"
            InteractiveTaskSquareView(
                title: title,
                taskType: .normal,
                isCompleted: false,
                isReadOnly: true
            )
        }
    }

    // MARK: - Create Board

    /// Validates the form, creates the Board and BoardTask records in a single transaction,
    /// then loads the preview data and invokes the callback.
    private func createBoard() {
        let trimmedName = boardName.trimmingCharacters(in: .whitespacesAndNewlines)

        guard !trimmedName.isEmpty else {
            errorMessage = "Board name is required"
            return
        }
        guard trimmedName.count <= 200 else {
            errorMessage = "Board name must be 200 characters or less"
            return
        }
        guard hasEnoughTasks else {
            errorMessage = "Not enough tasks in the pool (need \(tasksNeeded), have \(boardPool.count))"
            return
        }
        if isOddBoard && centerType == .chosen {
            guard centerTaskId != nil else {
                errorMessage = "Please select a task for the center square."
                return
            }
        }

        isCreating = true
        errorMessage = nil
        successMessage = nil

        let now = AppDatabase.currentTimestamp()
        let boardId = AppDatabase.generateUUID()
        let size = boardSize
        let capturedCenterTaskId = centerTaskId

        // For CHOSEN, exclude the center task from the grid pool so it isn't placed twice.
        let poolForGrid: [(taskId: String, title: String, type: String)] = {
            if isOddBoard && centerType == .chosen, let ctId = capturedCenterTaskId {
                return boardPool.filter { $0.taskId != ctId }
            }
            return boardPool
        }()

        // tasksNeeded for CHOSEN includes the center task, so the grid needs tasksNeeded - 1
        let gridTasksNeeded = (isOddBoard && centerType == .chosen) ? tasksNeeded - 1 : tasksNeeded

        // Select the pool tasks to place on non-center cells, shuffling if requested
        let selectedEntries: [(taskId: String, title: String, type: String)] = {
            let slice = Array(poolForGrid.prefix(gridTasksNeeded))
            return isRandomized ? Shuffle.fisherYatesShuffle(slice) : slice
        }()

        let centerSquareTypeString: String = centerType.rawValue
        let customCenterName: String? = centerType == .customFree
            ? centerCustomName.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                // Build Board — use the JSON-round-trip factory pattern, extending it for
                // variable boardSize and optional centerSquareCustomName.
                let boardDict: [String: Any] = {
                    var d: [String: Any] = [
                        "id": boardId,
                        "userId": playgroundUserId,
                        "name": trimmedName,
                        "status": "active",
                        "boardSize": size,
                        "timeframe": "weekly",
                        "startDate": now,
                        "endDate": now,
                        "centerSquareType": centerSquareTypeString,
                        "isRandomized": isRandomized,
                        "totalTasks": selectedEntries.count,
                        "completedTasks": 0,
                        "linesCompleted": 0,
                        "createdAt": now,
                        "updatedAt": now,
                        "version": 1,
                        "isDeleted": false
                    ]
                    if let name = customCenterName, !name.isEmpty {
                        d["centerSquareCustomName"] = name
                    }
                    return d
                }()
                let boardData = try JSONSerialization.data(withJSONObject: boardDict)
                let board = try JSONDecoder().decode(Board.self, from: boardData)

                let centerRow = size / 2
                let centerCol = size / 2
                var boardTasks: [BoardTask] = []

                // For CHOSEN center type, place the selected task at the center cell first.
                if size % 2 == 1 && centerType == .chosen, let ctId = capturedCenterTaskId {
                    let centerBt = BoardTask.makePlayground(
                        boardId: boardId,
                        taskId: ctId,
                        row: centerRow,
                        col: centerCol,
                        now: now,
                        isCenter: true
                    )
                    boardTasks.append(centerBt)
                }

                // Build BoardTask records for the remaining grid positions, skipping the
                // centre cell for odd boards with any non-none centre type.
                var poolIndex = 0

                for row in 0..<size {
                    for col in 0..<size {
                        let isCenterCell = row == centerRow && col == centerCol && size % 2 == 1
                        if isCenterCell && centerType != .none { continue }
                        guard poolIndex < selectedEntries.count else { break }

                        let entry = selectedEntries[poolIndex]
                        poolIndex += 1

                        let bt = BoardTask.makePlayground(
                            boardId: boardId,
                            taskId: entry.taskId,
                            row: row,
                            col: col,
                            now: now
                        )
                        boardTasks.append(bt)
                    }
                }

                try AppDatabase.shared.write { db in
                    try board.save(db)
                    for bt in boardTasks {
                        try bt.save(db)
                    }
                }

                // Load preview board tasks back from DB
                let savedBoardTasks = try AppDatabase.shared.fetchBoardTasks(boardId: boardId)
                let totalPlaced = boardTasks.count

                DispatchQueue.main.async {
                    isCreating = false
                    createdBoardId = boardId
                    previewBoardTasks = savedBoardTasks
                    // Persistent banner message — cleared only by "Create Another"
                    successMessage = "Created \"\(trimmedName)\" — \(totalPlaced) task\(totalPlaced == 1 ? "" : "s") placed."
                    onBoardCreated?(boardId)
                }
            } catch {
                DispatchQueue.main.async {
                    isCreating = false
                    errorMessage = "Failed to create board: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Helpers

    /// Clears the preview state when configuration controls change.
    private func resetOutcome() {
        createdBoardId = nil
        previewBoardTasks = []
        successMessage = nil
        errorMessage = nil
    }

    /// Resets the entire panel to its initial state for creating another board.
    private func resetAll() {
        boardName = ""
        boardSize = 3
        centerType = .free
        centerCustomName = ""
        centerTaskId = nil
        isRandomized = true
        isCreating = false
        createdBoardId = nil
        previewBoardTasks = []
        successMessage = nil
        errorMessage = nil
    }
}

// MARK: - Previews

#Preview("Sufficient pool") {
    ScrollView {
        BoardCreatorPanelView(
            boardPool: (1...9).map { (taskId: "task-\($0)", title: "Task \($0)", type: "normal") },
            libraryTasks: []
        )
        .padding()
    }
}

#Preview("Insufficient pool") {
    ScrollView {
        BoardCreatorPanelView(
            boardPool: [(taskId: "task-1", title: "Task 1", type: "normal")],
            libraryTasks: []
        )
        .padding()
    }
}

#Preview("Empty pool") {
    ScrollView {
        BoardCreatorPanelView(boardPool: [], libraryTasks: [])
            .padding()
    }
}
