import Foundation
import GRDB

/// Owns the data-loading layer for `BoardPlayView`.
///
/// Moved out of the view in the B2-I1 slice: the seven pieces of state the
/// play surface reads from the local GRDB database (the board record, its
/// placements, and the workspace-wide task/compound/board/template context
/// used by the achievement-config sheet + per-cell badge computation) now
/// live here as `@Published private(set)` state, refreshed by `reload()`.
///
/// House style mirrors `CoreBoardWindowViewModel` in this directory:
/// `@MainActor final class … : ObservableObject`, background dispatch +
/// main-queue apply, and a monotonic `reloadToken` stale-result guard.
///
/// ### Stale-result guard (the one deliberate improvement in this slice)
/// The pre-refactor view fired three independent detached tasks
/// (`loadBoard` / `loadBoardTasks` / `loadTaskData`) that could interleave
/// — a slow earlier read could clobber a newer one's result. `reload()`
/// folds all fetches into ONE background hop and captures a monotonic
/// token; the main-queue apply is dropped if a newer reload has since been
/// requested. So the newest reload always wins.
///
/// ### DB injection
/// `init` takes an `AppDatabase` with a `.shared` default so the view keeps
/// using the production singleton while unit tests can inject a
/// `makeTestInstance()`.
@MainActor
final class BoardPlayViewModel: ObservableObject {

    // MARK: - Published state

    /// The board record for `boardId`, or nil if not (yet) loaded / missing.
    @Published private(set) var board: Board?
    /// Placements for the current board.
    @Published private(set) var boardTasks: [BoardTask] = []
    /// All of the user's tasks (feeds `taskMap`, compound detail sheets,
    /// candidate pickers).
    @Published private(set) var allTasks: [Task] = []
    /// All compound-child links (global, not user-scoped — the DB helper
    /// doesn't filter by userId for that table).
    @Published private(set) var allCompoundChildren: [CompoundChild] = []
    // Phase 6.3 — workspace-wide boards + templates + placements feed both
    // the achievement-square config sheet (pickers) and the per-cell badge
    // data computation. Refreshed alongside the task data so the sheet
    // always sees up-to-date data when opened.
    @Published private(set) var allBoardsInWorkspace: [Board] = []
    @Published private(set) var allTemplatesInWorkspace: [RecurringBoardTemplate] = []
    @Published private(set) var allBoardTasksInWorkspace: [BoardTask] = []

    // MARK: - Interaction state (B2-I2)

    /// True while an interaction write (tap / stepper / swap / add / remove) is
    /// in flight. The view reads this to disable controls; only the moved
    /// interaction handlers mutate it, hence `private(set)`.
    @Published private(set) var isProcessing = false
    /// Transient flash-message string set by the interaction write tails. It is
    /// not rendered directly (the Riso visual layer owns the on-screen banner
    /// via `flashEvent`); it carries the message the view passes to
    /// `triggerRisoNotification(from:)` and backs the auto-dismiss dedup.
    /// Publicly settable because a couple of view-resident handlers (e.g.
    /// archive-failed) also surface an error string through it.
    @Published var bingoMessage: String?
    /// One-shot UI-effect signal (see `BoardPlayFlashEvent`). The view observes
    /// this via `.onChange` and fires its `triggerRisoNotification(from:)` /
    /// `triggerCreditToast(text:)` animations. `private(set)` — only
    /// `emitFlash` publishes it.
    @Published private(set) var flashEvent: BoardPlayFlashEvent?

    /// Monotonic counter backing `flashEvent.id` so each emission is a distinct
    /// `Equatable` value even when the flash copy repeats (rapid identical
    /// bingos each still trigger the view's `.onChange`).
    private var flashEventCounter = 0

    // MARK: - Edit-mode draft state (B2-I3)
    //
    // The in-place `BoardEditPanel` draft layer, moved verbatim out of
    // `BoardPlayView` in the B2-I3 slice. These are the fields the panel binds
    // two-way (`$viewModel.editName`, …) plus the staged-square dictionaries the
    // Edit-tasks / Rearrange sub-modes mutate. Nothing here is written to the DB
    // until `handleEditSave` commits; the panel is a pure staged-draft surface.
    //
    // They are `@Published var` (NOT `private(set)`) precisely because the panel
    // writes several of them through projected bindings — `@StateObject`
    // projections are two-way, so `$viewModel.editName` behaves exactly like the
    // pre-move `$editName` `@State` binding did.

    /// Draft board name input.
    @Published var editName: String = ""
    /// Draft timeframe segmented picker value.
    @Published var editTimeframe: Timeframe = .monthly
    /// Draft custom start-date picker value.
    @Published var editCustomStartDate: Date = Date()
    /// Draft custom end-date picker value.
    @Published var editCustomEndDate: Date = Date()
    /// Original parsed start date seeded from `board.startDate` — used by the
    /// `BoardEditPanel` dirty-check comparison.
    @Published var editOriginalCustomStartDate: Date = Date()
    /// Original parsed end date seeded from `board.endDate` — used by the
    /// `BoardEditPanel` dirty-check comparison.
    @Published var editOriginalCustomEndDate: Date = Date()
    /// Draft center-square type selector value.
    @Published var editCenterType: CenterSquareType = .free
    /// Draft custom center name input (only relevant when `editCenterType == .customFree`).
    @Published var editCenterCustomName: String = ""
    /// True when the board already has a center-task placement (gates CHOSEN option).
    /// Loaded asynchronously by `seedEditDraft(from:)`.
    @Published var editHasCandidateTasks: Bool = false
    /// Which squares sub-mode (Edit tasks / Rearrange) is active.
    @Published var editSubMode: BoardEditSubMode = .editTasks
    /// Per-cell staged state keyed by "row-col". Seeded from live `BoardTask`
    /// rows when the user enters edit mode; modified by Replace / Edit-task
    /// actions. Nothing is written to the DB until `handleEditSave` commits.
    @Published var editSquaresDraft: [String: SquaresDraftCell] = [:]
    /// Staged task-field overrides keyed by taskId (global — shared by all
    /// squares that reference the same task). Applied to `editDraftTaskMap` for
    /// rendering and committed via `saveTaskAndCascade` in `handleEditSave`.
    @Published var editTaskOverrides: [String: StagedTaskOverride] = [:]
    /// Phase 3 — Rearrange sub-mode staged state. Ordered `[RearrangeCellData]`
    /// shown by `RearrangeGrid`. nil until the user first enters Rearrange
    /// sub-mode (built lazily by `seedRearrangeCells`).
    @Published var editRearrangeCells: [RearrangeCellData]? = nil

    /// One-shot edit-commit signal (see `BoardPlayEditEvent`). The view observes
    /// this via `.onChange` and runs the residual UI mutations it still owns —
    /// `editSaving` / `editMode` / `editSaveError` / the "Board saved" toast /
    /// `dismiss()` — which read view `@State` / the `dismiss` environment and so
    /// can't move. `private(set)` — only `emitEdit` publishes it. Mirrors the
    /// `flashEvent` one-shot pattern (monotonic id + `Equatable`).
    @Published private(set) var editEvent: BoardPlayEditEvent?

    /// Monotonic counter backing `editEvent.id` so consecutive emissions are
    /// distinct `Equatable` values for the view's `.onChange`.
    private var editEventCounter = 0

    /// True while a `handleEditSave` commit is in flight. The VM's own re-entry
    /// guard (the view's `editSaving` `@State` is a UI mirror driven by
    /// `handleEditSave`'s return value + `editEvent`, but the authoritative
    /// double-save guard lives here so it can't race the published UI mirror).
    private var editSaveInFlight = false

    /// O(1) task lookup by task id over the loaded `allTasks`. Feeds the moved
    /// tap handlers; the view delegates its own `taskMap` here.
    var taskMap: [String: Task] {
        Dictionary(uniqueKeysWithValues: allTasks.map { ($0.id, $0) })
    }

    /// Grid column count from the board's `boardSize`, defaulting to 3. Mirrors
    /// the view's `gridSize`; used by the moved edit-draft computed helpers.
    private var gridSize: Int { board?.boardSize ?? 3 }

    // MARK: - Edit-mode draft derived helpers (B2-I3)
    //
    // Moved from `BoardPlayView` as computed vars. The pre-move versions each
    // opened with `guard editMode, …` — but `editMode` stays view-side, and the
    // guard is redundant at the sole render site (the `if editMode` panel
    // overlay) because the draft-state guards below already return the base
    // value right after `seedEditDraft` (staged == original ⇒ no overlay,
    // empty overrides ⇒ base map, nil rearrange ⇒ zero moves). Dropping
    // `editMode` therefore leaves the *rendered* result byte-identical while
    // making these unit-testable (a test can seed a draft and read the count
    // without a live view). See the B2-I3 report for the full analysis.

    /// Live `BoardTask` rows with staged task-ID replacements applied. Used as
    /// `boardTasks:` in `BoardEditPanel` so the draft grid shows the staged
    /// tasks without touching the database.
    var editDraftBoardTasks: [BoardTask] {
        guard !editSquaresDraft.isEmpty else { return boardTasks }
        return boardTasks.map { bt in
            let key = "\(bt.row)-\(bt.col)"
            guard let draft = editSquaresDraft[key],
                  draft.stagedTaskId != bt.taskId else { return bt }
            var copy = bt
            copy.taskId = draft.stagedTaskId
            return copy
        }
    }

    /// `taskMap` with staged task-field overrides applied. Used as `taskMap:` in
    /// `BoardEditPanel` so cell labels show the staged title/type without a
    /// database write.
    var editDraftTaskMap: [String: Task] {
        guard !editTaskOverrides.isEmpty else { return taskMap }
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
    /// position moves (from Rearrange sub-mode). Forwarded to
    /// `BoardEditPanel.squareEditCount` so the counter + Save pill react to
    /// square-level changes, not just metadata changes.
    ///
    /// Position moves are DERIVED: a drag that returns a cell to its original
    /// slot is net-zero and does not inflate the counter.
    var editSquaresEditCount: Int {
        let replacements = editSquaresDraft.values
            .filter { $0.stagedTaskId != $0.originalTaskId }.count
        let overrides = editTaskOverrides.count
        let positionMoves = countPositionMoves(in: editRearrangeCells, gridSize: gridSize)
        return replacements + overrides + positionMoves
    }

    /// Returns the number of task cells that are in a different grid slot from
    /// their `originalRow`/`originalCol`. Center and empty slots are excluded.
    func countPositionMoves(in cells: [RearrangeCellData]?, gridSize: Int) -> Int {
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

    // MARK: - Config

    /// The board this view model loads. Mutable so the embedded core-board
    /// pager can point the same (reused) view model at a new board via
    /// `boardChanged(to:)` without recreating it.
    private(set) var boardId: String
    /// The authenticated user's id. Set at init for tests; the view supplies
    /// it in `.onAppear` via `setUserId` because its `@EnvironmentObject`
    /// `AuthService` isn't available in a SwiftUI `init`.
    private var userId: String?
    private let database: AppDatabase

    // MARK: - Stale-result guard

    /// Monotonically-increasing token incremented on every reload call. Each
    /// in-flight background fetch captures the token at dispatch and only
    /// applies its result if `reloadToken` still matches when it completes on
    /// the main queue — so a slower earlier fetch can't overwrite a newer
    /// reload's result. Mirrors the identical pattern in
    /// `CoreBoardWindowViewModel` / `CoreBoardBrowserViewModel`.
    private var reloadToken: Int = 0

    // MARK: - Init

    /// - Parameters:
    ///   - boardId: The board to load.
    ///   - userId: The authenticated user's id (nilable: the view constructs
    ///     the view model in its `init`, where the `@EnvironmentObject`
    ///     `AuthService` is not yet available, so it passes nil here and
    ///     supplies the real id in `.onAppear` via `setUserId`). Tests pass a
    ///     real id at init. When nil, the user-scoped fetches (tasks /
    ///     workspace boards / templates) resolve to empty arrays, matching
    ///     the pre-refactor `loadTaskData` behavior.
    ///   - database: Injected for tests; defaults to the production singleton.
    init(boardId: String, userId: String?, database: AppDatabase = .shared) {
        self.boardId = boardId
        self.userId = userId
        self.database = database
    }

    /// Supply the authenticated user's id. Called by the view in `.onAppear`
    /// (where its `@EnvironmentObject` is available). Does not trigger a
    /// reload — the caller reloads immediately after.
    func setUserId(_ userId: String?) {
        self.userId = userId
    }

    // MARK: - Actions

    /// Full reload: the board record, its placements, and the workspace-wide
    /// task/compound/board/template context — all in one background hop,
    /// applied atomically on the main queue under the stale-result guard.
    ///
    /// Replaces the pre-refactor `loadBoard()` + `loadBoardTasks()` +
    /// `loadTaskData()` trio. Every site that called all three now calls
    /// this; the two dismiss handlers that called only the latter two use
    /// `reloadBoardTasksAndTaskData()` instead to preserve their scope.
    func reload() {
        reloadToken += 1
        let token = reloadToken
        let boardId = self.boardId
        let userId = self.userId
        let database = self.database

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let board = try? database.fetchBoard(id: boardId)
            let payload = Self.fetchTaskData(boardId: boardId, userId: userId, database: database)
            DispatchQueue.main.async {
                guard token == self.reloadToken else { return }
                self.board = board
                self.apply(payload)
            }
        }
    }

    /// Partial reload used by sheet-dismiss handlers that did NOT change the
    /// board record itself (the M3 swap sheet + the M4 add-to-cell cancel
    /// path): refreshes placements + task/compound + workspace data, but not
    /// `board`. Preserves the pre-refactor sites that called
    /// `loadBoardTasks()` + `loadTaskData()` without `loadBoard()`.
    func reloadBoardTasksAndTaskData() {
        reloadToken += 1
        let token = reloadToken
        let boardId = self.boardId
        let userId = self.userId
        let database = self.database

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let payload = Self.fetchTaskData(boardId: boardId, userId: userId, database: database)
            DispatchQueue.main.async {
                guard token == self.reloadToken else { return }
                self.apply(payload)
            }
        }
    }

    /// Point the view model at a new board and reload. Used by the view's
    /// `.onChange(of: boardId)` so the embedded core-board pager — which
    /// swaps the board id on the SAME (reused) `BoardPlayView` instance,
    /// without a `.id()` modifier to force a fresh view identity — refreshes
    /// correctly. In the standalone route the `.id(boardId)` on the
    /// navigation destination recreates the view (and this view model) per
    /// board, so this path is the defensive one for the reuse case.
    func boardChanged(to newBoardId: String) {
        boardId = newBoardId
        reload()
    }

    // MARK: - Interaction handlers (B2-I2)
    //
    // The play-interaction WRITE layer, moved verbatim out of `BoardPlayView`
    // in the B2-I2 slice. Each handler mutates the local DB (via the injected
    // `database`) and applies the reload + `@Published` state mutation back on
    // the main actor. The residual view-side animation triggers
    // (`triggerRisoNotification(from:)` / `triggerCreditToast(text:)`) — which
    // read view `@State`/`AuthService` and can't move — are surfaced via the
    // one-shot `flashEvent` the view observes.
    //
    // The one behavior-preserving substitution vs the pre-move bodies: the
    // handlers write through the injected `database` instead of
    // `AppDatabase.shared` directly (mirroring I1's DB injection) so the write
    // paths are unit-testable. In production the view builds the view model
    // with the `.shared` default, so the runtime target is identical.
    // Static helpers (`AppDatabase.currentTimestamp()` / `.generateUUID()`)
    // stay as-is.

    /// Toggles completion of a normal task square and runs the full bingo orchestration.
    ///
    /// - Parameter boardTask: The tapped `BoardTask`.
    func handleNormalTap(boardTask: BoardTask) {
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
    /// All shared-counter paths go through `incrementSharedCounter`, which
    /// enforces the overshoot (no high-end clamp) and one-way-latch invariants
    /// inside a single GRDB write transaction.
    ///
    /// - Parameters:
    ///   - boardTask: The counting task's `BoardTask` record.
    ///   - task: The `Task` providing `maxCount` and shared-counter fields.
    func handleCountingTap(boardTask: BoardTask, task: Task) {
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
        let database = self.database

        _Concurrency.Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            do {
                // Capture pre-increment board stats for flash-message comparison.
                let boardBefore: Board? = currentBoardId.flatMap { id in
                    try? database.read { db in try Board.fetchOne(db, key: id) }
                }

                let creditResult = try database.incrementSharedCounter(sourceTaskId: sourceTaskId)

                // Re-fetch the board after the write to detect bingo/greenlog changes.
                let boardAfter: Board? = currentBoardId.flatMap { id in
                    try? database.read { db in try Board.fetchOne(db, key: id) }
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
                    self.sharedCreditToastText(counterName: counterName, otherBoards: otherBoards, isIncrement: true)

                await MainActor.run {
                    self.isProcessing = false
                    self.reload()
                    if let msg = newBingoMsg {
                        self.bingoMessage = msg
                        self.scheduleBingoMessageDismiss(msg)
                    }
                    self.emitFlash(risoNotification: newBingoMsg, creditToast: creditText)
                }
            } catch {
                print("⚠️ BoardPlayView shared-counter increment error: \(error)")
                await MainActor.run {
                    self.isProcessing = false
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
        let database = self.database

        _Concurrency.Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            do {
                let decrementResult = try database.decrementSharedCounter(sourceTaskId: sourceTaskId)
                guard decrementResult.effectiveDelta > 0 else {
                    // No-op — source was already at 0; nothing to show.
                    await MainActor.run { self.isProcessing = false }
                    return
                }

                // No bingo-state-change toast on decrement: the one-way task
                // latch means completion can't regress, so bingo lines can't be
                // lost via a decrement (unlike the increment path).
                let otherBoards = decrementResult.affectedBoards.filter { $0.boardId != currentBoardId }
                let creditText: String? = otherBoards.isEmpty ? nil :
                    self.sharedCreditToastText(counterName: counterName, otherBoards: otherBoards, isIncrement: false)

                await MainActor.run {
                    self.isProcessing = false
                    self.reload()
                    self.emitFlash(risoNotification: nil, creditToast: creditText)
                }
            } catch {
                print("⚠️ BoardPlayView shared-counter decrement error: \(error)")
                await MainActor.run {
                    self.isProcessing = false
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
    func handleCountingDecrement(boardTask: BoardTask, task: Task) {
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
    func handleCompoundChildToggle(childTask: Task) {
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
        let database = self.database
        _Concurrency.Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            do {
                var newBingoMsg: String? = nil
                try database.write { db in
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
                    self.isProcessing = false
                    self.reload()
                    if let msg = newBingoMsg {
                        self.bingoMessage = msg
                        self.scheduleBingoMessageDismiss(msg)
                    }
                    self.emitFlash(risoNotification: newBingoMsg, creditToast: nil)
                }
            } catch {
                print("⚠️ BoardPlayView compoundChildToggle error: \(error)")
                await MainActor.run {
                    self.isProcessing = false
                }
            }
        }
    }

    /// Swap the task occupying a non-center square to a different task from the library.
    ///
    /// Delegates to `updateBoardTaskAndCascade`, which:
    ///   1. Patches `BoardTask.taskId` atomically (version bump + sync enqueue).
    ///   2. Computes the union of boards affected by the OLD and NEW task.
    ///   3. Re-derives stats + GREENLOG transitions for each affected board.
    ///
    /// The swap runs on a detached `_Concurrency.Task` to avoid blocking the main thread.
    /// UI is refreshed via `reload()` on completion (the sheet's `onDismiss`
    /// also triggers a reload as a defensive belt-and-suspenders).
    ///
    /// - Parameters:
    ///   - boardTaskId: The `BoardTask.id` whose cell is being swapped.
    ///   - newTaskId: The replacement `Task.id`.
    func handleCellSwap(boardTaskId: String, newTaskId: String) {
        isProcessing = true
        let database = self.database
        _Concurrency.Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            do {
                try database.updateBoardTaskAndCascade(
                    boardTaskId: boardTaskId,
                    newTaskId: newTaskId
                )
                await MainActor.run {
                    self.isProcessing = false
                    self.reload()
                }
            } catch {
                print("⚠️ BoardPlayView cell swap error: \(error)")
                await MainActor.run {
                    self.isProcessing = false
                    self.bingoMessage = "Swap failed — please try again"
                }
            }
        }
    }

    /// Remove a task placement from the current board.
    ///
    /// Delegates to `removeBoardTaskFromBoard`, which hard-deletes the
    /// `BoardTask` row, enqueues a DELETE sync tombstone, and re-derives stats
    /// for every board affected by the removed task. The underlying `Task` is
    /// untouched.
    ///
    /// - Parameter boardTaskId: The `BoardTask.id` to remove.
    func handleRemoveFromBoard(boardTaskId: String) {
        isProcessing = true
        let database = self.database
        _Concurrency.Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            do {
                try database.removeBoardTaskFromBoard(boardTaskId)
                await MainActor.run {
                    self.isProcessing = false
                    self.reload()
                }
            } catch {
                print("⚠️ BoardPlayView remove-from-board error: \(error)")
                await MainActor.run {
                    self.isProcessing = false
                    self.bingoMessage = "Remove failed — please try again"
                }
            }
        }
    }

    /// Add a task to an empty cell on the current board.
    ///
    /// Delegates to `addBoardTaskToBoard`, which creates a new `BoardTask`
    /// placement, enqueues a CREATE sync entry, and re-derives stats for every
    /// board affected by the placed task. If the task is already globally
    /// completed, the cascade immediately credits this cell as completed.
    ///
    /// - Parameters:
    ///   - taskId: The `Task.id` to place.
    ///   - row: 0-based grid row.
    ///   - col: 0-based grid column.
    func handleAddTaskToCell(taskId: String, row: Int, col: Int) {
        guard let b = board else { return }
        isProcessing = true
        let database = self.database
        _Concurrency.Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            do {
                try database.addBoardTaskToBoard(
                    b.id,
                    taskId: taskId,
                    position: (row: row, col: col)
                )
                await MainActor.run {
                    self.isProcessing = false
                    self.reload()
                }
            } catch {
                print("⚠️ BoardPlayView add-to-cell error: \(error)")
                await MainActor.run {
                    self.isProcessing = false
                    self.bingoMessage = "Add failed — please try again"
                }
            }
        }
    }

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
        let database = self.database

        _Concurrency.Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            do {
                var newBingoMsg: String? = nil

                try database.write { db in
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
                    self.isProcessing = false
                    // Full reload: board + placements + workspace task data. The
                    // task-data refresh keeps the compound detail sheet (rendered
                    // from taskMap + compoundChildrenByCompound) in sync with the
                    // latest child-toggle state without a dismiss-and-reopen.
                    self.reload()
                    if let msg = newBingoMsg {
                        self.bingoMessage = msg
                        self.scheduleBingoMessageDismiss(msg)
                    }
                    self.emitFlash(risoNotification: newBingoMsg, creditToast: nil)
                }
            } catch {
                print("⚠️ BoardPlayView orchestration error: \(error)")
                await MainActor.run {
                    self.isProcessing = false
                    self.bingoMessage = "Error: \(error.localizedDescription)"
                }
            }
        }
    }

    // MARK: - Flash + credit-toast helpers (B2-I2)

    /// Builds the credit toast copy for an increment or decrement.
    ///
    /// Increment: `"{name} logged — also counted on {A}, {B}."`
    /// Decrement:  `"{name} removed — also taken off {A}, {B}."`
    ///
    /// Pure (reads only its parameters) so it is `nonisolated` — the shared-
    /// counter handlers build the copy on their background task before hopping
    /// to the main actor.
    ///
    /// - Parameters:
    ///   - counterName: The counter's display name (source task title).
    ///   - otherBoards: Boards OTHER than the current board that were credited.
    ///   - isIncrement: `true` for increment, `false` for decrement.
    private nonisolated func sharedCreditToastText(
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

    /// Publishes a one-shot `flashEvent` the view observes to fire its
    /// `triggerRisoNotification(from:)` / `triggerCreditToast(text:)`
    /// animations. No-op when both payloads are nil.
    private func emitFlash(risoNotification: String?, creditToast: String?) {
        guard risoNotification != nil || creditToast != nil else { return }
        flashEventCounter += 1
        flashEvent = BoardPlayFlashEvent(
            id: flashEventCounter,
            risoNotification: risoNotification,
            creditToast: creditToast
        )
    }

    /// Auto-dismisses the transient `bingoMessage` after ~3s, but only if a
    /// newer message hasn't replaced it (mirrors the pre-move dedup guard).
    /// Uses `DispatchQueue.main.asyncAfter` per this view model's style.
    private func scheduleBingoMessageDismiss(_ message: String) {
        DispatchQueue.main.asyncAfter(deadline: .now() + 3.0) { [weak self] in
            guard let self = self else { return }
            if self.bingoMessage == message { self.bingoMessage = nil }
        }
    }

    // MARK: - Edit-mode draft mutators + commit (B2-I3)
    //
    // Moved verbatim from `BoardPlayView`. The pure staged-draft mutators
    // (`seedRearrangeCells` / `handleRearrange` / `handleEditCellReplace` /
    // `handleEditTaskOverride`) only touch the `@Published` draft fields. The
    // DB-touching functions (`seedEditDraft` / `handleEditSave` /
    // `handleEditArchive`) write through the injected `database` (I2's
    // precedent) and signal the residual view-owned UI mutations back through
    // the one-shot `editEvent`.
    //
    // NOT moved (they stay in the view because they touch view-owned state):
    //  - `handleEditCellTap` / `handleFreeCenterTap` mutate the edit-cell-menu
    //    routing `@State` (`editCellMenuRow/Col/Visible/IsCenter`), which stays.
    //  - the two `.onChange(of: editSubMode/editCenterType)` reactions stay as
    //    view `.onChange` observers (they call `seedRearrangeCells` / rebuild
    //    `editRearrangeCells`) to preserve SwiftUI's post-update onChange timing
    //    exactly — a `didSet` on the published var would fire synchronously
    //    before the re-render, a subtle behavior change. See the B2-I3 report.

    /// Seeds all edit-draft fields from the live board record before entering
    /// edit mode. Called synchronously on the main actor immediately before the
    /// view flips `editMode = true` so the form shows the current board values on
    /// first render.
    ///
    /// The pre-move version also reset the view's `editSaving = false`; that
    /// stays view-side (the Edit button resets it), since `editSaving` is a view
    /// `@State`.
    ///
    /// - Parameter b: The current active `Board`.
    func seedEditDraft(from b: Board) {
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
        editHasCandidateTasks = false

        // Phase 2 — seed the squares draft from the current live placement rows.
        // `boardTasks` is already loaded by `reload()` on appear.
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
        // Phase 3 — reset rearrange cells so they're rebuilt fresh on next entry.
        editRearrangeCells = nil

        // Async: check whether the board has any center-task placement so
        // BoardEditPanel can gate the CHOSEN option in BoardSetupFormView.
        let bid = b.id
        let database = self.database
        _Concurrency.Task.detached(priority: .userInitiated) { [weak self] in
            let count = (try? database.fetchBoardTasks(boardId: bid).count) ?? 0
            await MainActor.run { self?.editHasCandidateTasks = count > 0 }
        }
    }

    /// Lazily builds `editRearrangeCells` the first time the user switches to
    /// Rearrange sub-mode. Subsequent sub-mode switches preserve the staged order.
    func seedRearrangeCells(for b: Board) {
        guard editRearrangeCells == nil else { return }
        editRearrangeCells = buildRearrangeCells(
            squaresDraft: editSquaresDraft,
            gridSize: b.boardSize,
            centerSquareType: editCenterType
        )
    }

    /// Called by `RearrangeGrid.onReorder` when a drag-to-insert or tap-to-swap
    /// is committed. Updates the staged rearrange cells — no DB write until Save.
    func handleRearrange(newCells: [RearrangeCellData]) {
        editRearrangeCells = newCells
    }

    /// Stages a task-ID replacement on one cell (no DB write). Increments the
    /// squares draft so the panel counter + Save pill reflect this staged change.
    ///
    /// - Parameters:
    ///   - cellKey: The "row-col" key into `editSquaresDraft`.
    ///   - newTaskId: The task the user selected from `CellSwapSheet`.
    func handleEditCellReplace(cellKey: String, newTaskId: String) {
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

    /// Stages task-field overrides for a global Task (no DB write). The
    /// edit-mode draft task map picks this up immediately so the grid label
    /// updates.
    ///
    /// - Parameters:
    ///   - taskId: The global Task being edited.
    ///   - patch: Name / type / counting fields from `SquareEditTaskSheet`.
    func handleEditTaskOverride(taskId: String, patch: SquareEditTaskSheet.Patch) {
        editTaskOverrides[taskId] = StagedTaskOverride(
            title: patch.title,
            type: patch.type,
            action: patch.action.isEmpty ? nil : patch.action,
            unit: patch.unit.isEmpty ? nil : patch.unit,
            maxCount: patch.maxCount
        )
    }

    /// Builds the metadata patch + staged square/override/position commits from
    /// the current draft state and writes them via the injected `database`. On
    /// success it reloads the board and emits `editEvent(.saved)`; on failure it
    /// emits `editEvent(.saveFailed)`.
    ///
    /// The pre-move version set the view's `editSaving = true` synchronously
    /// after validation passed. To preserve that exact timing while keeping
    /// `editSaving` view-side, this returns `true` iff the commit was actually
    /// dispatched (validation passed + not re-entrant) so the view flips
    /// `editSaving = true` in the same synchronous tick; `editEvent` drives the
    /// reset. The authoritative double-save guard is `editSaveInFlight` here.
    ///
    /// - Parameter weekStartDay: The user's week-start (`"monday"` etc.) — an
    ///   `AuthService`-sourced value the view passes in, since the VM has no env.
    /// - Returns: `true` if the DB commit was dispatched (view should show the
    ///   saving state); `false` if validation failed or a save is already in
    ///   flight (view leaves `editSaving` untouched).
    @discardableResult
    func handleEditSave(weekStartDay: String) -> Bool {
        guard !editSaveInFlight else { return false }
        let trimmedName = editName.trimmingCharacters(in: .whitespaces)
        guard !trimmedName.isEmpty else { return false }

        let cal = Calendar.current

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
            guard snappedEnd >= startISO else { return false }
            endISO = snappedEnd
        } else if let boundaries = computeTimeframeBoundaries(
            timeframe: editTimeframe,
            referenceDate: Date(),
            weekStartDay: weekStartDay
        ) {
            startISO = wizardLocalISOString(boundaries.start)
            endISO = wizardLocalISOString(boundaries.end)
        } else {
            return false
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

        // Snapshot the staged square edits as value types before the detached
        // task (the `@Published` dictionaries are only safe on the MainActor).
        let cellReplacements: [(boardTaskId: String, newTaskId: String)] =
            editSquaresDraft.values
                .filter { $0.stagedTaskId != $0.originalTaskId }
                .map { (boardTaskId: $0.boardTaskId, newTaskId: $0.stagedTaskId) }

        // Build (task, override) pairs from the live taskMap + staged overrides.
        var taskOverridePairs: [(task: Task, override: StagedTaskOverride)] = []
        for (taskId, override) in editTaskOverrides {
            if let task = taskMap[taskId] {
                taskOverridePairs.append((task: task, override: override))
            }
        }

        // Phase 3 — snapshot staged position moves. Compare each cell's slot in
        // `editRearrangeCells` to its originalRow/Col. Center and empty slots are
        // excluded (they don't correspond to BoardTask rows).
        let size = gridSize
        let positionMoves: [(boardTaskId: String, row: Int, col: Int)] = {
            guard let rearranged = editRearrangeCells, size > 0 else { return [] }
            var moves: [(boardTaskId: String, row: Int, col: Int)] = []
            for (slotIdx, cell) in rearranged.enumerated() {
                guard !cell.isCenter, !cell.isEmpty else { continue }
                let stagedRow = slotIdx / size
                let stagedCol = slotIdx % size
                if stagedRow != cell.originalRow || stagedCol != cell.originalCol {
                    moves.append((boardTaskId: cell.id, row: stagedRow, col: stagedCol))
                }
            }
            return moves
        }()

        editSaveInFlight = true
        let bid = boardId
        let database = self.database
        _Concurrency.Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            do {
                // 1. Metadata patch (name / timeframe / center).
                try database.updateBoardAndCascade(boardId: bid, patch: patch)

                // 2. Staged cell replacements — each repoints one BoardTask row
                //    and re-derives board stats for the old + new task contexts.
                for replacement in cellReplacements {
                    try database.updateBoardTaskAndCascade(
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
                    try database.saveTaskAndCascade(updated)
                }

                // 4. Phase 3 — Staged position moves: rewrite row/col on moved
                //    BoardTask rows in a single atomic transaction, then re-derive
                //    bingo lines for this board.
                if !positionMoves.isEmpty {
                    try database.updateBoardTaskPositions(
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
                    self.editSaveInFlight = false
                    // Domain refresh moves here; the view-owned UI mutations
                    // (editSaving off, editMode off, "Board saved" toast) run in
                    // the view's `.onChange(of: editEvent)` on `.saved`.
                    self.reload()
                    self.emitEdit(.saved)
                }
            } catch {
                print("⚠️ BoardPlayViewModel.handleEditSave: \(error)")
                await MainActor.run {
                    self.editSaveInFlight = false
                    self.emitEdit(.saveFailed("Couldn’t save your changes — please try again."))
                }
            }
        }
        return true
    }

    /// Archives the board by setting `status = .archived` via the injected
    /// `database`, then emits `editEvent(.archived)` so the view exits edit mode
    /// and dismisses back to the Boards list. On failure it surfaces an error
    /// through `bingoMessage` (which the VM already owns).
    ///
    /// The archive confirm alert in `BoardEditPanel` calls this only after the
    /// user confirms — no further confirmation required here.
    func handleEditArchive() {
        let bid = boardId
        let database = self.database
        _Concurrency.Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            do {
                try database.archiveBoard(id: bid)
                // Only leave the board if the archive actually committed.
                await MainActor.run {
                    self.emitEdit(.archived)
                }
            } catch {
                print("⚠️ BoardPlayViewModel.handleEditArchive: \(error)")
                await MainActor.run {
                    self.bingoMessage = "Archive failed — please try again."
                }
            }
        }
    }

    /// Publishes a one-shot `editEvent` the view observes to run the residual
    /// edit-commit UI mutations it still owns.
    private func emitEdit(_ outcome: BoardPlayEditEvent.Outcome) {
        editEventCounter += 1
        editEvent = BoardPlayEditEvent(id: editEventCounter, outcome: outcome)
    }

    // MARK: - Private

    /// The workspace-wide fetch bundle shared by `reload()` and
    /// `reloadBoardTasksAndTaskData()`. Pure + `nonisolated` so it runs on the
    /// background queue. Mirrors the pre-refactor `loadTaskData` fetch set
    /// (plus the board's own placements) exactly.
    private nonisolated static func fetchTaskData(
        boardId: String,
        userId: String?,
        database: AppDatabase
    ) -> TaskDataPayload {
        let boardTasks = (try? database.fetchBoardTasks(boardId: boardId)) ?? []
        let tasks = userId.flatMap { id in try? database.fetchTasks(userId: id) } ?? []
        let children = (try? database.fetchAllCompoundChildren()) ?? []
        let workspaceBoards = userId.flatMap { id in try? database.fetchBoards(userId: id) } ?? []
        let workspaceTemplates = userId.flatMap { id in
            try? database.fetchRecurringBoardTemplates(userId: id)
        } ?? []
        let workspaceBoardTasks = (try? database.fetchAllBoardTasks()) ?? []
        return TaskDataPayload(
            boardTasks: boardTasks,
            allTasks: tasks,
            allCompoundChildren: children,
            allBoardsInWorkspace: workspaceBoards,
            allTemplatesInWorkspace: workspaceTemplates,
            allBoardTasksInWorkspace: workspaceBoardTasks
        )
    }

    private func apply(_ payload: TaskDataPayload) {
        boardTasks = payload.boardTasks
        allTasks = payload.allTasks
        allCompoundChildren = payload.allCompoundChildren
        allBoardsInWorkspace = payload.allBoardsInWorkspace
        allTemplatesInWorkspace = payload.allTemplatesInWorkspace
        allBoardTasksInWorkspace = payload.allBoardTasksInWorkspace
    }

    /// Snapshot of the task-data fetch bundle, passed from the background
    /// queue to the main-queue apply.
    private struct TaskDataPayload {
        let boardTasks: [BoardTask]
        let allTasks: [Task]
        let allCompoundChildren: [CompoundChild]
        let allBoardsInWorkspace: [Board]
        let allTemplatesInWorkspace: [RecurringBoardTemplate]
        let allBoardTasksInWorkspace: [BoardTask]
    }
}

// MARK: - BoardPlayFlashEvent

/// One-shot UI-effect signal published by `BoardPlayViewModel` after an
/// interaction write completes. The write itself + all domain-state mutation
/// (board stats, sync rows, the `@Published` arrays) happen in the view model;
/// this carries ONLY the residual view-side animation triggers the view owns
/// (`triggerRisoNotification(from:)` + `triggerCreditToast(text:)`), which
/// depend on view `@State` / `AuthService` and can't move.
///
/// A single event can carry BOTH a bingo/GREENLOG notification and a
/// shared-counter credit toast (the shared-counter increment path fires both),
/// so the payload is two optionals rather than a single-case enum — an enum
/// would force two `@Published` writes in one synchronous main-actor block,
/// and SwiftUI would coalesce them, dropping one effect. The monotonic `id`
/// keeps consecutive identical-copy emissions distinct for `.onChange`.
struct BoardPlayFlashEvent: Identifiable, Equatable {
    let id: Int
    /// Message for the view's `triggerRisoNotification(from:)` (bingo toast /
    /// GREENLOG overlay). Nil ⇒ the interaction produced no bingo-state change.
    let risoNotification: String?
    /// Text for the view's `triggerCreditToast(text:)` (shared-counter ripple).
    /// Nil ⇒ the ripple reached no OTHER board.
    let creditToast: String?
}

// MARK: - BoardPlayEditEvent

/// One-shot edit-commit signal published by `BoardPlayViewModel` after a
/// `handleEditSave` / `handleEditArchive` DB commit completes. The commit +
/// domain refresh (`reload()`) happen in the view model; this carries ONLY the
/// residual view-owned UI mutations the view still runs — `editSaving` /
/// `editMode` / `editSaveError` / the "Board saved" toast / `dismiss()` — which
/// depend on view `@State` and the `dismiss` environment and can't move.
///
/// Mirrors `BoardPlayFlashEvent`'s one-shot pattern (monotonic `id` so
/// consecutive emissions stay distinct for the view's `.onChange`).
struct BoardPlayEditEvent: Identifiable, Equatable {
    let id: Int
    let outcome: Outcome

    enum Outcome: Equatable {
        /// Save committed → view resets `editSaving`, flips `editMode` off
        /// (animated), and flashes the "Board saved" toast.
        case saved
        /// Save threw → view resets `editSaving` and shows the alert via
        /// `editSaveError`. Carries the user-facing error copy.
        case saveFailed(String)
        /// Archive committed → view flips `editMode` off (animated) and
        /// `dismiss()`es back to the Boards list.
        case archived
    }
}

// MARK: - Sync Queue + cascade helpers (moved from BoardPlayView.swift in B2-I2)
//
// These file-private free functions + `BPVCascadeBoardResult` moved verbatim
// from `BoardPlayView.swift` alongside the interaction handlers that call them
// inside their write transactions. Folding them into `AppDatabase` is a
// later slice (B4); for now they travel with their only callers.

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
