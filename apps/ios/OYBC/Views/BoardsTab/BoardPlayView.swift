import SwiftUI
import UIKit
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

/// Applies BoardPlayView's navigation title only when not embedded.
/// SwiftUI can't conditionally apply a modifier inline without a branch,
/// so we wrap the title chrome here.
private struct BoardPlayTitleChrome: ViewModifier {
    let title: String
    let enabled: Bool
    func body(content: Content) -> some View {
        if enabled {
            // Riso play board owns its header in-content (back square + name +
            // status badge), so suppress the system nav title AND back button
            // to avoid duplicate back/name affordances. The Edit toolbar item
            // (defined separately) is unaffected.
            content
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarBackButtonHidden(true)
        } else {
            content
        }
    }
}

// MARK: - SwapTarget

/// Lightweight `Identifiable` wrapper used to drive the `.sheet(item:)` for
/// the M3 cell-swap picker. Carries the boardTask id + the current task id so
/// `CellSwapSheet` can exclude the current task from the eligible list.
private struct SwapTarget: Identifiable {
    /// The `BoardTask.id` whose cell is being swapped.
    let id: String
    /// The `Task.id` currently occupying the square (excluded from the picker).
    let currentTaskId: String
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
    /// Cross-tab navigation: when the user opens a Task detail sheet
    /// over this board and taps a different board in the Usage section,
    /// dismiss the sheet here and delegate the routing to MainTabView
    /// (which owns boardsPath). Defaults to a no-op so existing call
    /// sites compile while we plumb this from the top.
    var onOpenBoard: (String) -> Void = { _ in }
    /// When true the view omits its own navigation-title chrome so a host
    /// (the core-board window pager) can own the title/bar. Default false
    /// preserves the standalone /boards/:id-equivalent behavior.
    var embedded: Bool = false
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
    // MARK: Riso visual layer state
    /// Whether to show the GREENLOG full-bleed celebration overlay.
    @State private var showGreenlogOverlay: Bool = false
    /// Whether to show the bingo toast (drops from top).
    @State private var showBingoToast: Bool = false
    /// Subtitle for the current bingo toast (e.g. "Row 2 complete!").
    @State private var bingoToastSubtitle: String = ""
    /// Board task id of the counting cell whose stepper sheet is open.
    @State private var countingStepperBoardTaskId: String?
    @State private var detailBoardTaskId: String?
    /// Drives the task-detail library sheet (separate from the board-play detail sheet).
    @State private var taskDetailSheetTaskId: TaskIdItem?
    /// M2 — edit-board sheet (ACTIVE boards only).
    @State private var isEditBoardPresented: Bool = false
    /// M3 — live-edit cell swap: the square whose task the user wants to replace.
    @State private var swapTarget: SwapTarget? = nil
    /// M4 — live-edit remove from board: the boardTaskId pending confirmation.
    @State private var removeBoardTaskId: String? = nil
    /// M4 — live-edit add to empty cell: the grid position awaiting task selection.
    @State private var addCellPos: (row: Int, col: Int)? = nil
    /// M4 — tracks whether the add-cell sheet was dismissed via a confirmed selection.
    /// `onDismiss` skips the reload when true because `handleAddTaskToCell` already reloads.
    @State private var addTaskConfirmed: Bool = false
    /// Stashed target for cross-board navigation requested from inside
    /// the task-detail sheet. We can't mutate `boardsPath` while the
    /// sheet is dismissing — SwiftUI swallows the path change during
    /// the transition, leaving the user on the original board. Setting
    /// this stash + watching `taskDetailSheetTaskId` for nil-transition
    /// (see `.onChange` below) sequences dismiss-then-navigate
    /// correctly.
    @State private var pendingOpenBoardId: String?

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

    /// Set of 0-based cell indices (row * gridSize + col) that are part of a
    /// completed bingo line. Drives the gold-ring highlight on `RisoBoardPlayCell`.
    private var highlightedSquareIndices: Set<Int> {
        guard let lines = board?.completedLineIds, !lines.isEmpty else { return [] }
        return BingoDetection.getHighlightedSquares(completedLines: lines, gridSize: gridSize)
    }

    /// Kicker text derived from the board's timeframe (e.g. "WEEKLY BOARD").
    private var boardKicker: String {
        guard let b = board else { return "BOARD" }
        switch b.timeframe {
        case .daily:   return "DAILY BOARD"
        case .weekly:  return "WEEKLY BOARD"
        case .monthly: return "MONTHLY BOARD"
        case .yearly:  return "YEARLY BOARD"
        case .custom:  return "CUSTOM BOARD"
        }
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .top) {
            // ── Paper background ──
            RisoPaperBackground()
                .ignoresSafeArea()

            // ── Main scrollable content ──
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {

                    // ── In-content header ──
                    risoPlayHeader
                        .padding(.horizontal, Riso.gutter)
                        .padding(.top, 12)

                    // ── Stat bar ──
                    if let b = board {
                        RisoStatBar(
                            completedTasks: b.completedTasks,
                            totalTasks: b.totalTasks,
                            linesCompleted: b.linesCompleted,
                            expiryText: risoExpiryText(board: b)
                        )
                        .padding(.horizontal, Riso.gutter)
                        .padding(.top, 14)
                        .padding(.bottom, 13)
                    }

                    // ── Grid ──
                    if board != nil {
                        risoGridSection
                            .padding(.horizontal, Riso.gutter)
                    }

                    // ── Expired banner (below grid) ──
                    if isBoardLocked {
                        Text("Board expired — interactions disabled")
                            .font(.risoBody(12, .semibold))
                            .foregroundStyle(Color.risoRed)
                            .padding(.horizontal, Riso.gutter)
                            .padding(.top, 8)
                    }

                    Spacer(minLength: 20)
                }
            }

            // ── Bingo toast (drops from top) ──
            if showBingoToast {
                RisoBingoToast(
                    subtitle: bingoToastSubtitle,
                    bingoCount: board?.linesCompleted ?? 1
                )
                .padding(.horizontal, Riso.gutter)
                .padding(.top, 54)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    )
                )
                .zIndex(10)
            }

            // ── GREENLOG overlay (full-bleed) ──
            if showGreenlogOverlay, let b = board {
                RisoGreenlogOverlay(
                    completedTasks: b.completedTasks,
                    totalTasks: b.totalTasks,
                    linesCompleted: b.linesCompleted,
                    boardName: b.name,
                    onShare: {
                        // Share sheet stub — wire to ShareSheet when available
                    },
                    onDismiss: {
                        withAnimation(.easeOut(duration: 0.25)) {
                            showGreenlogOverlay = false
                        }
                    }
                )
                .ignoresSafeArea()
                .transition(.opacity)
                .zIndex(20)
            }

            // ── Counting stepper sheet ──
            // Presented as a sheet (see .sheet modifier below)
        }
        .modifier(BoardPlayTitleChrome(title: board?.name ?? "Board", enabled: !embedded))
        // M2 — toolbar "Edit" button (ACTIVE boards only; DRAFT uses the wizard;
        // COMPLETED / ARCHIVED boards are immutable).
        .toolbar {
            if let b = board, b.status == .active, !embedded {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Edit") {
                        isEditBoardPresented = true
                    }
                }
            }
        }
        .sheet(isPresented: $isEditBoardPresented, onDismiss: {
            // Reload the board record so the updated name / timeframe
            // are reflected immediately without a manual scroll or pull.
            loadBoard()
            loadBoardTasks()
            loadTaskData()
        }) {
            if let b = board {
                EditBoardSheet(
                    board: b,
                    weekStartDay: authService.currentUser?.decodedPreferences.weekStartDay.rawValue ?? "monday",
                    onSaved: {
                        isEditBoardPresented = false
                    }
                )
            }
        }
        // M3 — Cell swap sheet. Presented when the user taps "⎘ Swap with
        // another task…" in the context menu of a non-center ACTIVE square.
        .sheet(
            item: $swapTarget,
            onDismiss: {
                // Reload so the grid reflects any completed swap.
                loadBoardTasks()
                loadTaskData()
            }
        ) { target in
            CellSwapSheet(
                mode: .swap,
                currentTaskId: target.currentTaskId,
                candidateTasks: allTasks,
                onDismiss: { swapTarget = nil },
                onConfirm: { newTaskId in
                    swapTarget = nil
                    handleCellSwap(boardTaskId: target.id, newTaskId: newTaskId)
                }
            )
        }
        // M4 — Remove from board confirmation. Presented when the user taps
        // "⎘ Remove from board" in the context menu of a non-center ACTIVE square.
        .alert(
            "Remove from board?",
            isPresented: Binding(
                get: { removeBoardTaskId != nil },
                set: { if !$0 { removeBoardTaskId = nil } }
            ),
            actions: {
                Button("Cancel", role: .cancel) { removeBoardTaskId = nil }
                Button("Remove", role: .destructive) {
                    guard let targetId = removeBoardTaskId else { return }
                    removeBoardTaskId = nil
                    handleRemoveFromBoard(boardTaskId: targetId)
                }
            },
            message: {
                if let btId = removeBoardTaskId,
                   let bt = boardTasks.first(where: { $0.id == btId }),
                   let task = taskMap[bt.taskId] {
                    Text("\"\(task.title)\" will be removed from this board. The task stays in your library and on any other boards where it appears.")
                } else {
                    Text("This task will be removed from this board. The task stays in your library and on any other boards where it appears.")
                }
            }
        )
        // M4 — Add task to empty cell sheet. Presented when the user taps
        // the "+" affordance on an empty cell.
        .sheet(
            isPresented: Binding(
                get: { addCellPos != nil },
                set: { if !$0 { addCellPos = nil } }
            ),
            onDismiss: {
                // Skip reload on confirm: `handleAddTaskToCell` already calls
                // `loadBoardTasks` + `loadTaskData` after its DB write, so a
                // second reload here would flash pre-insert state. Only reload
                // on cancel (user dismissed without selecting a task).
                if addTaskConfirmed {
                    addTaskConfirmed = false
                } else {
                    loadBoardTasks()
                    loadTaskData()
                }
            }
        ) {
            if let pos = addCellPos {
                CellSwapSheet(
                    mode: .add,
                    currentTaskId: "",
                    candidateTasks: allTasks,
                    onDismiss: { addCellPos = nil },
                    onConfirm: { taskId in
                        addTaskConfirmed = true
                        addCellPos = nil
                        handleAddTaskToCell(taskId: taskId, row: pos.row, col: pos.col)
                    }
                )
            }
        }
        .onAppear {
            loadBoard()
            loadBoardTasks()
            loadTaskData()
        }
        // Defensive: also reload on boardId prop change. With `.id(boardId)`
        // on the destination, SwiftUI re-creates the view (and .onAppear
        // fires) — but if any future refactor strips the .id, this keeps
        // data fresh per boardId.
        .onChange(of: boardId) { _, _ in
            loadBoard()
            loadBoardTasks()
            loadTaskData()
        }
        // Counting stepper sheet — Riso pill stepper for counting cells.
        // Wires to handleCountingTap / handleCountingDecrement; dismiss clears state.
        .sheet(
            isPresented: Binding(
                get: { countingStepperBoardTaskId != nil },
                set: { if !$0 { countingStepperBoardTaskId = nil } }
            )
        ) {
            if let btId = countingStepperBoardTaskId,
               let bt = boardTasks.first(where: { $0.id == btId }),
               let task = taskMap[bt.taskId] {
                let rawCount = task.currentCount ?? 0
                let maxVal = task.maxCount ?? 0
                let isLinked = task.sharedCounterId != nil
                let displayed: Int = {
                    if let _ = task.sharedCounterId {
                        return deriveDisplayedCount(
                            derivedBaseline: task.baseline ?? 0,
                            derivedMaxCount: maxVal,
                            sourceCurrentCount: rawCount
                        ).displayed
                    }
                    return rawCount
                }()
                RisoCountingStepperSheet(
                    taskTitle: task.title,
                    currentCount: displayed,
                    maxCount: maxVal,
                    unitText: task.unit ?? "",
                    isLinkedCounter: isLinked,
                    onIncrement: {
                        handleCountingTap(boardTask: bt, task: task)
                    },
                    onDecrement: {
                        handleCountingDecrement(boardTask: bt, task: task)
                    },
                    onDismiss: {
                        countingStepperBoardTaskId = nil
                    }
                )
            }
        }
        .sheet(isPresented: Binding(
            get: { detailBoardTaskId != nil },
            set: { if !$0 { detailBoardTaskId = nil } }
        )) {
            detailSheet
        }
        // `onDismiss:` fires AFTER the sheet has visually unmounted, so
        // the subsequent boardsPath mutation (via onOpenBoard) lands in
        // a clean SwiftUI transaction. Using .onChange of the item here
        // would fire synchronously with the state mutation (before the
        // dismiss transition completes) and the path change would get
        // swallowed mid-transition — leaving the user on the original
        // board.
        .sheet(
            item: $taskDetailSheetTaskId,
            onDismiss: {
                if let target = pendingOpenBoardId {
                    pendingOpenBoardId = nil
                    onOpenBoard(target)
                }
            }
        ) { item in
            TaskDetailSheetView(
                taskId: item.id,
                onClose: { taskDetailSheetTaskId = nil },
                onOpenBoard: { newBoardId in
                    pendingOpenBoardId = newBoardId
                    taskDetailSheetTaskId = nil
                }
            )
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
            // Use the timestamp-based window helper rather than
            // lexicographic string compare — Board dates can be local-ISO
            // or UTC-with-`Z` and the two don't sort correctly as strings.
            let spawns = allBoardsInWorkspace.filter { b in
                !b.isDeleted
                    && b.spawnedFromTemplateId == refTemplateId
                    && DateFormatting.isWithinTimeframe(
                        b.startDate,
                        startDate: parent.startDate,
                        endDate: parent.endDate
                    )
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

    // MARK: - Riso Play Header

    /// In-content header: back button (non-embedded only) + kicker + board name + status badge.
    @ViewBuilder
    private var risoPlayHeader: some View {
        HStack(alignment: .top, spacing: 10) {
            // Back button — hidden when embedded (host owns navigation chrome)
            if !embedded {
                // SwiftUI's NavigationStack owns the back gesture; this button
                // is a visual affordance only. Calling dismiss via the environment
                // is the idiomatic way to pop without a NavigationLink.
                risoBackButton
            }

            // Kicker + board name
            VStack(alignment: .leading, spacing: 3) {
                Text(boardKicker)
                    .risoKicker()
                Text(board?.name ?? "")
                    .font(.risoHead(22, .extraBold))
                    .tracking(-0.44)
                    .foregroundStyle(Color.risoInk)
                    .lineLimit(2)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // Status badge
            if let b = board {
                risoStatusBadge(status: b.status)
                    .padding(.top, 4)
            }
        }
    }

    @ViewBuilder
    private var risoBackButton: some View {
        // We render a visual back square. The NavigationStack automatically
        // attaches swipe-back and adds a back button in the nav bar when
        // !embedded; this in-content square is supplemental UX.
        // Using the environment's dismiss action is the right hook.
        BackButton()
    }

    @ViewBuilder
    private func risoStatusBadge(status: BoardStatus) -> some View {
        let (label, fill, fore): (String, Color, Color) = {
            switch status {
            case .active:    return ("ACTIVE",    Color.risoBlue,  Color.risoPaper)
            case .completed: return ("COMPLETE",  Color.risoGreen, Color.risoPaper)
            case .draft:     return ("DRAFT",     Color.risoPaper2, Color.risoMuted)
            case .archived:  return ("ARCHIVED",  Color.risoPaper2, Color.risoMuted)
            }
        }()
        Text(label)
            .font(.risoHead(10, .bold))
            .foregroundStyle(fore)
            .padding(.horizontal, 9)
            .padding(.vertical, 4)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
    }

    /// Compact expiry string for the stat bar — "4d", "Expired", "Today", etc.
    private func risoExpiryText(board: Board) -> String {
        guard board.timeframe != .custom else { return "No end" }
        guard let end = parseISO8601Date(board.endDate) else { return "—" }
        let now = Date()
        guard now <= end else { return "Expired" }
        let secs = end.timeIntervalSince(now)
        if secs < 86_400 { return "Today" }
        let days = Int(ceil(secs / 86_400))
        return "\(days)d"
    }

    // MARK: - Riso Notification helpers

    /// Called on the Main thread after every orchestration / shared-counter run.
    /// Interprets the `bingoMessage` string set by the existing plumbing and
    /// triggers the appropriate Riso visual:
    ///   - "GREENLOG!" → full-bleed overlay (after ~520ms to let the cell pop land)
    ///   - "Bingo! …" → drop-in toast (~2.8s then auto-dismiss)
    ///   - other messages (reactivation, swap errors) → no Riso visual (bingoMessage
    ///     remains set for potential legacy readers, but we don't toast these)
    ///
    /// The method is idempotent — calling it with the same message while the toast
    /// is already showing is a no-op.
    private func triggerRisoNotification(from message: String) {
        if message == "GREENLOG!" {
            // Delay to let the 25th cell pop animation finish (~340ms + margin)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.52) {
                withAnimation(.easeIn(duration: 0.3)) {
                    showGreenlogOverlay = true
                }
            }
        } else if message.lowercased().contains("bingo") && !message.lowercased().contains("lost") {
            // Extract a short subtitle from the message
            // Original format: "Bingo! (row_1, col_2)" → "Line complete!"
            bingoToastSubtitle = "Line complete!"
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                showBingoToast = true
            }
            // Auto-dismiss after ~2.8s
            _Concurrency.Task.detached { @MainActor in
                try? await _Concurrency.Task.sleep(nanoseconds: 2_800_000_000)
                withAnimation(.easeOut(duration: 0.25)) {
                    showBingoToast = false
                }
            }
        }
    }

    // MARK: - Riso Grid Section

    @ViewBuilder
    private var risoGridSection: some View {
        let cols = Array(repeating: GridItem(.flexible(), spacing: Riso.cellGap), count: gridSize)
        let highlighted = highlightedSquareIndices

        LazyVGrid(columns: cols, spacing: Riso.cellGap) {
            ForEach(0..<(gridSize * gridSize), id: \.self) { index in
                let row = index / gridSize
                let col = index % gridSize
                let isCenter = gridSize % 2 == 1
                    && row == gridSize / 2
                    && col == gridSize / 2

                if let bt = btByPosition["\(row)-\(col)"] {
                    risoPlaySquare(boardTask: bt, index: index, highlighted: highlighted)
                } else if isCenter,
                          let b = board,
                          (b.centerSquareType == .free || b.centerSquareType == .customFree) {
                    // FREE center cell
                    RisoBoardPlayCell(
                        title: "FREE",
                        taskType: .normal,
                        isCompleted: false,
                        isBingoLine: highlighted.contains(index),
                        isCenter: true
                    )
                } else if !isCenter,
                          let b = board,
                          b.status == .active,
                          !isBoardLocked {
                    // M4 — Empty non-center cell on an ACTIVE board: dashed "+" affordance.
                    ZStack {
                        RoundedRectangle(cornerRadius: Riso.cellRadius)
                            .strokeBorder(
                                Color.risoInk.opacity(0.35),
                                style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                            )
                        Button {
                            addCellPos = (row: row, col: col)
                        } label: {
                            Image(systemName: "plus.circle")
                                .font(.system(size: 22, weight: .semibold))
                                .foregroundStyle(Color.risoMuted)
                        }
                        .buttonStyle(.plain)
                    }
                    .aspectRatio(1, contentMode: .fit)
                } else {
                    // Empty placeholder
                    Color.clear.aspectRatio(1, contentMode: .fit)
                }
            }
        }
        .padding(.bottom, 8)
    }

    // MARK: - Riso Play Square

    /// Renders one `RisoBoardPlayCell` for a placed BoardTask, wiring all tap
    /// handlers to the existing write/cascade/detection call sites.
    ///
    /// - Parameters:
    ///   - boardTask: The `BoardTask` placement record.
    ///   - index: 0-based grid index (row * gridSize + col) — used for bingo-line lookup.
    ///   - highlighted: Set of indices that are on a completed bingo line.
    @ViewBuilder
    private func risoPlaySquare(boardTask: BoardTask, index: Int, highlighted: Set<Int>) -> some View {
        let task = taskMap[boardTask.taskId]
        let taskType = task?.type ?? .normal
        // Completion derivation — preserved verbatim from original playSquare.
        // Compounds: NEVER read Task.isCompleted. Achievements: derive from
        // cross-board references. Primitives: read Task.isCompleted directly.
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
                return achievementCellIsCompleted(for: task)
            }
            return task.isCompleted
        }()

        // Counting display values — mirrors original playSquare.
        let rawCount = task?.currentCount ?? 0
        let maxVal = task?.maxCount ?? 0
        let isLinkedCounter = task?.sharedCounterId != nil
        let current: Int = {
            if let t = task, let _ = t.sharedCounterId {
                return deriveDisplayedCount(
                    derivedBaseline: t.baseline ?? 0,
                    derivedMaxCount: t.maxCount ?? 0,
                    sourceCurrentCount: rawCount
                ).displayed
            }
            return rawCount
        }()

        // Compound child progress — mirrors original playSquare.
        let compoundLinks = task.map { compoundChildrenByCompound[$0.id] ?? [] } ?? []
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

        let cellKind: CellTaskType = {
            switch taskType {
            case .normal:      return .normal
            case .counting:    return .counting
            case .compound:    return .compound
            case .achievement: return .achievement
            }
        }()

        RisoBoardPlayCell(
            title: task?.title ?? "Unknown",
            taskType: cellKind,
            isCompleted: isCompleted,
            isBingoLine: highlighted.contains(index),
            isCenter: boardTask.isCenter,
            isLocked: isBoardLocked,
            currentCount: current,
            maxCount: maxVal,
            compoundDoneCount: compoundDoneCount,
            compoundChildCount: compoundLinks.count,
            onTap: {
                guard !isBoardLocked, !isProcessing else { return }
                // Haptic feedback — fire immediately on tap (before async write lands)
                let generator = UIImpactFeedbackGenerator(style: .medium)
                generator.impactOccurred()
                switch taskType {
                case .normal:
                    handleNormalTap(boardTask: boardTask)
                case .counting:
                    // Tap → open counting stepper sheet
                    countingStepperBoardTaskId = boardTask.id
                case .compound:
                    detailBoardTaskId = boardTask.id
                case .achievement:
                    break // read-only
                }
            }
        )
        .contextMenu {
            risoContextMenu(boardTask: boardTask, task: task, isCompleted: isCompleted, taskType: taskType, current: current, maxVal: maxVal, isLinkedCounter: isLinkedCounter)
        }
    }

    /// Context menu items — preserved exactly from original `playSquare`, now
    /// extracted so they can be attached to `RisoBoardPlayCell`.
    @ViewBuilder
    private func risoContextMenu(
        boardTask: BoardTask,
        task: Task?,
        isCompleted: Bool,
        taskType: TaskType,
        current: Int,
        maxVal: Int,
        isLinkedCounter: Bool
    ) -> some View {
        switch taskType {
        case .normal:
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
            Button("Open in library", systemImage: "book") {
                taskDetailSheetTaskId = TaskIdItem(id: boardTask.taskId)
            }
            if board?.status == .active, !isBoardLocked, !boardTask.isCenter {
                Divider()
                Button("Swap with another task…", systemImage: "arrow.2.squarepath") {
                    swapTarget = SwapTarget(id: boardTask.id, currentTaskId: boardTask.taskId)
                }
                Button("Remove from board", systemImage: "minus.circle", role: .destructive) {
                    removeBoardTaskId = boardTask.id
                }
            }

        case .counting:
            if let t = task {
                let actionLabel = t.action ?? "item"
                Button("+ Add \(actionLabel)", systemImage: "plus") {
                    guard !isBoardLocked else { return }
                    handleCountingTap(boardTask: boardTask, task: t)
                }
                .disabled(current >= maxVal || isProcessing || isBoardLocked)
                Button("− Remove \(actionLabel)", systemImage: "minus") {
                    guard !isBoardLocked else { return }
                    handleCountingDecrement(boardTask: boardTask, task: t)
                }
                .disabled(current == 0 || isLinkedCounter || isProcessing || isBoardLocked)
                Button("View Details", systemImage: "info.circle") {
                    detailBoardTaskId = boardTask.id
                }
                Button("Open in library", systemImage: "book") {
                    taskDetailSheetTaskId = TaskIdItem(id: t.id)
                }
                if board?.status == .active, !isBoardLocked, !boardTask.isCenter {
                    Divider()
                    Button("Swap with another task…", systemImage: "arrow.2.squarepath") {
                        swapTarget = SwapTarget(id: boardTask.id, currentTaskId: boardTask.taskId)
                    }
                    Button("Remove from board", systemImage: "minus.circle", role: .destructive) {
                        removeBoardTaskId = boardTask.id
                    }
                }
            }

        case .compound:
            Button("View Children", systemImage: "list.bullet") {
                detailBoardTaskId = boardTask.id
            }
            Button("Open in library", systemImage: "book") {
                taskDetailSheetTaskId = TaskIdItem(id: boardTask.taskId)
            }
            if board?.status == .active, !isBoardLocked, !boardTask.isCenter {
                Divider()
                Button("Swap with another task…", systemImage: "arrow.2.squarepath") {
                    swapTarget = SwapTarget(id: boardTask.id, currentTaskId: boardTask.taskId)
                }
                Button("Remove from board", systemImage: "minus.circle", role: .destructive) {
                    removeBoardTaskId = boardTask.id
                }
            }

        case .achievement:
            Button("View Details", systemImage: "info.circle") {
                detailBoardTaskId = boardTask.id
            }
            Button("Open in library", systemImage: "book") {
                taskDetailSheetTaskId = TaskIdItem(id: boardTask.taskId)
            }
            if board?.status == .active, !isBoardLocked, !boardTask.isCenter {
                Divider()
                Button("Swap with another task…", systemImage: "arrow.2.squarepath") {
                    swapTarget = SwapTarget(id: boardTask.id, currentTaskId: boardTask.taskId)
                }
                Button("Remove from board", systemImage: "minus.circle", role: .destructive) {
                    removeBoardTaskId = boardTask.id
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
                    && DateFormatting.isWithinTimeframe(
                        b.startDate,
                        startDate: parent.startDate,
                        endDate: parent.endDate
                    )
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
        // For linked derived counters (sharedCounterId != nil), apply
        // deriveDisplayedCount so the detail sheet shows the baseline-adjusted
        // value rather than the raw source accumulator.
        let rawCount = task.currentCount ?? 0
        let maxVal = task.maxCount ?? 0
        let unitText = task.unit ?? ""
        let isLinkedCounter = task.sharedCounterId != nil
        let current: Int = {
            if let _ = task.sharedCounterId {
                return deriveDisplayedCount(
                    derivedBaseline: task.baseline ?? 0,
                    derivedMaxCount: maxVal,
                    sourceCurrentCount: rawCount
                ).displayed
            }
            return rawCount
        }()

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
                        .foregroundColor(current > 0 && !isLinkedCounter ? .orange : .secondary)
                }
                // Linked derived counters are read-only — decrement is disabled.
                .disabled(current == 0 || isLinkedCounter || isProcessing || isBoardLocked)
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

                    HStack {
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

                        // Info button — opens the child task's detail in the library sheet.
                        Button {
                            taskDetailSheetTaskId = TaskIdItem(id: link.childTaskId)
                        } label: {
                            Image(systemName: "info.circle")
                                .font(.system(size: 16))
                                .foregroundColor(.secondary)
                        }
                        .buttonStyle(.plain)
                        .accessibilityLabel("Open \(childTask?.title ?? "task") in library")
                    }
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
    /// understand why the cell is (or isn't) complete. Uses the same
    /// trigger-aware `meets` predicate as `achievementBadge(for:)` and
    /// `achievementCellIsCompleted(for:)` so the three surfaces never
    /// drift on completion semantics.
    @ViewBuilder
    private func achievementDetailContent(task: Task) -> some View {
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
            let ref = allBoardsInWorkspace.first(where: { $0.id == refBoardId })
            Section("Watching board") {
                if let ref {
                    HStack {
                        let isMet = meets(ref)
                        Image(systemName: isMet ? "checkmark.circle.fill" : "circle")
                            .foregroundColor(isMet ? .green : .secondary)
                        Text(ref.name)
                            .foregroundColor(.primary)
                        Spacer()
                        Text(trigger == .bingo ? "Bingo" : "Greenlog")
                            .font(.caption)
                            .foregroundColor(.secondary)
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
                        && DateFormatting.isWithinTimeframe(
                            b.startDate,
                            startDate: parent.startDate,
                            endDate: parent.endDate
                        )
                }
            }()
            let metCount = spawns.filter(meets).count
            let required = task.requiredCount ?? 0
            Section("Watching template") {
                HStack {
                    Image(systemName: "rectangle.stack")
                        .foregroundColor(.secondary)
                    Text(template?.name ?? "(referenced template unavailable)")
                        .foregroundColor(.primary)
                    Spacer()
                    // Format `met / required` — derivation requires
                    // metCount >= requiredCount on a non-empty in-window
                    // set, so this is the actual completion fraction.
                    // `(N in window)` aside tells the user how many
                    // spawns currently exist vs. how many they need.
                    Text("\(metCount) / \(required)")
                        .foregroundColor(.secondary)
                        .font(.subheadline.monospacedDigit())
                    Text(trigger == .bingo ? "Bingo" : "Greenlog")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
                Text("\(spawns.count) in-window spawn\(spawns.count == 1 ? "" : "s")")
                    .font(.caption)
                    .foregroundColor(.secondary)
            }
        } else {
            Section {
                Text("This achievement task has no reference set.")
                    .foregroundColor(.secondary)
            }
        }
        Section {
            Text("Derived from the watched target; the cell cannot be toggled directly.")
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

    /// Increments a counting task's `currentCount` by 1.
    ///
    /// Phase 3 — Shared Counters routing:
    ///  (a) Linked derived counter (`task.sharedCounterId != nil`): tap increments
    ///      the source task and propagates to all sibling linked tasks.
    ///  (b) Source counter (`task.id` appears as a `sharedCounterId` on any task
    ///      in `taskMap`): tap increments source + propagates to all linked tasks.
    ///  (c) Standalone counter (no shared link): falls through to the legacy
    ///      `runOrchestration` path.
    ///
    /// All shared-counter paths go through `AppDatabase.shared.incrementSharedCounter`,
    /// which enforces the overshoot (no high-end clamp) and one-way-latch invariants
    /// inside a single GRDB write transaction.
    ///
    /// - Parameters:
    ///   - boardTask: The counting task's `BoardTask` record.
    ///   - task: The `Task` providing `maxCount` and shared-counter fields.
    private func handleCountingTap(boardTask: BoardTask, task: Task) {
        guard !isProcessing else { return }

        // Detect whether this task participates in a shared-counter relationship.
        if let sourceId = task.sharedCounterId {
            // (a) Linked derived counter — increment the source.
            runSharedCounterIncrement(sourceTaskId: sourceId)
            return
        }

        // (b) Source counter — check if any task in the workspace links to this task.
        let isSource = allTasks.contains { $0.sharedCounterId == task.id && !$0.isDeleted }
        if isSource {
            runSharedCounterIncrement(sourceTaskId: task.id)
            return
        }

        // (c) Standalone counter — legacy path. NO high-end clamp per the
        //     feedback_counter_overshoot_is_valid invariant: overshoot is
        //     intentional and the count must be allowed to exceed maxCount.
        guard let maxCount = task.maxCount else { return }
        let now = AppDatabase.currentTimestamp()
        // NO min(...) clamp: let the count go past maxCount.
        let newCount = (task.currentCount ?? 0) + 1
        let wasCompleted = task.isCompleted
        let nowCompleted = wasCompleted || newCount >= maxCount

        var updatedTask = task
        updatedTask.currentCount = newCount
        updatedTask.isCompleted = nowCompleted
        updatedTask.completedAt = !wasCompleted && nowCompleted ? now : task.completedAt
        updatedTask.updatedAt = now
        updatedTask.version += 1

        runOrchestration(updatedTask: updatedTask, boardTask: boardTask)
    }

    /// Runs the shared-counter propagation in a background task, then refreshes
    /// board + task data on the main thread.
    ///
    /// Mirrors the pattern in `runOrchestration` (uses `_Concurrency.Task.detached`
    /// to avoid shadowing by the GRDB `Task` model).
    ///
    /// - Parameter sourceTaskId: The source (template) task id to increment.
    private func runSharedCounterIncrement(sourceTaskId: String) {
        guard !isProcessing else { return }
        isProcessing = true
        let currentBoardId = board?.id

        _Concurrency.Task.detached(priority: .userInitiated) {
            do {
                // Capture pre-increment board stats for flash-message comparison.
                let boardBefore: Board? = currentBoardId.flatMap { id in
                    try? AppDatabase.shared.read { db in try Board.fetchOne(db, key: id) }
                }

                try AppDatabase.shared.incrementSharedCounter(sourceTaskId: sourceTaskId)

                // Re-fetch the board after the write to detect bingo/greenlog changes.
                let boardAfter: Board? = currentBoardId.flatMap { id in
                    try? AppDatabase.shared.read { db in try Board.fetchOne(db, key: id) }
                }

                var newBingoMsg: String? = nil
                if let before = boardBefore, let after = boardAfter {
                    let prevBingos = Set(before.completedLineIds ?? [])
                    let nextBingos = Set(after.completedLineIds ?? [])
                    let gained = nextBingos.subtracting(prevBingos).sorted()
                    let lost = prevBingos.subtracting(nextBingos).sorted()
                    let totalSquares = after.boardSize * after.boardSize
                    let isGreenlogNow = after.completedTasks >= totalSquares

                    if before.status == .completed && after.status == .active {
                        newBingoMsg = "Board reactivated — no longer complete"
                    } else if !lost.isEmpty {
                        newBingoMsg = "Bingo lost: \(lost.joined(separator: ", "))"
                    } else if isGreenlogNow && after.status == .completed && before.status == .active {
                        newBingoMsg = "GREENLOG!"
                    } else if !gained.isEmpty {
                        newBingoMsg = "Bingo! (\(gained.joined(separator: ", ")))"
                    }
                }

                await MainActor.run {
                    isProcessing = false
                    loadBoard()
                    loadBoardTasks()
                    loadTaskData()
                    if let msg = newBingoMsg {
                        bingoMessage = msg
                        triggerRisoNotification(from: msg)
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
                print("⚠️ BoardPlayView shared-counter increment error: \(error)")
                await MainActor.run {
                    isProcessing = false
                }
            }
        }
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
                        triggerRisoNotification(from: msg)
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

    // MARK: - Cell Swap (M3)

    /// Swap the task occupying a non-center square to a different task from the library.
    ///
    /// Delegates to `AppDatabase.shared.updateBoardTaskAndCascade`, which:
    ///   1. Patches `BoardTask.taskId` atomically (version bump + sync enqueue).
    ///   2. Computes the union of boards affected by the OLD and NEW task.
    ///   3. Re-derives stats + GREENLOG transitions for each affected board.
    ///
    /// The swap runs on a detached `_Concurrency.Task` to avoid blocking the main thread.
    /// UI is refreshed via `loadBoardTasks()` + `loadTaskData()` on completion (the
    /// sheet's `onDismiss` also triggers a reload as a defensive belt-and-suspenders).
    ///
    /// - Parameters:
    ///   - boardTaskId: The `BoardTask.id` whose cell is being swapped.
    ///   - newTaskId: The replacement `Task.id`.
    private func handleCellSwap(boardTaskId: String, newTaskId: String) {
        isProcessing = true
        _Concurrency.Task.detached(priority: .userInitiated) {
            do {
                try AppDatabase.shared.updateBoardTaskAndCascade(
                    boardTaskId: boardTaskId,
                    newTaskId: newTaskId
                )
                await MainActor.run {
                    isProcessing = false
                    loadBoard()
                    loadBoardTasks()
                    loadTaskData()
                }
            } catch {
                print("⚠️ BoardPlayView cell swap error: \(error)")
                await MainActor.run {
                    isProcessing = false
                    bingoMessage = "Swap failed — please try again"
                }
            }
        }
    }

    // MARK: - Placement Add / Remove (M4)

    /// Remove a task placement from the current board.
    ///
    /// Delegates to `AppDatabase.shared.removeBoardTaskFromBoard`, which hard-deletes
    /// the `BoardTask` row, enqueues a DELETE sync tombstone, and re-derives stats for
    /// every board affected by the removed task. The underlying `Task` is untouched.
    ///
    /// - Parameter boardTaskId: The `BoardTask.id` to remove.
    private func handleRemoveFromBoard(boardTaskId: String) {
        isProcessing = true
        _Concurrency.Task.detached(priority: .userInitiated) {
            do {
                try AppDatabase.shared.removeBoardTaskFromBoard(boardTaskId)
                await MainActor.run {
                    isProcessing = false
                    loadBoard()
                    loadBoardTasks()
                    loadTaskData()
                }
            } catch {
                print("⚠️ BoardPlayView remove-from-board error: \(error)")
                await MainActor.run {
                    isProcessing = false
                    bingoMessage = "Remove failed — please try again"
                }
            }
        }
    }

    /// Add a task to an empty cell on the current board.
    ///
    /// Delegates to `AppDatabase.shared.addBoardTaskToBoard`, which creates a new
    /// `BoardTask` placement, enqueues a CREATE sync entry, and re-derives stats for
    /// every board affected by the placed task. If the task is already globally
    /// completed, the cascade immediately credits this cell as completed.
    ///
    /// - Parameters:
    ///   - taskId: The `Task.id` to place.
    ///   - row: 0-based grid row.
    ///   - col: 0-based grid column.
    private func handleAddTaskToCell(taskId: String, row: Int, col: Int) {
        guard let b = board else { return }
        isProcessing = true
        _Concurrency.Task.detached(priority: .userInitiated) {
            do {
                try AppDatabase.shared.addBoardTaskToBoard(
                    b.id,
                    taskId: taskId,
                    position: (row: row, col: col)
                )
                await MainActor.run {
                    isProcessing = false
                    loadBoard()
                    loadBoardTasks()
                    loadTaskData()
                }
            } catch {
                print("⚠️ BoardPlayView add-to-cell error: \(error)")
                await MainActor.run {
                    isProcessing = false
                    bingoMessage = "Add failed — please try again"
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
                        triggerRisoNotification(from: msg)
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

// MARK: - BackButton

/// 40×40 Riso back-chevron square button for the in-content play-board header.
/// Uses the SwiftUI environment's `dismiss` action so it integrates correctly
/// with `NavigationStack`'s internal path management.
private struct BackButton: View {
    @Environment(\.dismiss) private var dismiss
    var body: some View {
        Button {
            dismiss()
        } label: {
            Image(systemName: "chevron.left")
                .font(.system(size: 18, weight: .bold))
                .foregroundStyle(Color.risoInk)
                .frame(width: 40, height: 40)
                .background(Color.risoPaper2)
                .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Riso.cardRadius)
                        .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
                )
                .background(
                    RoundedRectangle(cornerRadius: Riso.cardRadius)
                        .fill(Color.risoInk)
                        .offset(x: Riso.Shadow.small, y: Riso.Shadow.small)
                )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Back")
    }
}

// MARK: - Preview

#Preview {
    NavigationStack {
        BoardPlayView(boardId: "example-board-id-123")
            .environmentObject(AuthService())
    }
}
