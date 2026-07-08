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
    /// Catch-all draft guard: a DRAFT board is never rendered as a playable
    /// grid. When a draft is loaded (non-embedded) this fires with the board
    /// id so the host can resume it in the wizard. Covers every navigation
    /// path that lands on a board id (core-board browser, task-detail Usage
    /// jump, stray deep-links) — the list/core-grid/pager route to resume
    /// directly before reaching here, so this is the safety net. Nil ⇒ the
    /// guard still suppresses the grid but offers no resume action.
    var onResumeDraft: ((String) -> Void)? = nil
    @EnvironmentObject var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    // MARK: - State

    /// Owns the data-loading layer (B2-I1). The seven data arrays the play
    /// surface reads are now `@Published private(set)` on the view model and
    /// exposed here as read-only computed shims so every existing read site
    /// (`board`, `boardTasks`, …) is untouched. Constructed in `init` with
    /// the board id + user id.
    @StateObject private var viewModel: BoardPlayViewModel

    private var board: Board? { viewModel.board }
    private var boardTasks: [BoardTask] { viewModel.boardTasks }
    private var allTasks: [Task] { viewModel.allTasks }
    private var allCompoundChildren: [CompoundChild] { viewModel.allCompoundChildren }
    // Phase 6.3 — workspace-wide boards + templates feed both the
    // achievement-square config sheet (for the pickers) and the per-
    // cell badge data computation. Refreshed alongside the task data
    // so the sheet always sees up-to-date data when opened.
    private var allBoardsInWorkspace: [Board] { viewModel.allBoardsInWorkspace }
    private var allTemplatesInWorkspace: [RecurringBoardTemplate] { viewModel.allTemplatesInWorkspace }
    private var allBoardTasksInWorkspace: [BoardTask] { viewModel.allBoardTasksInWorkspace }

    @State private var isProcessing = false
    @State private var bingoMessage: String?
    // MARK: Riso visual layer state
    /// Whether to show the GREENLOG full-bleed celebration overlay.
    @State private var showGreenlogOverlay: Bool = false
    /// Compact greenlog-streak value (e.g. "3d"/"2w") for the celebration overlay
    /// + share poster. Non-nil only for core boards with a streak ≥ 1; nil hides
    /// the STREAK card. Computed when the GREENLOG overlay is triggered.
    @State private var greenlogStreakValue: String? = nil
    /// Whether to show the Share Board sheet (opened from the GREENLOG overlay).
    @State private var showShareBoardSheet: Bool = false
    /// Whether to show the bingo toast (drops from top).
    @State private var showBingoToast: Bool = false
    /// Subtitle for the current bingo toast (e.g. "Row 2 complete!").
    @State private var bingoToastSubtitle: String = ""
    /// Monotonic token so only the latest toast's auto-dismiss fires —
    /// rapid bingos no longer spawn overlapping dismiss tasks that cut a
    /// fresh toast short.
    @State private var bingoToastGeneration: Int = 0
    // MARK: P2 — Shared-counter credited toast
    /// Whether to show the shared-counter credit toast (slides from bottom).
    @State private var showCreditToast: Bool = false
    /// Copy shown in the credit toast, e.g. "Push-ups logged — also counted on Board A, Board B."
    @State private var creditToastText: String = ""
    /// Monotonic token so only the latest credit toast's auto-dismiss fires.
    @State private var creditToastGeneration: Int = 0
    /// Board task id of the counting cell whose stepper sheet is open.
    @State private var countingStepperBoardTaskId: String?
    @State private var detailBoardTaskId: String?
    /// Drives the task-detail library sheet (separate from the board-play detail sheet).
    @State private var taskDetailSheetTaskId: TaskIdItem?
    // MARK: Edit-mode draft state (Phase 1 board-edit chrome)
    /// True while the in-place `BoardEditPanel` is overlaid on `BoardPlayView`.
    @State private var editMode: Bool = false
    /// Draft board name input.
    @State private var editName: String = ""
    /// Draft timeframe segmented picker value.
    @State private var editTimeframe: Timeframe = .monthly
    /// Draft custom start-date picker value.
    @State private var editCustomStartDate: Date = Date()
    /// Draft custom end-date picker value.
    @State private var editCustomEndDate: Date = Date()
    /// Original parsed start date seeded from `board.startDate` — used by the
    /// `BoardEditPanel` dirty-check comparison.
    @State private var editOriginalCustomStartDate: Date = Date()
    /// Original parsed end date seeded from `board.endDate` — used by the
    /// `BoardEditPanel` dirty-check comparison.
    @State private var editOriginalCustomEndDate: Date = Date()
    /// Draft center-square type selector value.
    @State private var editCenterType: CenterSquareType = .free
    /// Draft custom center name input (only relevant when `editCenterType == .customFree`).
    @State private var editCenterCustomName: String = ""
    /// True when the board already has a center-task placement (gates CHOSEN option).
    /// Loaded asynchronously by `seedEditDraft(from:)`.
    @State private var editHasCandidateTasks: Bool = false
    /// Which squares sub-mode (Edit tasks / Rearrange) is active.
    @State private var editSubMode: BoardEditSubMode = .editTasks
    /// True while `updateBoardAndCascade` is in flight — disables the Save pill.
    @State private var editSaving: Bool = false
    /// Surfaces a board-edit Save failure (the edit panel overlays the inline
    /// flash, so a system alert is used — it pierces the overlay).
    @State private var editSaveError: String?
    /// Controls the "Board saved" success toast (auto-dismissed after 2.4 s).
    @State private var showEditSavedToast: Bool = false
    // MARK: Edit-mode squares draft (Phase 2 — Edit tasks)
    /// Per-cell staged state keyed by "row-col". Seeded from live `BoardTask`
    /// rows when the user enters edit mode; modified by Replace / Edit-task actions.
    /// Nothing is written to the DB until `handleEditSave` commits.
    @State private var editSquaresDraft: [String: SquaresDraftCell] = [:]
    /// Staged task-field overrides keyed by taskId (global — shared by all squares
    /// that reference the same task). Applied to `editDraftTaskMap` for rendering and
    /// committed via `saveTaskAndCascade` in `handleEditSave`.
    @State private var editTaskOverrides: [String: StagedTaskOverride] = [:]
    /// Target for the "Replace task" sheet triggered from a cell tap in edit mode.
    @State private var editModeReplaceTarget: EditModeSwapTarget? = nil
    /// Target for the "Edit task" sheet triggered from a cell tap in edit mode.
    @State private var editModeTaskTarget: EditModeTaskTarget? = nil
    /// Row/col of the cell whose tap-menu is displayed. Set alongside the
    /// `.confirmationDialog` trigger.
    @State private var editCellMenuRow: Int = 0
    @State private var editCellMenuCol: Int = 0
    @State private var editCellMenuVisible: Bool = false
    /// True when the tap-menu was opened for the positional center cell
    /// (used to show the Phase-2b "Make it a free space" / "Make it a task
    /// square" toggle items in `confirmationDialog`).
    @State private var editCellMenuIsCenter: Bool = false
    /// M3 — live-edit cell swap: the square whose task the user wants to replace.
    @State private var swapTarget: SwapTarget? = nil
    /// M4 — live-edit remove from board: the boardTaskId pending confirmation.
    @State private var removeBoardTaskId: String? = nil
    /// M4 — live-edit add to empty cell: the grid position awaiting task selection.
    @State private var addCellPos: (row: Int, col: Int)? = nil
    /// M4 — tracks whether the add-cell sheet was dismissed via a confirmed selection.
    /// `onDismiss` skips the reload when true because `handleAddTaskToCell` already reloads.
    @State private var addTaskConfirmed: Bool = false
    /// Phase 3 — Rearrange sub-mode staged state.
    /// Ordered `[RearrangeCellData]` array shown by `RearrangeGrid`. nil until
    /// the user first enters Rearrange sub-mode (built lazily by `seedRearrangeCells`).
    @State private var editRearrangeCells: [RearrangeCellData]? = nil

    /// Stashed target for cross-board navigation requested from inside
    /// the task-detail sheet. We can't mutate `boardsPath` while the
    /// sheet is dismissing — SwiftUI swallows the path change during
    /// the transition, leaving the user on the original board. Setting
    /// this stash + watching `taskDetailSheetTaskId` for nil-transition
    /// (see `.onChange` below) sequences dismiss-then-navigate
    /// correctly.
    @State private var pendingOpenBoardId: String?

    // MARK: - Init

    /// Constructs the view and its data-loading `BoardPlayViewModel`.
    ///
    /// The view model is created with a nil userId here because the
    /// `@EnvironmentObject` `AuthService` is not available in a SwiftUI
    /// `init`. The view supplies the authenticated user's id to the view
    /// model in `.onAppear` (via `setUserId`), where the env IS available —
    /// faithfully reproducing the pre-refactor behavior, where the loaders
    /// read `authService.currentUser?.id` at reload time.
    init(
        boardId: String,
        onOpenBoard: @escaping (String) -> Void = { _ in },
        embedded: Bool = false,
        onResumeDraft: ((String) -> Void)? = nil
    ) {
        self.boardId = boardId
        self.onOpenBoard = onOpenBoard
        self.embedded = embedded
        self.onResumeDraft = onResumeDraft
        _viewModel = StateObject(
            wrappedValue: BoardPlayViewModel(boardId: boardId, userId: nil)
        )
    }

    // MARK: - Computed

    /// O(1) task lookup by task ID.
    private var taskMap: [String: Task] {
        Dictionary(uniqueKeysWithValues: allTasks.map { ($0.id, $0) })
    }

    // MARK: - Edit-mode squares draft (Phase 2)

    /// Live `BoardTask` rows with staged task-ID replacements applied.
    /// Used as `boardTasks:` in `BoardEditPanel` so the draft grid shows
    /// the staged tasks without touching the database.
    private var editDraftBoardTasks: [BoardTask] {
        guard editMode, !editSquaresDraft.isEmpty else { return boardTasks }
        return boardTasks.map { bt in
            let key = "\(bt.row)-\(bt.col)"
            guard let draft = editSquaresDraft[key],
                  draft.stagedTaskId != bt.taskId else { return bt }
            var copy = bt
            copy.taskId = draft.stagedTaskId
            return copy
        }
    }

    /// `taskMap` with staged task-field overrides applied.
    /// Used as `taskMap:` in `BoardEditPanel` so cell labels show the
    /// staged title/type without a database write.
    private var editDraftTaskMap: [String: Task] {
        guard editMode, !editTaskOverrides.isEmpty else { return taskMap }
        var map = taskMap
        for (taskId, override) in editTaskOverrides {
            guard var t = map[taskId] else { continue }
            t.title = override.title
            t.type  = override.type
            if override.type == .counting {
                t.action   = override.action
                t.unit     = override.unit
                t.maxCount = override.maxCount
            }
            map[taskId] = t
        }
        return map
    }

    /// Number of staged square edits: cell replacements + task-field overrides +
    /// position moves (from Rearrange sub-mode).
    ///
    /// Position moves are DERIVED: a drag that returns a cell to its original slot
    /// is net-zero and does not inflate the counter. Each `RearrangeCellData` carries
    /// its `originalRow`/`originalCol` so we can compare the current slot index to
    /// the original position. The staged positions are inferred from the order of
    /// `editRearrangeCells` (index → row-major row/col).
    ///
    /// Forwarded to `BoardEditPanel.squareEditCount` so the counter and Save pill
    /// react to square-level changes, not just metadata changes.
    private var editSquaresEditCount: Int {
        guard editMode else { return 0 }
        let replacements = editSquaresDraft.values
            .filter { $0.stagedTaskId != $0.originalTaskId }.count
        let overrides = editTaskOverrides.count
        let positionMoves = countPositionMoves(in: editRearrangeCells, gridSize: gridSize)
        return replacements + overrides + positionMoves
    }

    /// Returns the number of task cells that are in a different grid slot from
    /// their `originalRow`/`originalCol`. Center and empty slots are excluded.
    private func countPositionMoves(in cells: [RearrangeCellData]?, gridSize: Int) -> Int {
        guard let cells, gridSize > 0 else { return 0 }
        var count = 0
        for (slotIdx, cell) in cells.enumerated() {
            guard !cell.isCenter, !cell.isEmpty else { continue }
            let stagedRow = slotIdx / gridSize
            let stagedCol = slotIdx % gridSize
            if stagedRow != cell.originalRow || stagedCol != cell.originalCol {
                count += 1
            }
        }
        return count
    }

    /// Display title for the tap-menu confirmationDialog.
    ///
    /// - For a free-center tap (no draft entry): returns "Center square".
    /// - For any task cell: returns the staged task title.
    private var editCellMenuTitle: String {
        // Free center tap has no squaresDraft entry — give it a clear title.
        if editCellMenuIsCenter
            && (editCenterType == .free || editCenterType == .customFree) {
            return "Center square"
        }
        let key = "\(editCellMenuRow)-\(editCellMenuCol)"
        guard let draft = editSquaresDraft[key] else { return "Square" }
        let map = editDraftTaskMap
        return map[draft.stagedTaskId]?.title ?? "Square"
    }

    /// Returns true when `boardTask.isCenter` AND the board's center type
    /// (using the edit draft while in edit mode) is non-`.none`. This is the
    /// Phase-2b "pinned center" predicate used by the live context menus.
    ///
    /// A `.none`-center board task that happens to sit at the middle position
    /// is NOT pinned — Swap and Remove are enabled for it.
    private func isPinnedCenter(boardTask: BoardTask) -> Bool {
        guard boardTask.isCenter else { return false }
        let effectiveCenterType = editMode ? editCenterType : (board?.centerSquareType ?? .none)
        return effectiveCenterType != .none
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
        case .indefinite: return "ONGOING BOARD"
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

                    if let b = board, b.status == .draft, !embedded {
                        // ── Draft guard ──
                        // A draft is never playable. Show a resume prompt
                        // instead of the stat bar + grid (the header already
                        // carries the name + DRAFT badge). Reached only via
                        // secondary nav (browser / Usage jump) — the primary
                        // surfaces route to resume before getting here.
                        draftResumeSection(board: b)
                            .padding(.horizontal, Riso.gutter)
                            .padding(.top, 24)
                    } else {
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

            // ── P2: Shared-counter credit toast (slides from bottom) ──
            if showCreditToast {
                VStack {
                    Spacer()
                    HStack(spacing: 8) {
                        Image(systemName: "arrow.left.arrow.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.risoBlue)
                        Text(creditToastText)
                            .font(.risoBody(12, .semibold))
                            .foregroundStyle(Color.risoInk)
                            .multilineTextAlignment(.leading)
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 10)
                    .background(Color.risoPaper2)
                    .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
                    .overlay(
                        RoundedRectangle(cornerRadius: Riso.cardRadius)
                            .strokeBorder(Color.risoBlue, lineWidth: Riso.Keyline.dense)
                    )
                    .background(
                        RoundedRectangle(cornerRadius: Riso.cardRadius)
                            .fill(Color.risoInk)
                            .offset(x: Riso.Shadow.small, y: Riso.Shadow.small)
                    )
                    .padding(.horizontal, Riso.gutter)
                    .padding(.bottom, 100)
                }
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .bottom).combined(with: .opacity),
                        removal: .move(edge: .bottom).combined(with: .opacity)
                    )
                )
                .zIndex(9)
            }

            // ── GREENLOG overlay (full-bleed) ──
            if showGreenlogOverlay, let b = board {
                RisoGreenlogOverlay(
                    completedTasks: b.completedTasks,
                    totalTasks: b.totalTasks,
                    linesCompleted: b.linesCompleted,
                    boardName: b.name,
                    streak: greenlogStreakValue,
                    celebrationIntensity: authService.userPreferences.celebrationIntensity,
                    onShare: {
                        showShareBoardSheet = true
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

            // ── "Board saved" toast (drops from top after a successful edit save) ──
            if showEditSavedToast {
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 14, weight: .semibold))
                        .foregroundStyle(Color.risoGreen)
                    Text("Board saved")
                        .font(.risoBody(14, .semibold))
                        .foregroundStyle(Color.risoInk)
                }
                .padding(.horizontal, 16)
                .padding(.vertical, 12)
                .background(Color.risoPaper2)
                .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Riso.cardRadius)
                        .strokeBorder(Color.risoGreen, lineWidth: Riso.Keyline.container)
                )
                .background(
                    RoundedRectangle(cornerRadius: Riso.cardRadius)
                        .fill(Color.risoInk)
                        .offset(x: Riso.Shadow.small, y: Riso.Shadow.small)
                )
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, Riso.gutter)
                .padding(.top, 54)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    )
                )
                .zIndex(11)
            }

            // ── In-place board edit chrome (Phase 1) ──
            // Full-screen overlay that replaces the retired `EditBoardSheet` modal.
            // Sits above the GREENLOG overlay (zIndex 20) so it covers celebrations
            // triggered just before the user taps Save.
            if editMode, let b = board {
                BoardEditPanel(
                    board: b,
                    boardTasks: editDraftBoardTasks,
                    taskMap: editDraftTaskMap,
                    weekStartDay: authService.currentUser?.decodedPreferences.weekStartDay.rawValue ?? "monday",
                    originalCustomStartDate: editOriginalCustomStartDate,
                    originalCustomEndDate: editOriginalCustomEndDate,
                    name: $editName,
                    timeframe: $editTimeframe,
                    customStartDate: $editCustomStartDate,
                    customEndDate: $editCustomEndDate,
                    centerType: $editCenterType,
                    centerCustomName: $editCenterCustomName,
                    hasCandidateTasks: editHasCandidateTasks,
                    subMode: $editSubMode,
                    squareEditCount: editSquaresEditCount,
                    onCellTap: { row, col in handleEditCellTap(row: row, col: col) },
                    // Phase 2b — center toggle (free center → task square).
                    onCenterTap: handleFreeCenterTap,
                    // Phase 3 — Rearrange
                    rearrangeCells: editRearrangeCells,
                    onReorder: handleRearrange,
                    isSaving: editSaving,
                    onSave: handleEditSave,
                    onCancelConfirmed: {
                        withAnimation(.easeInOut(duration: 0.22)) { editMode = false }
                    },
                    onArchiveConfirmed: handleEditArchive
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.risoPaper.ignoresSafeArea())
                .transition(.opacity)
                .zIndex(30)
                // Phase 3 — seed rearrange cells lazily on sub-mode switch to Rearrange.
                .onChange(of: editSubMode) { _, newMode in
                    if newMode == .rearrange {
                        seedRearrangeCells(for: b)
                    }
                }
                // Phase 2b — when center type changes (via the toggle or the
                // BoardSetupFormView picker), rebuild the staged rearrange cells
                // so the Rearrange sub-mode immediately reflects the new pinning.
                // If no rearrange cells exist yet, seedRearrangeCells will build
                // them with the correct type on the next sub-mode switch.
                .onChange(of: editCenterType) { _, newType in
                    guard let current = editRearrangeCells else { return }
                    // Preserve any staged rearrange order: map each non-center,
                    // non-empty cell's CURRENT slot index back to (row, col) and pass
                    // it as the positionDraft, so changing the center type doesn't
                    // discard the user's in-progress rearrange.
                    let size = b.boardSize
                    var positions: [String: (row: Int, col: Int)] = [:]
                    for (i, cell) in current.enumerated() where !cell.isCenter && !cell.isEmpty {
                        positions[cell.id] = (row: i / size, col: i % size)
                    }
                    editRearrangeCells = buildRearrangeCells(
                        squaresDraft: editSquaresDraft,
                        gridSize: size,
                        centerSquareType: newType,
                        positionDraft: positions
                    )
                }
            }

            // ── Counting stepper sheet ──
            // Presented as a sheet (see .sheet modifier below)
        }
        .modifier(BoardPlayTitleChrome(title: board?.name ?? "Board", enabled: !embedded))
        // M2 — toolbar "Edit" button (ACTIVE boards only; DRAFT uses the wizard;
        // COMPLETED / ARCHIVED boards are immutable).
        .toolbar {
            // M2 — "Edit" button: visible on ACTIVE non-embedded boards when the
            // edit-mode panel is not already open (hide it once we're editing so
            // the top bar inside `BoardEditPanel` owns all navigation).
            if let b = board, b.status == .active, !embedded, !editMode {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Edit") {
                        seedEditDraft(from: b)
                        withAnimation(.easeInOut(duration: 0.22)) { editMode = true }
                    }
                }
            }
        }
        // Phase 2 — Tap-menu: Replace task / Edit task (+ Phase-2b center toggle).
        // Presented when the user taps an occupied square OR the free center cell
        // while in edit mode + Edit-tasks sub-mode.
        // Uses .confirmationDialog so it anchors natively to the bottom (iOS
        // action-sheet idiom).
        .confirmationDialog(
            editCellMenuTitle,
            isPresented: $editCellMenuVisible,
            titleVisibility: .visible
        ) {
            // Replace / Edit task: shown for any occupied cell (including a .none
            // center with a task). Not shown for a free center (no task draft entry).
            let cellKey = "\(editCellMenuRow)-\(editCellMenuCol)"
            if editSquaresDraft[cellKey] != nil {
                Button("Replace task") {
                    if let draft = editSquaresDraft[cellKey] {
                        editModeReplaceTarget = EditModeSwapTarget(
                            id: cellKey,
                            currentTaskId: draft.stagedTaskId
                        )
                    }
                }
                Button("Edit task") {
                    if let draft = editSquaresDraft[cellKey] {
                        let map = editDraftTaskMap
                        if let task = map[draft.stagedTaskId] {
                            editModeTaskTarget = EditModeTaskTarget(id: cellKey, task: task)
                        }
                    }
                }
            }

            // Phase 2b — Center toggle buttons. Only shown when the tapped cell
            // is the positional center. .chosen is intentionally excluded — the
            // BoardSetupFormView chrome is the way out of CHOSEN.
            if editCellMenuIsCenter {
                if editCenterType == .free || editCenterType == .customFree {
                    // Free center → task square (empty; fill via the live "+" flow).
                    // The .onChange(of: editCenterType) handler rebuilds the rearrange
                    // cells (preserving any staged order) — no inline rebuild here.
                    Button("Make it a task square") { editCenterType = .none }
                } else if editCenterType == .none {
                    // Task square (or empty slot) → free space.
                    Button("Make it a free space") { editCenterType = .free }
                }
            }

            Button("Cancel", role: .cancel) {}
        }
        // Phase 2 — Replace task sheet (staged; no DB write on confirm).
        .sheet(item: $editModeReplaceTarget) { target in
            CellSwapSheet(
                mode: .swap,
                currentTaskId: target.currentTaskId,
                candidateTasks: allTasks,
                onDismiss: { editModeReplaceTarget = nil },
                onConfirm: { newTaskId in
                    editModeReplaceTarget = nil
                    handleEditCellReplace(cellKey: target.id, newTaskId: newTaskId)
                }
            )
        }
        // Phase 2 — Edit task sheet (staged; no DB write on Done).
        .sheet(item: $editModeTaskTarget) { target in
            SquareEditTaskSheet(
                task: target.task,
                onDone: { patch in
                    editModeTaskTarget = nil
                    handleEditTaskOverride(taskId: target.task.id, patch: patch)
                },
                onCancel: { editModeTaskTarget = nil }
            )
        }
        // M3 — Cell swap sheet. Presented when the user taps "⎘ Swap with
        // another task…" in the context menu of a non-center ACTIVE square.
        .sheet(
            item: $swapTarget,
            onDismiss: {
                // Reload so the grid reflects any completed swap. The board
                // record itself is unchanged, so this skips the board fetch.
                viewModel.reloadBoardTasksAndTaskData()
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
        // Board-edit Save failure — a system alert pierces the edit overlay.
        .alert(
            "Couldn’t save",
            isPresented: Binding(
                get: { editSaveError != nil },
                set: { if !$0 { editSaveError = nil } }
            ),
            actions: { Button("OK", role: .cancel) { editSaveError = nil } },
            message: { Text(editSaveError ?? "") }
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
                    viewModel.reloadBoardTasksAndTaskData()
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
            // Supply the authenticated user id from the env (unavailable in
            // `init`) before the first load. userId is stable for the
            // session, so later reloads (post-write tails, sheet dismisses,
            // pager board-changes) reuse it.
            viewModel.setUserId(authService.currentUser?.id)
            viewModel.reload()
        }
        // Defensive: also reload on boardId prop change. With `.id(boardId)`
        // on the standalone destination, SwiftUI re-creates the view (and the
        // view model) so .onAppear fires — but the embedded core-board pager
        // reuses the SAME BoardPlayView instance (no `.id()`), so this points
        // the existing view model at the new board and reloads.
        .onChange(of: boardId) { _, newBoardId in
            viewModel.boardChanged(to: newBoardId)
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
                // P2: Compute shared hint — other ACTIVE boards where a member
                // task lives, excluding the current board.
                let sharedHint: String? = sharedStepperHint(for: task)
                RisoCountingStepperSheet(
                    taskTitle: task.title,
                    currentCount: displayed,
                    maxCount: maxVal,
                    unitText: task.unit ?? "",
                    isLinkedCounter: isLinked,
                    sharedHint: sharedHint,
                    onIncrement: {
                        handleCountingTap(boardTask: bt, task: task)
                    },
                    onDecrement: {
                        handleCountingDecrement(boardTask: bt, task: task)
                    }
                    // Dismissal clears `countingStepperBoardTaskId` via the
                    // .sheet(isPresented:) binding setter above.
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
        // Share board sheet — presented from the GREENLOG overlay's "Share my board"
        // button. The GREENLOG overlay stays visible beneath the sheet.
        .sheet(isPresented: $showShareBoardSheet) {
            if let b = board {
                ShareBoardSheet(
                    boardName: b.name,
                    boardId: b.id,
                    completedTasks: b.completedTasks,
                    totalTasks: b.totalTasks,
                    linesCompleted: b.linesCompleted,
                    streak: greenlogStreakValue,
                    onDismiss: { showShareBoardSheet = false }
                )
                .presentationDetents([.medium, .large])
            }
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

    /// Draft-guard body: shown in place of the stat bar + grid when a draft
    /// board is loaded outside the wizard. Drafts are never playable; this
    /// offers to resume the draft in the wizard instead.
    @ViewBuilder
    private func draftResumeSection(board: Board) -> some View {
        VStack(spacing: 16) {
            BlipPlaceholder(size: 56, mood: .calm)

            Text("This board is still a draft.")
                .risoH2()
                .multilineTextAlignment(.center)

            Text("Finish setting it up in the wizard — drafts aren't playable until you complete them.")
                .risoSub()
                .multilineTextAlignment(.center)
                .padding(.horizontal, 16)

            if let onResumeDraft {
                RisoButton(
                    title: "Resume draft",
                    kind: .primary,
                    systemImage: "pencil.and.outline",
                    action: { onResumeDraft(board.id) }
                )
                .padding(.top, 4)
            }
        }
        .frame(maxWidth: .infinity)
    }

    @ViewBuilder
    private var risoBackButton: some View {
        // In-content back square. When !embedded, BoardPlayTitleChrome hides
        // the system nav-bar back button, so this IS the primary back
        // affordance (the swipe-back gesture still works); when embedded the
        // host owns the chrome. Uses the environment dismiss action.
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
        guard board.timeframe != .custom, !board.isIndefinite else { return "No end" }
        guard let endStr = board.endDate, let end = parseISO8601Date(endStr) else { return "—" }
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
    /// Rapid bingos re-arm the toast: each one bumps `bingoToastGeneration`, and
    /// only the latest generation's auto-dismiss fires, so a fresh toast isn't
    /// cut short by an earlier one's timer.
    private func triggerRisoNotification(from message: String) {
        if message == "GREENLOG!" {
            // Compute the greenlog streak for the overlay/poster (core boards
            // only). Runs while the 0.52s reveal delay elapses.
            refreshGreenlogStreak()
            // Delay to let the 25th cell pop animation finish (~340ms + margin)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.52) {
                withAnimation(.easeIn(duration: 0.3)) {
                    showGreenlogOverlay = true
                }
            }
        } else if message.lowercased().contains("bingo") && !message.lowercased().contains("lost") {
            // Extract a short subtitle from the message.
            // Original format: "Bingo! (row_1, col_2)" → "Line complete!"
            bingoToastSubtitle = "Line complete!"
            bingoToastGeneration &+= 1
            let generation = bingoToastGeneration
            withAnimation(.spring(response: 0.5, dampingFraction: 0.7)) {
                showBingoToast = true
            }
            // Auto-dismiss after ~2.8s — but only if no newer toast has been
            // shown since (otherwise this stale timer would cut it short).
            _Concurrency.Task.detached { @MainActor in
                try? await _Concurrency.Task.sleep(nanoseconds: 2_800_000_000)
                guard generation == bingoToastGeneration else { return }
                withAnimation(.easeOut(duration: 0.25)) {
                    showBingoToast = false
                }
            }
        }
    }

    // MARK: - P2: Shared-counter credit toast helpers

    /// Fires the credit toast for a shared-counter ripple that reached other boards.
    /// Uses a generation token to prevent stale auto-dismiss from clipping a new toast.
    ///
    /// - Parameter text: The full toast copy string.
    private func triggerCreditToast(text: String) {
        creditToastText = text
        creditToastGeneration &+= 1
        let generation = creditToastGeneration
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
            showCreditToast = true
        }
        _Concurrency.Task.detached { @MainActor in
            try? await _Concurrency.Task.sleep(nanoseconds: 2_600_000_000)
            guard generation == creditToastGeneration else { return }
            withAnimation(.easeOut(duration: 0.2)) {
                showCreditToast = false
            }
        }
    }

    /// Builds the credit toast copy for an increment or decrement.
    ///
    /// Increment: `"{name} logged — also counted on {A}, {B}."`
    /// Decrement:  `"{name} removed — also taken off {A}, {B}."`
    ///
    /// - Parameters:
    ///   - counterName: The counter's display name (source task title).
    ///   - otherBoards: Boards OTHER than the current board that were credited.
    ///   - isIncrement: `true` for increment, `false` for decrement.
    private func sharedCreditToastText(
        counterName: String,
        otherBoards: [AppDatabase.AffectedBoard],
        isIncrement: Bool
    ) -> String {
        let boardNames = otherBoards.map { $0.boardName }.joined(separator: ", ")
        if isIncrement {
            return "\(counterName) logged — also counted on \(boardNames)."
        } else {
            return "\(counterName) removed — also taken off \(boardNames)."
        }
    }

    /// Computes the "↔ Shared · also counts on …" hint shown in the stepper sheet
    /// for a shared-counter task. Returns `nil` when the task is not in a shared group
    /// or has no OTHER active boards to mention.
    ///
    /// - Parameter task: The `Task` backing the tapped counting square.
    private func sharedStepperHint(for task: Task) -> String? {
        guard task.type == .counting else { return nil }

        // Determine the source task id for this counter.
        let sourceId: String
        if let linkedSourceId = task.sharedCounterId {
            sourceId = linkedSourceId
        } else if allTasks.contains(where: { $0.sharedCounterId == task.id && !$0.isDeleted }) {
            sourceId = task.id
        } else {
            return nil  // Not in a shared group.
        }

        // Collect all member task ids (source + linked).
        let memberIds: Set<String> = {
            var ids = Set<String>([sourceId])
            for t in allTasks where t.sharedCounterId == sourceId && !t.isDeleted {
                ids.insert(t.id)
            }
            return ids
        }()

        // Find ACTIVE boards (other than the current board) where any member is placed.
        let currentBid = board?.id
        var seenBoardIds = Set<String>()
        if let cid = currentBid { seenBoardIds.insert(cid) }
        var otherBoardNames: [String] = []
        for bt in allBoardTasksInWorkspace {
            guard memberIds.contains(bt.taskId),
                  !seenBoardIds.contains(bt.boardId)
            else { continue }
            if let b = allBoardsInWorkspace.first(where: { $0.id == bt.boardId }),
               !b.isDeleted, b.status == .active {
                seenBoardIds.insert(b.id)
                otherBoardNames.append(b.name)
            }
        }
        guard !otherBoardNames.isEmpty else { return nil }
        otherBoardNames.sort()  // stable order

        if otherBoardNames.count == 1 {
            return "↔ Shared · also counts on \(otherBoardNames[0])"
        } else {
            let first = otherBoardNames[0]
            let more = otherBoardNames.count - 1
            return "↔ Shared · also counts on \(first) + \(more) more"
        }
    }

    /// Computes the greenlog streak for the current board (core boards only) and
    /// stores a compact label in `greenlogStreakValue` for the overlay + poster.
    /// Non-core boards → nil (the STREAK card hides). Reads boards off-main.
    private func refreshGreenlogStreak() {
        guard let b = board, b.isCore else {
            greenlogStreakValue = nil
            return
        }
        let userId = b.userId
        let timeframe = b.timeframe
        let weekStartDay = authService.userPreferences.weekStartDay.rawValue
        _Concurrency.Task.detached {
            let boards = (try? AppDatabase.shared.fetchBoards(userId: userId)) ?? []
            let count = computeStreak(
                timeframe: timeframe, criterion: .greenlog,
                boards: boards, weekStartDay: weekStartDay, now: Date()
            )
            let value = count >= 1 ? compactStreakLabel(count, timeframe: timeframe) : nil
            await MainActor.run { greenlogStreakValue = value }
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
                    // FREE center cell — gold FREE label, not interactive in play mode.
                    RisoBoardPlayCell(
                        title: "FREE",
                        taskType: .normal,
                        isCompleted: false,
                        isBingoLine: highlighted.contains(index),
                        isCenter: true
                    )
                } else if let b = board,
                          // Phase-2b: a .none center is a normal cell, so show the
                          // "+" affordance for the positional center too when empty.
                          (!isCenter || b.centerSquareType == .none),
                          b.status == .active,
                          !isBoardLocked {
                    // M4 — Empty non-center cell (or .none center) on an ACTIVE board: dashed "+" affordance.
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

        // P2: Shared-counter marker — true for source tasks that have linked tasks
        // pointing at them, or for linked tasks with sharedCounterId set.
        let isSharedCounterCell: Bool = {
            guard let t = task, t.type == .counting else { return false }
            if t.sharedCounterId != nil { return true }
            return allTasks.contains { $0.sharedCounterId == t.id && !$0.isDeleted }
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
            isSharedCounter: isSharedCounterCell,
            compoundDoneCount: compoundDoneCount,
            compoundChildCount: compoundLinks.count,
            onTap: {
                guard !isBoardLocked, !isProcessing else { return }
                // Haptic feedback — fire immediately on tap (before async write
                // lands). Respects the Board Preferences "Haptics" toggle.
                if authService.userPreferences.haptics {
                    let generator = UIImpactFeedbackGenerator(style: .medium)
                    generator.impactOccurred()
                }
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
            if board?.status == .active, !isBoardLocked, !isPinnedCenter(boardTask: boardTask) {
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
                // No maxVal gate — overshoot is a feature (never clamp);
                // matches the cell-tap stepper + detail-sheet stepper.
                .disabled(isProcessing || isBoardLocked)
                Button("− Remove \(actionLabel)", systemImage: "minus") {
                    guard !isBoardLocked else { return }
                    handleCountingDecrement(boardTask: boardTask, task: t)
                }
                // P2: isLinkedCounter no longer disables − (decrementSharedCounter handles fan-out).
                .disabled(current == 0 || isProcessing || isBoardLocked)
                Button("View Details", systemImage: "info.circle") {
                    detailBoardTaskId = boardTask.id
                }
                Button("Open in library", systemImage: "book") {
                    taskDetailSheetTaskId = TaskIdItem(id: t.id)
                }
                if board?.status == .active, !isBoardLocked, !isPinnedCenter(boardTask: boardTask) {
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
            if board?.status == .active, !isBoardLocked, !isPinnedCenter(boardTask: boardTask) {
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
            if board?.status == .active, !isBoardLocked, !isPinnedCenter(boardTask: boardTask) {
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
            ZStack {
                RisoPaperBackground().ignoresSafeArea()
                VStack(spacing: 0) {
                    // ── Header ──
                    HStack(alignment: .top) {
                        VStack(alignment: .leading, spacing: 3) {
                            Text(task.title)
                                .font(.risoHead(18, .extraBold))
                                .foregroundStyle(Color.risoInk)
                            Text(detailTypeLabel(for: task.type))
                                .font(.risoBody(13, .semibold))
                                .foregroundStyle(Color.risoMuted)
                        }
                        Spacer(minLength: 8)
                        RisoToolbarPill(title: "Done") { detailBoardTaskId = nil }
                    }
                    .padding(.horizontal, Riso.gutter)
                    .padding(.vertical, 16)

                    ScrollView(showsIndicators: false) {
                        VStack(alignment: .leading, spacing: 16) {
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
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 24)
                    }
                }
            }
            .presentationDetents([.medium, .large])
        }
    }

    /// Card section helper for the Riso detail sheet — `.risoSectionLabel()`
    /// heading above a paper2 card. Mirrors `EditTaskSheet.risoSection`.
    @ViewBuilder
    private func detailSection<Content: View>(
        _ label: String,
        @ViewBuilder content: () -> Content
    ) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(label).risoSectionLabel()
            content()
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
                .risoCard(fill: .risoPaper2)
                .risoHardShadow(Riso.Shadow.small)
        }
    }

    /// Square Riso stepper button used by the counting detail card.
    @ViewBuilder
    private func detailStepperButton(
        system: String, enabled: Bool, action: @escaping () -> Void
    ) -> some View {
        Button(action: action) {
            Image(systemName: system)
                .font(.system(size: 18, weight: .bold))
                // Enabled glyph sits on gold — non-inverting ink for dark mode.
                .foregroundStyle(enabled ? Color.risoInkStatic : Color.risoMuted)
                .frame(width: 44, height: 44)
                .risoCard(fill: enabled ? .risoGold : .risoPaper)
        }
        .buttonStyle(RisoButtonStyle())
        .disabled(!enabled)
        .accessibilityLabel(system == "plus" ? "Increment count" : "Decrement count")
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
        detailSection("Completion") {
            Button {
                handleNormalTap(boardTask: boardTask)
                detailBoardTaskId = nil
            } label: {
                HStack(spacing: 8) {
                    Image(systemName: isCompleted ? "xmark.circle" : "checkmark.circle")
                    Text(isCompleted ? "Mark incomplete" : "Mark complete")
                }
                .font(.risoHead(15, .bold))
                .foregroundStyle(isCompleted ? Color.risoInk : Color.risoPaper)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .risoCard(fill: isCompleted ? .risoPaper2 : .risoGreen)
            }
            .buttonStyle(RisoButtonStyle())
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

        detailSection("Progress") {
            VStack(alignment: .leading, spacing: 12) {
                RisoProgressBar(
                    value: maxVal > 0 ? Double(min(current, maxVal)) / Double(maxVal) : 0,
                    color: current >= maxVal ? .risoGreen : .risoBlue
                )

                Text("\(current) / \(maxVal)\(unitText.isEmpty ? "" : " \(unitText)")")
                    .font(.risoBody(13, .semibold))
                    .foregroundStyle(Color.risoMuted)

                HStack(spacing: 16) {
                    // P2: isLinkedCounter no longer disables − (decrementSharedCounter handles fan-out).
                    detailStepperButton(
                        system: "minus",
                        enabled: current > 0 && !isProcessing && !isBoardLocked
                    ) {
                        handleCountingDecrement(boardTask: boardTask, task: task)
                    }

                    Spacer()

                    Text("\(current)")
                        .font(.risoHead(26, .extraBold))
                        .monospacedDigit()
                        .foregroundStyle(Color.risoInk)

                    Spacer()

                    detailStepperButton(
                        system: "plus",
                        // No maxVal gate — overshoot (current > maxCount) is a
                        // feature, never clamped; matches the cell-tap stepper.
                        enabled: !isProcessing && !isBoardLocked
                    ) {
                        handleCountingTap(boardTask: boardTask, task: task)
                    }
                }
            }
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

        detailSection("Children") {
            VStack(alignment: .leading, spacing: 12) {
                if links.isEmpty {
                    Text("No children found")
                        .font(.risoBody(13, .semibold))
                        .foregroundStyle(Color.risoMuted)
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

                        HStack(spacing: 10) {
                            Button {
                                guard let ct = childTask, !isBoardLocked, !isProcessing else { return }
                                handleCompoundChildToggle(childTask: ct)
                            } label: {
                                HStack(spacing: 8) {
                                    Image(systemName: isDone ? "checkmark.circle.fill" : "circle")
                                        .foregroundStyle(isDone ? Color.risoGreen : Color.risoMuted)
                                    Text(childTask?.title ?? link.childTaskId)
                                        .font(.risoBody(14, .semibold))
                                        .foregroundStyle(Color.risoInk)
                                    Spacer(minLength: 0)
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
                                    .foregroundStyle(Color.risoMuted)
                            }
                            .buttonStyle(.plain)
                            .accessibilityLabel("Open \(childTask?.title ?? "task") in library")
                        }
                    }
                }
            }
        }

        Text("Completion applies to all boards where this task appears.")
            .font(.risoBody(12, .regular))
            .foregroundStyle(Color.risoMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
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
            // Match the !isDeleted filter used by achievementBadge(for:) and
            // achievementCellIsCompleted(for:) so a soft-deleted watched board
            // doesn't show here while the cell reads as not-complete.
            let ref = allBoardsInWorkspace.first(where: { $0.id == refBoardId && !$0.isDeleted })
            detailSection("Watching board") {
                if let ref {
                    let isMet = meets(ref)
                    HStack(spacing: 8) {
                        Image(systemName: isMet ? "checkmark.circle.fill" : "circle")
                            .foregroundStyle(isMet ? Color.risoGreen : Color.risoMuted)
                        Text(ref.name)
                            .font(.risoBody(14, .semibold))
                            .foregroundStyle(Color.risoInk)
                        Spacer(minLength: 0)
                        Text(trigger == .bingo ? "Bingo" : "Greenlog")
                            .font(.risoBody(12, .bold))
                            .foregroundStyle(Color.risoMuted)
                    }
                } else {
                    Text("(referenced board unavailable)")
                        .font(.risoBody(13, .semibold))
                        .foregroundStyle(Color.risoMuted)
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
            detailSection("Watching template") {
                VStack(alignment: .leading, spacing: 6) {
                    HStack(spacing: 8) {
                        Image(systemName: "rectangle.stack")
                            .foregroundStyle(Color.risoMuted)
                        Text(template?.name ?? "(referenced template unavailable)")
                            .font(.risoBody(14, .semibold))
                            .foregroundStyle(Color.risoInk)
                        Spacer(minLength: 0)
                        // `met / required` — derivation requires metCount >=
                        // requiredCount on a non-empty in-window set, so this is
                        // the actual completion fraction.
                        Text("\(metCount) / \(required)")
                            .font(.risoHead(14, .bold))
                            .monospacedDigit()
                            .foregroundStyle(Color.risoInk)
                        Text(trigger == .bingo ? "Bingo" : "Greenlog")
                            .font(.risoBody(12, .bold))
                            .foregroundStyle(Color.risoMuted)
                    }
                    Text("\(spawns.count) in-window spawn\(spawns.count == 1 ? "" : "s")")
                        .font(.risoBody(12, .regular))
                        .foregroundStyle(Color.risoMuted)
                }
            }
        } else {
            detailSection("Achievement") {
                Text("This achievement task has no reference set.")
                    .font(.risoBody(13, .semibold))
                    .foregroundStyle(Color.risoMuted)
            }
        }

        Text("Derived from the watched target; the cell cannot be toggled directly.")
            .font(.risoBody(12, .regular))
            .foregroundStyle(Color.risoMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 4)
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
            // Resolve the source task title for the credit toast copy.
            let sourceName = taskMap[sourceId]?.title ?? task.title
            runSharedCounterIncrement(sourceTaskId: sourceId, counterName: sourceName)
            return
        }

        // (b) Source counter — check if any task in the workspace links to this task.
        let isSource = allTasks.contains { $0.sharedCounterId == task.id && !$0.isDeleted }
        if isSource {
            runSharedCounterIncrement(sourceTaskId: task.id, counterName: task.title)
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

    /// Runs the shared-counter increment in a background task, then refreshes
    /// board + task data on the main thread and fires a credit toast when
    /// the ripple reached other boards.
    ///
    /// Mirrors the pattern in `runOrchestration` (uses `_Concurrency.Task.detached`
    /// to avoid shadowing by the GRDB `Task` model).
    ///
    /// - Parameters:
    ///   - sourceTaskId: The source (template) task id to increment.
    ///   - counterName: Display name used in the credit toast copy.
    private func runSharedCounterIncrement(sourceTaskId: String, counterName: String = "") {
        guard !isProcessing else { return }
        isProcessing = true
        let currentBoardId = board?.id

        _Concurrency.Task.detached(priority: .userInitiated) {
            do {
                // Capture pre-increment board stats for flash-message comparison.
                let boardBefore: Board? = currentBoardId.flatMap { id in
                    try? AppDatabase.shared.read { db in try Board.fetchOne(db, key: id) }
                }

                let creditResult = try AppDatabase.shared.incrementSharedCounter(sourceTaskId: sourceTaskId)

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

                // P2: Build credit toast for OTHER boards that changed.
                let otherBoards = creditResult.affectedBoards.filter { $0.boardId != currentBoardId }
                let creditText: String? = otherBoards.isEmpty ? nil :
                    sharedCreditToastText(counterName: counterName, otherBoards: otherBoards, isIncrement: true)

                await MainActor.run {
                    isProcessing = false
                    viewModel.reload()
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
                    if let text = creditText {
                        triggerCreditToast(text: text)
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

    /// Runs the shared-counter decrement in a background task, then refreshes
    /// board + task data on the main thread and fires a credit toast when the
    /// ripple reached other boards.
    ///
    /// - Parameters:
    ///   - sourceTaskId: The source (template) task id to decrement.
    ///   - counterName: Display name used in the credit toast copy.
    private func runSharedCounterDecrement(sourceTaskId: String, counterName: String = "") {
        guard !isProcessing else { return }
        isProcessing = true
        let currentBoardId = board?.id

        _Concurrency.Task.detached(priority: .userInitiated) {
            do {
                let decrementResult = try AppDatabase.shared.decrementSharedCounter(sourceTaskId: sourceTaskId)
                guard decrementResult.effectiveDelta > 0 else {
                    // No-op — source was already at 0; nothing to show.
                    await MainActor.run { isProcessing = false }
                    return
                }

                // No bingo-state-change toast on decrement: the one-way task
                // latch means completion can't regress, so bingo lines can't be
                // lost via a decrement (unlike the increment path).
                let otherBoards = decrementResult.affectedBoards.filter { $0.boardId != currentBoardId }
                let creditText: String? = otherBoards.isEmpty ? nil :
                    sharedCreditToastText(counterName: counterName, otherBoards: otherBoards, isIncrement: false)

                await MainActor.run {
                    isProcessing = false
                    viewModel.reload()
                    if let text = creditText {
                        triggerCreditToast(text: text)
                    }
                }
            } catch {
                print("⚠️ BoardPlayView shared-counter decrement error: \(error)")
                await MainActor.run {
                    isProcessing = false
                }
            }
        }
    }

    /// Decrements a counting task's `currentCount` by 1.
    /// Routes shared-counter tasks (source or linked) through
    /// `runSharedCounterDecrement`; standalone tasks use the legacy orchestration.
    ///
    /// - Parameters:
    ///   - boardTask: The counting task's `BoardTask` record.
    ///   - task: The `Task` providing current state.
    private func handleCountingDecrement(boardTask: BoardTask, task: Task) {
        guard !isProcessing else { return }

        // Shared-counter path: same detection as handleCountingTap.
        if let sourceId = task.sharedCounterId {
            runSharedCounterDecrement(sourceTaskId: sourceId, counterName: task.title)
            return
        }
        let isSource = allTasks.contains { $0.sharedCounterId == task.id && !$0.isDeleted }
        if isSource {
            runSharedCounterDecrement(sourceTaskId: task.id, counterName: task.title)
            return
        }

        // Standalone counter — legacy path (un-completes, no fan-out).
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
                    viewModel.reload()
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
    /// UI is refreshed via `viewModel.reload()` on completion (the sheet's
    /// `onDismiss` also triggers a reload as a defensive belt-and-suspenders).
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
                    viewModel.reload()
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
                    viewModel.reload()
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
                    viewModel.reload()
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
                    // Full reload: board + placements + workspace task data. The
                    // task-data refresh keeps the compound detail sheet (rendered
                    // from taskMap + compoundChildrenByCompound) in sync with the
                    // latest child-toggle state without a dismiss-and-reopen.
                    viewModel.reload()
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

    // MARK: - Edit Mode

    /// Seeds all edit-draft @State vars from the live board record before
    /// entering edit mode. Called synchronously on the main actor immediately
    /// before `editMode = true` so the form shows the current board values on
    /// first render.
    ///
    /// - Parameter b: The current active `Board` from `self.board`.
    private func seedEditDraft(from b: Board) {
        editName = b.name
        editTimeframe = b.timeframe

        let cal = Calendar.current
        let fallbackStart = cal.startOfDay(for: Date())
        let fallbackEnd = cal.date(byAdding: .day, value: 30, to: fallbackStart) ?? Date()
        let seedStart = parseWizardCalendarDate(b.startDate) ?? fallbackStart
        let seedEnd: Date = {
            if let endStr = b.endDate, let parsed = parseWizardCalendarDate(endStr) { return parsed }
            return fallbackEnd
        }()
        editCustomStartDate = seedStart
        editOriginalCustomStartDate = seedStart
        editCustomEndDate = seedEnd
        editOriginalCustomEndDate = seedEnd
        editCenterType = b.centerSquareType
        editCenterCustomName = b.centerSquareCustomName ?? ""
        editSubMode = .editTasks
        editSaving = false
        editHasCandidateTasks = false

        // Phase 2 — seed the squares draft from the current live placement rows.
        // `boardTasks` is already loaded by `viewModel.reload()` on appear.
        editSquaresDraft = [:]
        for bt in boardTasks {
            let key = "\(bt.row)-\(bt.col)"
            editSquaresDraft[key] = SquaresDraftCell(
                boardTaskId: bt.id,
                row: bt.row,
                col: bt.col,
                isCenter: bt.isCenter,
                originalTaskId: bt.taskId,
                stagedTaskId: bt.taskId
            )
        }
        editTaskOverrides = [:]
        // Phase 3 — reset rearrange cells so they're rebuilt fresh on next sub-mode entry.
        editRearrangeCells = nil

        // Async: check whether the board has any center-task placement so
        // BoardEditPanel can gate the CHOSEN option in BoardSetupFormView.
        let bid = b.id
        _Concurrency.Task.detached(priority: .userInitiated) {
            let count = (try? AppDatabase.shared.fetchBoardTasks(boardId: bid).count) ?? 0
            await MainActor.run { editHasCandidateTasks = count > 0 }
        }
    }

    // MARK: - Phase 3 rearrange handlers

    /// Lazily builds `editRearrangeCells` the first time the user switches to
    /// Rearrange sub-mode. Subsequent sub-mode switches preserve the staged order.
    private func seedRearrangeCells(for b: Board) {
        guard editRearrangeCells == nil else { return }
        editRearrangeCells = buildRearrangeCells(
            squaresDraft: editSquaresDraft,
            gridSize: b.boardSize,
            centerSquareType: editCenterType
        )
    }

    /// Called by `RearrangeGrid.onReorder` when a drag-to-insert or tap-to-swap
    /// is committed. Updates the staged rearrange cells and leaves everything else
    /// in place — no DB write until Save.
    private func handleRearrange(newCells: [RearrangeCellData]) {
        editRearrangeCells = newCells
    }

    // MARK: - Phase 2 edit-mode tap-menu handlers

    /// Called by `BoardEditPanel.onCellTap` when the user taps an occupied
    /// cell in Edit-tasks sub-mode. Records the row/col and presents the
    /// Replace / Edit (+ Phase-2b center toggle) confirmationDialog.
    private func handleEditCellTap(row: Int, col: Int) {
        editCellMenuRow = row
        editCellMenuCol = col
        let mid = gridSize / 2
        editCellMenuIsCenter = gridSize % 2 == 1 && row == mid && col == mid
        editCellMenuVisible = true
    }

    /// Called by `BoardEditPanel.onCenterTap` when the user taps the FREE /
    /// CUSTOM_FREE center cell in Edit-tasks sub-mode. Shows the center-toggle
    /// confirmationDialog ("Make it a task square").
    private func handleFreeCenterTap() {
        let mid = gridSize / 2
        editCellMenuRow = mid
        editCellMenuCol = mid
        editCellMenuIsCenter = true
        editCellMenuVisible = true
    }

    /// Stages a task-ID replacement on one cell (no DB write).
    ///
    /// Called when the user picks a task from the Replace-task sheet in
    /// board-edit mode. Increments the squares draft so the panel counter
    /// and Save pill reflect this staged change.
    ///
    /// - Parameters:
    ///   - cellKey: The "row-col" key into `editSquaresDraft`.
    ///   - newTaskId: The task the user selected from `CellSwapSheet`.
    private func handleEditCellReplace(cellKey: String, newTaskId: String) {
        guard let draft = editSquaresDraft[cellKey] else { return }
        editSquaresDraft[cellKey]?.stagedTaskId = newTaskId
        // Keep an already-seeded rearrange grid in sync so a Replace made after
        // switching to Rearrange (which doesn't re-seed) shows the new task label.
        if let idx = editRearrangeCells?.firstIndex(where: { $0.id == draft.boardTaskId }) {
            let old = editRearrangeCells![idx]
            editRearrangeCells![idx] = RearrangeCellData(
                id: old.id,
                taskId: newTaskId,
                isCenter: old.isCenter,
                isEmpty: old.isEmpty,
                originalRow: old.originalRow,
                originalCol: old.originalCol
            )
        }
    }

    /// Stages task-field overrides for a global Task (no DB write).
    ///
    /// Called when the user taps Done in `SquareEditTaskSheet`. Stores the
    /// patch as a `StagedTaskOverride` keyed by `taskId`. The edit-mode draft
    /// task map picks this up immediately so the grid label updates.
    ///
    /// - Parameters:
    ///   - taskId: The global Task being edited.
    ///   - patch: Name / type / counting fields from `SquareEditTaskSheet`.
    private func handleEditTaskOverride(taskId: String, patch: SquareEditTaskSheet.Patch) {
        editTaskOverrides[taskId] = StagedTaskOverride(
            title: patch.title,
            type: patch.type,
            action: patch.action.isEmpty ? nil : patch.action,
            unit: patch.unit.isEmpty ? nil : patch.unit,
            maxCount: patch.maxCount
        )
    }

    /// Builds the metadata patch from current draft state and writes it via
    /// `updateBoardAndCascade`. On success: exits edit mode, reloads the
    /// board from GRDB, and shows a 2.4-second "Board saved" toast.
    private func handleEditSave() {
        guard !editSaving else { return }
        let trimmedName = editName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return }

        let cal = Calendar.current
        let weekStart = authService.currentUser?.decodedPreferences.weekStartDay.rawValue ?? "monday"

        func snapStart(_ d: Date) -> String {
            wizardLocalISOString(cal.startOfDay(for: d))
        }
        func snapEnd(_ d: Date) -> String {
            let nextDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: d))!
            return wizardLocalISOString(nextDay.addingTimeInterval(-0.001))
        }

        let startISO: String
        let endISO: String?
        var clearEnd = false

        if editTimeframe == .indefinite {
            startISO = wizardLocalISOString(cal.startOfDay(for: Date()))
            endISO = nil
            clearEnd = true
        } else if editTimeframe == .custom {
            startISO = snapStart(editCustomStartDate)
            let snappedEnd = snapEnd(editCustomEndDate)
            // Carry over EditBoardSheet's guard: the end-date picker's min can lag a
            // start-date change, so re-validate end >= start before persisting.
            guard snappedEnd >= startISO else { return }
            endISO = snappedEnd
        } else if let boundaries = computeTimeframeBoundaries(
            timeframe: editTimeframe,
            referenceDate: Date(),
            weekStartDay: weekStart
        ) {
            startISO = wizardLocalISOString(boundaries.start)
            endISO = wizardLocalISOString(boundaries.end)
        } else {
            return
        }

        let patch = AppDatabase.UpdateActiveBoardPatch(
            name: trimmedName,
            timeframe: editTimeframe,
            startDate: startISO,
            endDate: endISO,
            clearEndDate: clearEnd,
            centerSquareType: editCenterType,
            centerSquareCustomName: editCenterType == .customFree
                ? (editCenterCustomName.trimmingCharacters(in: .whitespaces).isEmpty
                    ? nil
                    : editCenterCustomName.trimmingCharacters(in: .whitespaces))
                : nil
        )

        // Phase 2 — snapshot squares draft before entering the detached task.
        // `@State` vars are only safe on the MainActor; capture copies as
        // value types so the detached task has stable, sendable data.
        let cellReplacements: [(boardTaskId: String, newTaskId: String)] =
            editSquaresDraft.values
                .filter { $0.stagedTaskId != $0.originalTaskId }
                .map { (boardTaskId: $0.boardTaskId, newTaskId: $0.stagedTaskId) }

        // Build (task, override) pairs from the live taskMap + staged overrides.
        // De-duplicated by taskId so each global Task is saved at most once.
        var taskOverridePairs: [(task: Task, override: StagedTaskOverride)] = []
        for (taskId, override) in editTaskOverrides {
            if let task = taskMap[taskId] {
                taskOverridePairs.append((task: task, override: override))
            }
        }

        // Phase 3 — snapshot staged position moves.
        // Compare each cell's slot in `editRearrangeCells` to its originalRow/Col.
        // Center and empty slots are excluded (they don't correspond to BoardTask rows).
        let positionMoves: [(boardTaskId: String, row: Int, col: Int)] = {
            guard let rearranged = editRearrangeCells, gridSize > 0 else { return [] }
            var moves: [(boardTaskId: String, row: Int, col: Int)] = []
            for (slotIdx, cell) in rearranged.enumerated() {
                guard !cell.isCenter, !cell.isEmpty else { continue }
                let stagedRow = slotIdx / gridSize
                let stagedCol = slotIdx % gridSize
                if stagedRow != cell.originalRow || stagedCol != cell.originalCol {
                    moves.append((boardTaskId: cell.id, row: stagedRow, col: stagedCol))
                }
            }
            return moves
        }()

        editSaving = true
        let bid = boardId
        _Concurrency.Task.detached(priority: .userInitiated) {
            do {
                // 1. Metadata patch (name / timeframe / center).
                try AppDatabase.shared.updateBoardAndCascade(boardId: bid, patch: patch)

                // 2. Staged cell replacements — each repoints one BoardTask row
                //    and re-derives board stats for the old + new task contexts.
                for replacement in cellReplacements {
                    try AppDatabase.shared.updateBoardTaskAndCascade(
                        boardTaskId: replacement.boardTaskId,
                        newTaskId: replacement.newTaskId
                    )
                }

                // 3. Staged task-field overrides — each writes the global Task
                //    and re-derives board stats for all boards the task is on.
                let now = AppDatabase.currentTimestamp()
                for (task, override) in taskOverridePairs {
                    var updated = task
                    updated.title = override.title
                    updated.type  = override.type
                    switch override.type {
                    case .counting:
                        // action can be cleared (nil) — assign unconditionally so the
                        // commit matches the draft grid (which clears it on blank).
                        updated.action = override.action
                        if let u = override.unit   { updated.unit   = u }
                        if let m = override.maxCount { updated.maxCount = m }
                    case .normal:
                        // Switching from Counting → Simple: clear counting fields.
                        if task.type == .counting {
                            updated.action   = nil
                            updated.unit     = nil
                            updated.maxCount = nil
                        }
                    default:
                        break
                    }
                    updated.updatedAt = now
                    updated.version  += 1
                    try AppDatabase.shared.saveTaskAndCascade(updated)
                }

                // 4. Phase 3 — Staged position moves: rewrite row/col on moved BoardTask rows
                //    in a single atomic transaction, then re-derive bingo lines for this board.
                if !positionMoves.isEmpty {
                    try AppDatabase.shared.updateBoardTaskPositions(
                        boardId: bid,
                        moves: positionMoves.map {
                            AppDatabase.BoardTaskPositionMove(
                                boardTaskId: $0.boardTaskId,
                                row: $0.row,
                                col: $0.col
                            )
                        }
                    )
                }

                await MainActor.run {
                    editSaving = false
                    withAnimation(.easeInOut(duration: 0.22)) { editMode = false }
                    viewModel.reload()
                    triggerBoardSavedToast()
                }
            } catch {
                print("⚠️ BoardPlayView.handleEditSave: \(error)")
                await MainActor.run {
                    editSaving = false
                    editSaveError = "Couldn’t save your changes — please try again."
                }
            }
        }
    }

    /// Archives the board by setting `status = .archived` in GRDB, then
    /// dismisses `BoardPlayView` back to the Boards list.
    ///
    /// The archive confirm alert in `BoardEditPanel` calls this callback only
    /// after the user confirms — no further confirmation required here.
    private func handleEditArchive() {
        let bid = boardId
        _Concurrency.Task.detached(priority: .userInitiated) {
            do {
                try AppDatabase.shared.archiveBoard(id: bid)
                // Only leave the board if the archive actually committed.
                await MainActor.run {
                    withAnimation(.easeInOut(duration: 0.22)) { editMode = false }
                    dismiss()
                }
            } catch {
                print("⚠️ BoardPlayView.handleEditArchive: \(error)")
                await MainActor.run {
                    bingoMessage = "Archive failed — please try again."
                }
            }
        }
    }

    /// Flashes the "Board saved" success toast for 2.4 s, then hides it.
    /// Safe to call multiple times — the latest invocation wins.
    private func triggerBoardSavedToast() {
        withAnimation(.easeOut(duration: 0.2)) { showEditSavedToast = true }
        _Concurrency.Task { @MainActor in
            try? await _Concurrency.Task.sleep(nanoseconds: 2_400_000_000)
            withAnimation(.easeOut(duration: 0.2)) { showEditSavedToast = false }
        }
    }

    // MARK: - Data Loading
    //
    // The board / placements / workspace-task loaders moved to
    // `BoardPlayViewModel` (B2-I1). Call sites now use `viewModel.reload()`
    // (full) or `viewModel.reloadBoardTasksAndTaskData()` (placements + task
    // data, board unchanged).
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
