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

/// Per-board outcome of `bpvRunCrossBoardCascade`. Caller uses this to surface
/// flash messages for the currently-visible board.
struct BPVCascadeBoardResult {
    let update: DerivationPass.BoardStatsUpdate
    /// True if this board transitioned COMPLETED → ACTIVE because it is no
    /// longer GREENLOG.
    let wasReactivated: Bool
    /// True if every cell on this board is now complete.
    let isGreenlogNow: Bool
    /// True if `board.status` was bumped to `.completed` by this cascade pass.
    let didAutoComplete: Bool
}

/// Run the cross-board derivation cascade for a Task that just changed locally.
///
/// For every board affected by `changedTaskId` (directly or via a compound
/// containing it transitively), this:
///   1. Rebuilds bingo state via `DerivationPass.computeBoardStatsUpdate`
///      — which respects compound evaluation + achievement-square overrides.
///   2. Auto-completes the board on GREENLOG; reverts COMPLETED → ACTIVE when
///      no longer GREENLOG.
///   3. Persists the updated `Board` row (bumping `updatedAt` + `version`).
///   4. Enqueues a `boards` sync entry for Firestore.
///
/// Mirrors `SyncService.runPullCascade` but additionally applies the GREENLOG
/// status transitions that local interactions own. Caller controls the
/// transaction via the passed `db` handle.
///
/// - Parameters:
///   - db: GRDB database handle (must be inside a write transaction).
///   - changedTaskId: The id of the Task whose state just changed.
///   - now: ISO8601 timestamp to stamp on every updated board row.
/// - Returns: A `[boardId: BPVCascadeBoardResult]` map. Boards excluded by
///   `isDeleted` are omitted.
private func bpvRunCrossBoardCascade(
    db: Database,
    changedTaskId: String,
    now: String
) throws -> [String: BPVCascadeBoardResult] {
    let allChildren: [CompoundChild] = try CompoundChild
        .filter(Column("isDeleted") == false)
        .fetchAll(db)
    let allBoardTasks: [BoardTask] = try BoardTask.fetchAll(db)
    let allTasks: [Task] = try Task.fetchAll(db)
    // Phase 6.3 — DerivationPass.computeBoardStatsUpdate needs the
    // workspace's boards to evaluate the specific-board / recurring-
    // template achievement branches. Pre-6.3 calls omitted this and
    // the algorithm defaults to []; on this cascade path we already
    // have the data fetched, so use it.
    let allBoards: [Board] = try Board.fetchAll(db)

    var taskById: [String: Task] = [:]
    for t in allTasks { taskById[t.id] = t }
    var childrenByCompound: [String: [CompoundChild]] = [:]
    for c in allChildren {
        childrenByCompound[c.compoundTaskId, default: []].append(c)
    }

    let parentCompounds = DerivationPass.findTransitiveParentCompounds(
        changedTaskId: changedTaskId,
        children: allChildren
    )
    let affectedBoardIds = DerivationPass.findAffectedBoardIds(
        changedTaskId: changedTaskId,
        parentCompounds: parentCompounds,
        boardTasks: allBoardTasks
    )

    var results: [String: BPVCascadeBoardResult] = [:]
    for boardId in affectedBoardIds {
        guard var board = try Board.fetchOne(db, key: boardId), !board.isDeleted else { continue }
        let boardTasksOnBoard = allBoardTasks.filter { $0.boardId == boardId }
        let update = DerivationPass.computeBoardStatsUpdate(
            board: board,
            boardTasksOnBoard: boardTasksOnBoard,
            childrenByCompound: childrenByCompound,
            taskById: taskById,
            allBoards: allBoards
        )

        let totalSquares = board.boardSize * board.boardSize
        let isGreenlogNow = update.completedTasks >= totalSquares
        var wasReactivated = false
        var didAutoComplete = false

        board.completedTasks = update.completedTasks
        board.totalTasks = totalSquares
        board.linesCompleted = update.linesCompleted
        board.completedLineIds = update.completedLineIds.isEmpty ? nil : update.completedLineIds
        board.updatedAt = now
        board.version += 1

        if isGreenlogNow, board.status == .active {
            board.status = .completed
            board.completedAt = now
            didAutoComplete = true
        } else if !isGreenlogNow, board.status == .completed {
            board.status = .active
            board.completedAt = nil
            wasReactivated = true
        }

        try board.save(db)
        try bpvMakeSyncItem(
            entityType: "boards",
            entityId: boardId,
            operationType: .update,
            payload: board,
            now: now
        ).save(db)

        results[boardId] = BPVCascadeBoardResult(
            update: update,
            wasReactivated: wasReactivated,
            isGreenlogNow: isGreenlogNow,
            didAutoComplete: didAutoComplete
        )
    }
    return results
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
    @State private var allCompoundChildren: [CompoundChild] = []
    // Phase 6.3 — workspace-wide boards + templates feed both the
    // achievement-square config sheet (for the pickers) and the per-
    // cell badge data computation. Refreshed alongside `loadTaskData`
    // so the sheet always sees up-to-date data when opened.
    @State private var allBoardsInWorkspace: [Board] = []
    @State private var allTemplatesInWorkspace: [RecurringBoardTemplate] = []
    @State private var allBoardTasksInWorkspace: [BoardTask] = []

    @State private var isProcessing = false
    @State private var bingoMessage: String?
    @State private var detailBoardTaskId: String?

    // MARK: - Computed

    /// O(1) task lookup by task ID.
    private var taskMap: [String: Task] {
        Dictionary(uniqueKeysWithValues: allTasks.map { ($0.id, $0) })
    }

    /// Compound children grouped by parent compound task ID, sorted by childIndex.
    private var compoundChildrenByCompound: [String: [CompoundChild]] {
        var grouped: [String: [CompoundChild]] = [:]
        for c in allCompoundChildren {
            grouped[c.compoundTaskId, default: []].append(c)
        }
        for id in grouped.keys {
            grouped[id]?.sort { $0.childIndex < $1.childIndex }
        }
        return grouped
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

    // MARK: - Phase 6.3: per-cell achievement-task badge data

    /// Compute the achievement-task badge for one BoardTask. nil if the
    /// backing Task is not ACHIEVEMENT-typed. Mirrors the TS-side
    /// `achievementBadgesByBoardTaskId` memo in BoardPlayPage.tsx.
    private func achievementBadge(for bt: BoardTask) -> AchievementSquareBadgeData? {
        guard let task = taskMap[bt.taskId], task.type == .achievement else { return nil }
        guard let parent = board else { return nil }
        let trigger = task.achievementTrigger ?? .greenlog
        let meets: (Board) -> Bool = { b in
            switch trigger {
            case .bingo:
                return (b.linesCompleted ?? 0) > 0
            case .greenlog:
                return b.status == .completed
            }
        }
        // Precedence: referencedBoardId wins when both somehow get set.
        // Mirrors derivationPass's bad-data rule.
        if let refBoardId = task.referencedBoardId {
            let ref = allBoardsInWorkspace.first(where: { $0.id == refBoardId && !$0.isDeleted })
            return AchievementSquareBadgeData(
                mode: .specificBoard,
                referencedBoardName: ref?.name,
                referencedBoardCompleted: ref.map(meets) ?? false
            )
        }
        if let refTemplateId = task.referencedTemplateId {
            let template = allTemplatesInWorkspace.first(where: { $0.id == refTemplateId })
            let spawns = allBoardsInWorkspace.filter { b in
                !b.isDeleted
                    && b.spawnedFromTemplateId == refTemplateId
                    && b.startDate >= parent.startDate
                    && b.startDate <= parent.endDate
            }
            let metCount = spawns.filter(meets).count
            return AchievementSquareBadgeData(
                mode: .recurringTemplate,
                templateName: template?.name,
                templateInWindowMet: metCount,
                templateRequiredCount: task.requiredCount ?? 0
            )
        }
        // No reference set: no badge (cell renders as regular task).
        return nil
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
        // Completion state lives on Task (not BoardTask) after compound-tasks unification.
        // Compounds: NEVER read Task.isCompleted (spec §4.1 — NEVER WRITTEN, NEVER READ on
        // compound rows). Derive completion via CompoundEvaluation so the green-complete
        // background + checkmark render correctly when all children are done.
        // Primitives: read the stored column directly.
        let isCompleted: Bool = {
            guard let task = task else { return false }
            if task.type == .compound {
                return CompoundEvaluation.evaluate(
                    compound: task,
                    childrenByCompound: compoundChildrenByCompound,
                    taskById: taskMap
                )
            }
            if task.type == .achievement {
                // ACHIEVEMENT cells derive completion from cross-board
                // references — mirror DerivationPass's logic locally
                // so the cell's tint + checkmark match the persisted
                // board.completedTasks count without a round-trip.
                return achievementCellIsCompleted(for: task)
            }
            return task.isCompleted
        }()

        let badge = achievementBadge(for: boardTask)

        switch taskType {
        case .normal:
            InteractiveTaskSquareView(
                title: task?.title ?? "Unknown",
                taskType: .normal,
                isCompleted: isCompleted,
                onTap: {
                    guard !isBoardLocked else { return }
                    handleNormalTap(boardTask: boardTask)
                },
                achievementBadge: badge
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
            // currentCount lives on Task after compound-tasks unification.
            let current = task?.currentCount ?? 0
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
                },
                achievementBadge: badge
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

        case .compound:
            let compoundLinks = task.map { compoundChildrenByCompound[$0.id] ?? [] } ?? []
            let compoundChildCount = compoundLinks.count
            let compoundDoneCount = compoundLinks.filter { link in
                guard let childTask = taskMap[link.childTaskId], !childTask.isDeleted else { return false }
                if childTask.type == .compound {
                    return CompoundEvaluation.evaluate(
                        compound: childTask,
                        childrenByCompound: compoundChildrenByCompound,
                        taskById: taskMap
                    )
                }
                return childTask.isCompleted
            }.count

            ZStack {
                InteractiveTaskSquareView(
                    title: task?.title ?? "Unknown",
                    taskType: .compound,
                    isCompleted: isCompleted,
                    compoundOperator: task?.operatorType,
                    compoundThreshold: task?.threshold,
                    compoundChildCount: compoundChildCount,
                    compoundDoneCount: compoundDoneCount,
                    onTap: {
                        guard !isBoardLocked else { return }
                        detailBoardTaskId = boardTask.id
                    },
                    achievementBadge: badge
                )
                // Transparent overlay ensures compound taps always open the detail sheet,
                // matching the progress-square pattern.
                Color.clear
                    .contentShape(Rectangle())
                    .onTapGesture {
                        guard !isBoardLocked else { return }
                        detailBoardTaskId = boardTask.id
                    }
            }
            .frame(width: 90, height: 90)
            .contextMenu {
                Button("View Children", systemImage: "list.bullet") {
                    detailBoardTaskId = boardTask.id
                }
            }

        case .achievement:
            // Phase 6.3 — ACHIEVEMENT cells are non-interactive: their
            // completion is derived from cross-board references. Render
            // like a NORMAL cell with no tap action; the badge labels
            // what the cell is watching.
            InteractiveTaskSquareView(
                title: task?.title ?? "Unknown",
                taskType: .normal,
                isCompleted: isCompleted,
                isReadOnly: true,
                achievementBadge: badge
            )
            .contextMenu {
                Button("View Details", systemImage: "info.circle") {
                    detailBoardTaskId = boardTask.id
                }
            }
        }
    }

    // MARK: - Phase 6.3: ACHIEVEMENT cell completion (local mirror of DerivationPass)

    /// Local mirror of DerivationPass's ACHIEVEMENT branch for per-cell
    /// rendering. The persisted `board.completedTasks` count already
    /// reflects this (derivation writes it on every Task cascade), but
    /// per-cell green-tinting reads from this helper so the UI doesn't
    /// have to round-trip through DerivationPass on every render.
    private func achievementCellIsCompleted(for task: Task) -> Bool {
        guard let parent = board else { return false }
        let trigger = task.achievementTrigger ?? .greenlog
        let meets: (Board) -> Bool = { b in
            switch trigger {
            case .bingo:
                return (b.linesCompleted ?? 0) > 0
            case .greenlog:
                return b.status == .completed
            }
        }
        if let refBoardId = task.referencedBoardId {
            guard let ref = allBoardsInWorkspace.first(where: { $0.id == refBoardId && !$0.isDeleted }) else {
                return false
            }
            return meets(ref)
        }
        if let refTemplateId = task.referencedTemplateId {
            let spawns = allBoardsInWorkspace.filter { b in
                !b.isDeleted
                    && b.spawnedFromTemplateId == refTemplateId
                    && b.startDate >= parent.startDate
                    && b.startDate <= parent.endDate
            }
            if spawns.isEmpty { return false }
            let metCount = spawns.filter(meets).count
            let required = task.requiredCount ?? 0
            return required > 0 && metCount >= required
        }
        return false
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
                    case .compound:
                        compoundDetailContent(boardTask: bt, task: task)
                    case .achievement:
                        achievementDetailContent(task: task)
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
        case .normal:      return "Normal task"
        case .counting:    return "Counting task"
        case .compound:    return "Compound task"
        case .achievement: return "Achievement task"
        }
    }

    @ViewBuilder
    private func normalDetailContent(boardTask: BoardTask) -> some View {
        let isCompleted = taskMap[boardTask.taskId]?.isCompleted ?? false
        Section("Completion") {
            Button {
                handleNormalTap(boardTask: boardTask)
                detailBoardTaskId = nil
            } label: {
                Label(
                    isCompleted ? "Mark Incomplete" : "Mark Complete",
                    systemImage: isCompleted ? "xmark.circle" : "checkmark.circle"
                )
                .foregroundColor(isCompleted ? .red : .green)
            }
            .disabled(isProcessing || isBoardLocked)
        }
    }

    @ViewBuilder
    private func countingDetailContent(boardTask: BoardTask, task: Task) -> some View {
        // currentCount lives on Task after compound-tasks unification.
        let current = task.currentCount ?? 0
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

    /// Detail sheet content for a compound task: shows each child with its current
    /// completion state and a tap handler that toggles the child's `Task.isCompleted`.
    ///
    /// - Parameters:
    ///   - boardTask: The parent compound's `BoardTask` placement record.
    ///   - task: The parent compound `Task`.
    @ViewBuilder
    private func compoundDetailContent(boardTask: BoardTask, task: Task) -> some View {
        let links = (compoundChildrenByCompound[task.id] ?? [])

        Section("Children") {
            if links.isEmpty {
                Text("No children found")
                    .foregroundColor(.secondary)
            } else {
                ForEach(links, id: \.id) { link in
                    let childTask = taskMap[link.childTaskId]
                    let isDone: Bool = {
                        guard let ct = childTask, !ct.isDeleted else { return false }
                        if ct.type == .compound {
                            return CompoundEvaluation.evaluate(
                                compound: ct,
                                childrenByCompound: compoundChildrenByCompound,
                                taskById: taskMap
                            )
                        }
                        return ct.isCompleted
                    }()

                    Button {
                        guard let ct = childTask, !isBoardLocked, !isProcessing else { return }
                        handleCompoundChildToggle(childTask: ct)
                    } label: {
                        HStack {
                            Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                                .foregroundColor(isDone ? .green : .secondary)
                            Text(childTask?.title ?? link.childTaskId)
                                .foregroundColor(.primary)
                            Spacer()
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(isProcessing || isBoardLocked || childTask == nil)
                }
            }
        }

        Section {
            Text("Completion applies to all boards where this task appears.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    /// Phase 6.3 — detail content for an ACHIEVEMENT-typed Task.
    /// Surfaces the cross-board target's current state so the user can
    /// understand why the cell is (or isn't) complete.
    @ViewBuilder
    private func achievementDetailContent(task: Task) -> some View {
        if let refBoardId = task.referencedBoardId {
            let ref = allBoardsInWorkspace.first(where: { $0.id == refBoardId })
            Section("Watching board") {
                if let ref {
                    HStack {
                        Image(systemName: ref.status == .completed ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(ref.status == .completed ? .green : .secondary)
                        Text(ref.name)
                            .foregroundColor(.primary)
                        Spacer()
                    }
                } else {
                    Text("(referenced board unavailable)")
                        .foregroundColor(.secondary)
                }
            }
        } else if let refTemplateId = task.referencedTemplateId {
            let template = allTemplatesInWorkspace.first(where: { $0.id == refTemplateId })
            let parent = board
            let spawns: [Board] = {
                guard let parent else { return [] }
                return allBoardsInWorkspace.filter { b in
                    !b.isDeleted
                        && b.spawnedFromTemplateId == refTemplateId
                        && b.startDate >= parent.startDate
                        && b.startDate <= parent.endDate
                }
            }()
            let completed = spawns.filter { $0.status == .completed }.count
            Section("Watching template") {
                HStack {
                    Image(systemName: "rectangle.stack")
                        .foregroundColor(.secondary)
                    Text(template?.name ?? "(referenced template unavailable)")
                        .foregroundColor(.primary)
                    Spacer()
                    Text("\(completed) / \(spawns.count)")
                        .foregroundColor(.secondary)
                        .font(.subheadline.monospacedDigit())
                }
            }
        } else {
            Section {
                Text("This achievement task has no reference set.")
                    .foregroundColor(.secondary)
            }
        }
        Section {
            Text("Completion is derived from the referenced board (or template's in-window spawns). The cell cannot be toggled directly.")
                .font(.caption)
                .foregroundColor(.secondary)
        }
    }

    // MARK: - Tap Handlers
    //
    // After compound-tasks unification, completion state lives on Task (not BoardTask).
    // Each handler mutates the Task record and passes it to runOrchestration alongside
    // the BoardTask (used only to update its updatedAt/version placement metadata).

    /// Toggles completion of a normal task square and runs the full bingo orchestration.
    ///
    /// - Parameter boardTask: The tapped `BoardTask`.
    private func handleNormalTap(boardTask: BoardTask) {
        guard !isProcessing, var task = taskMap[boardTask.taskId] else { return }
        let now = AppDatabase.currentTimestamp()
        let newCompleted = !task.isCompleted

        task.isCompleted = newCompleted
        task.completedAt = newCompleted ? now : nil
        task.updatedAt = now
        task.version += 1

        runOrchestration(updatedTask: task, boardTask: boardTask)
    }

    /// Increments a counting task's `currentCount` by 1, marking complete at `maxCount`.
    ///
    /// - Parameters:
    ///   - boardTask: The counting task's `BoardTask` record.
    ///   - task: The `Task` providing `maxCount`.
    private func handleCountingTap(boardTask: BoardTask, task: Task) {
        guard !isProcessing, !task.isCompleted, let maxCount = task.maxCount else { return }
        let now = AppDatabase.currentTimestamp()
        let newCount = min((task.currentCount ?? 0) + 1, maxCount)
        let nowCompleted = newCount >= maxCount

        var updatedTask = task
        updatedTask.currentCount = newCount
        updatedTask.isCompleted = nowCompleted
        updatedTask.completedAt = nowCompleted ? now : nil
        updatedTask.updatedAt = now
        updatedTask.version += 1

        runOrchestration(updatedTask: updatedTask, boardTask: boardTask)
    }

    /// Decrements a counting task's `currentCount` by 1 and un-marks completion.
    ///
    /// - Parameters:
    ///   - boardTask: The counting task's `BoardTask` record.
    ///   - task: The `Task` providing current state.
    private func handleCountingDecrement(boardTask: BoardTask, task: Task) {
        guard !isProcessing else { return }
        let now = AppDatabase.currentTimestamp()
        let newCount = max((task.currentCount ?? 0) - 1, 0)

        var updatedTask = task
        updatedTask.currentCount = newCount
        updatedTask.isCompleted = false
        updatedTask.completedAt = nil
        updatedTask.updatedAt = now
        updatedTask.version += 1

        runOrchestration(updatedTask: updatedTask, boardTask: boardTask)
    }

    /// Toggles a compound child's `Task.isCompleted` state.
    ///
    /// If the child is placed on the current board, orchestrates via the full bingo pipeline.
    /// If the child is not on any board, falls back to a direct Task update + sync enqueue.
    ///
    /// - Parameter childTask: The child `Task` to toggle.
    private func handleCompoundChildToggle(childTask: Task) {
        guard !isProcessing else { return }
        let now = AppDatabase.currentTimestamp()
        var updatedChild = childTask
        let newCompleted = !childTask.isCompleted
        updatedChild.isCompleted = newCompleted
        updatedChild.completedAt = newCompleted ? now : nil
        updatedChild.updatedAt = now
        updatedChild.version += 1

        // If the child has a BoardTask on the current board, use the full orchestration
        // pipeline so bingo detection stays consistent.
        if let childBt = boardTasks.first(where: { $0.taskId == childTask.id }) {
            runOrchestration(updatedTask: updatedChild, boardTask: childBt)
            return
        }

        // Fallback: child is not placed on this board, but a parent compound
        // (or the child via another board) may be — so we still need the
        // cross-board cascade to recompute every affected board's bingo state
        // and propagate the change to UI on this board (its compound square
        // derives via CompoundEvaluation, not Task.isCompleted).
        isProcessing = true
        let currentBoardId = board?.id
        _Concurrency.Task.detached(priority: .userInitiated) {
            do {
                var newBingoMsg: String? = nil
                try AppDatabase.shared.write { db in
                    try updatedChild.save(db)
                    try bpvMakeSyncItem(
                        entityType: "tasks",
                        entityId: updatedChild.id,
                        operationType: .update,
                        payload: updatedChild,
                        now: now
                    ).save(db)

                    let cascadeResults = try bpvRunCrossBoardCascade(
                        db: db,
                        changedTaskId: updatedChild.id,
                        now: now
                    )
                    if let cid = currentBoardId, let result = cascadeResults[cid] {
                        let lost = result.update.lostBingos.sorted()
                        let gained = result.update.newBingos.sorted()
                        if result.wasReactivated {
                            newBingoMsg = "Board reactivated — no longer complete"
                        } else if !lost.isEmpty {
                            newBingoMsg = "Bingo lost: \(lost.joined(separator: ", "))"
                        } else if result.isGreenlogNow {
                            newBingoMsg = "GREENLOG!"
                        } else if !gained.isEmpty {
                            newBingoMsg = "Bingo! (\(gained.joined(separator: ", ")))"
                        }
                    }
                }
                await MainActor.run {
                    isProcessing = false
                    loadBoard()
                    loadBoardTasks()
                    loadTaskData()
                    if let msg = newBingoMsg {
                        bingoMessage = msg
                        let dismissAfter: Double = 3.0
                        _Concurrency.Task.detached { @MainActor in
                            try? await _Concurrency.Task.sleep(nanoseconds: UInt64(dismissAfter * 1_000_000_000))
                            if bingoMessage == msg {
                                bingoMessage = nil
                            }
                        }
                    }
                }
            } catch {
                print("⚠️ BoardPlayView compoundChildToggle error: \(error)")
                await MainActor.run {
                    isProcessing = false
                }
            }
        }
    }

    // MARK: - Orchestration

    /// Runs the full task-completion orchestration in a single DB write transaction.
    ///
    /// Steps:
    /// 1. Auto-activates a DRAFT board on first interaction.
    /// 2. Persists the updated `Task` (global completion state) and bumps the
    ///    `BoardTask` placement record's `updatedAt`/`version`. Both are queued
    ///    for sync.
    /// 3. Delegates to `bpvRunCrossBoardCascade` — which uses
    ///    `DerivationPass.computeBoardStatsUpdate` to rebuild bingo state for
    ///    every affected board (current board plus any other board placing this
    ///    task or a compound containing it). Cascade respects compound
    ///    evaluation + achievement-square overrides, applies GREENLOG → COMPLETED
    ///    auto-completion + COMPLETED → ACTIVE reactivation, persists each
    ///    affected board, and queues board sync entries.
    /// 4. Surfaces a flash message for the *current* board only (other affected
    ///    boards update silently — the user isn't looking at them).
    ///
    /// Uses `_Concurrency.Task` to avoid shadowing by the GRDB `Task` model.
    ///
    /// - Parameters:
    ///   - updatedTask: The already-mutated `Task` carrying new completion state.
    ///   - boardTask: The `BoardTask` placement record on the current board
    ///     (updatedAt/version will be bumped + sync-queued).
    private func runOrchestration(updatedTask: Task, boardTask: BoardTask) {
        guard let board = board else { return }
        isProcessing = true
        let now = AppDatabase.currentTimestamp()
        let currentBoardId = board.id

        _Concurrency.Task.detached(priority: .userInitiated) {
            do {
                var newBingoMsg: String? = nil

                try AppDatabase.shared.write { db in
                    // 1. Auto-activate DRAFT boards on first interaction. Cascade
                    //    will re-save the board with stats; this leg only flips
                    //    .draft → .active so cascade doesn't promote a draft to
                    //    .completed (which would be wrong for first-tap).
                    if board.status == .draft {
                        var activated = board
                        activated.status = .active
                        activated.updatedAt = now
                        activated.version += 1
                        try activated.save(db)
                    }

                    // 2a. Persist the updated Task (carries completion state).
                    try updatedTask.save(db)
                    try bpvMakeSyncItem(
                        entityType: "tasks",
                        entityId: updatedTask.id,
                        operationType: .update,
                        payload: updatedTask,
                        now: now
                    ).save(db)

                    // 2b. Bump the BoardTask placement record's updatedAt/version.
                    var updatedBoardTask = boardTask
                    updatedBoardTask.updatedAt = now
                    updatedBoardTask.version += 1
                    try updatedBoardTask.save(db)
                    try SyncQueueBuilder.makeItem(
                        entityType: "boardTasks",
                        entityId: updatedBoardTask.id,
                        operationType: .update,
                        payload: updatedBoardTask,
                        now: now
                    ).save(db)

                    // 3. Cross-board cascade: rebuilds bingo state via
                    //    DerivationPass.computeBoardStatsUpdate (which honours
                    //    compound evaluation + achievement squares), applies
                    //    GREENLOG transitions, and persists every affected board.
                    let cascadeResults = try bpvRunCrossBoardCascade(
                        db: db,
                        changedTaskId: updatedTask.id,
                        now: now
                    )

                    // 4. Surface a flash message for the *current* board only.
                    //    Other affected boards still updated stats — they just
                    //    don't get a transient banner since the user isn't on them.
                    if let result = cascadeResults[currentBoardId] {
                        let lost = result.update.lostBingos.sorted()
                        let gained = result.update.newBingos.sorted()
                        if result.wasReactivated {
                            newBingoMsg = "Board reactivated — no longer complete"
                        } else if !lost.isEmpty {
                            newBingoMsg = "Bingo lost: \(lost.joined(separator: ", "))"
                        } else if result.isGreenlogNow {
                            newBingoMsg = "GREENLOG!"
                        } else if !gained.isEmpty {
                            newBingoMsg = "Bingo! (\(gained.joined(separator: ", ")))"
                        }
                    }
                }

                // Refresh UI on main thread.
                await MainActor.run {
                    isProcessing = false
                    loadBoard()
                    loadBoardTasks()
                    // Also refresh allTasks + allCompoundChildren so the compound
                    // detail sheet (which renders from taskMap + compoundChildrenByCompound)
                    // reflects the latest child-toggle state immediately without needing a
                    // dismiss-and-reopen. Mirrors the Path-B (child-not-on-board) pattern.
                    loadTaskData()
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

    /// Loads all tasks and compound children for the authenticated user
    /// into memory. CompoundChildren are fetched globally (not user-scoped)
    /// since the AppDatabase helper doesn't filter by userId for that table.
    private func loadTaskData() {
        let userId = authService.currentUser?.id
        _Concurrency.Task.detached(priority: .userInitiated) {
            let tasks = userId.flatMap { id in
                try? AppDatabase.shared.fetchTasks(userId: id)
            } ?? []
            let children = (try? AppDatabase.shared.fetchAllCompoundChildren()) ?? []
            // Phase 6.3 — workspace-wide boards + templates + board_tasks
            // for the achievement-square config sheet (pickers) and the
            // per-cell badge data computation. Same fetch pattern as
            // tasks above — runs once per onAppear, refreshed alongside
            // the spawn-driver pass.
            let workspaceBoards = userId.flatMap { id in
                try? AppDatabase.shared.fetchBoards(userId: id)
            } ?? []
            let workspaceTemplates = userId.flatMap { id in
                try? AppDatabase.shared.fetchRecurringBoardTemplates(userId: id)
            } ?? []
            let workspaceBoardTasks = (try? AppDatabase.shared.fetchAllBoardTasks()) ?? []
            await MainActor.run {
                allTasks = tasks
                allCompoundChildren = children
                allBoardsInWorkspace = workspaceBoards
                allTemplatesInWorkspace = workspaceTemplates
                allBoardTasksInWorkspace = workspaceBoardTasks
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
