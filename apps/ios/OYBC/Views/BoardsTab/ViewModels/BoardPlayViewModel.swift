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

    /// O(1) task lookup by task id over the loaded `allTasks`. Feeds the moved
    /// tap handlers; the view delegates its own `taskMap` here.
    var taskMap: [String: Task] {
        Dictionary(uniqueKeysWithValues: allTasks.map { ($0.id, $0) })
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
