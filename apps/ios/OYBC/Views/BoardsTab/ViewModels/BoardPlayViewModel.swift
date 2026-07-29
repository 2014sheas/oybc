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

    /// Windowed Completion (docs/WINDOWED_COMPLETION.md §The model): the
    /// workspace's non-deleted TaskEvents grouped by `taskId`. The board grid +
    /// tap handlers resolve each event-owning primitive square against the
    /// board's window (`board.startDate`) via `resolveTaskWindowState` instead of
    /// reading the lifetime `Task.isCompleted` / `currentCount` caches. iOS twin
    /// of web's `SquareWindowContext`.
    @Published private(set) var windowEventsByTaskId: [String: [TaskEvent]] = [:]

    /// Kernel per-cell states for the CURRENT board — the single source of
    /// truth every achievement/completion render read funnels through
    /// (PR-3, docs/BOARD_INTEGRITY.md). Stored (not computed) so the full
    /// resolvePlacements + computeBoardGrid pass runs ONCE per data change
    /// (`apply(_:)` after every reload), not once per rendered cell — the
    /// PR-3 review flagged the per-cell recompute (O(size²) kernel passes
    /// per render) as the perf-shape to avoid.
    @Published private(set) var kernelCellStates: [String: DerivationPass.CellState] = [:]

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

    // MARK: - Passive completion (Shared Counters P3)

    /// One-shot arrival signal (see `CounterArrivalEvent`). Published exactly
    /// once per board-open when ≥1 shared-counter square filled in from a log
    /// made elsewhere. The view observes it via `.onChange` and drives the gold
    /// `RisoArrivalBanner` + the per-square pulse (both view-owned `@State`).
    /// `private(set)` — only `detectArrivalsAndSeed()` publishes it. Follows the
    /// `flashEvent` one-shot pattern (monotonic id + `Equatable`).
    @Published private(set) var arrivalEvent: CounterArrivalEvent?

    /// Monotonic counter backing `arrivalEvent.id` so consecutive emissions are
    /// distinct `Equatable` values for the view's `.onChange`.
    private var arrivalEventCounter = 0

    /// Set on board-open (appear / pager board-change) so the NEXT `apply()`
    /// runs arrival detection exactly once. Cleared after the detect pass, so a
    /// LOCAL tap (whose reload also lands in `apply`) never masquerades as an
    /// arrival.
    private var shouldDetectArrivals = false

    /// The board id the arrival baseline was last (re)seeded for. After the
    /// once-per-open detect, subsequent reloads on the SAME board re-snapshot
    /// the baseline through local taps so leaving + returning stays quiet.
    private var arrivalDetectedBoardId: String?

    /// Device-local last-seen snapshot store. Injected for tests.
    private let arrivalStore: CounterArrivalStore

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

    // MARK: - Windowed read helpers (Windowed Completion)

    /// The current board's window lower bound (`board.startDate`), or nil when
    /// no board is loaded. Every event-owning square resolves against
    /// `[windowStart, ∞)`.
    var windowStart: String? { board?.startDate }

    /// Resolve an event-owning primitive task's windowed state for the current
    /// board window (docs §Semantics). Callers must branch derived / compound /
    /// achievement BEFORE calling — this delegates to the shared
    /// `resolveTaskWindowState`.
    func windowedState(forTaskId taskId: String) -> TaskWindowState {
        guard let task = taskMap[taskId] else { return TaskWindowState(isCompleted: false, count: 0) }
        let events = windowEventsByTaskId[taskId] ?? []
        return resolveTaskWindowState(task: task, events: events, windowStart: windowStart)
    }

    /// Windowed-Completion-aware "is this square complete" read for the
    /// Board-Edit draft preview surfaces (`RearrangeGrid` + the edit-tasks
    /// static grid). iOS parity fix for the same class of bug the web fix in
    /// d16ff21 patched: these preview surfaces used to read the lifetime
    /// `Task.isCompleted` cache directly, so a lifetime-complete task bled
    /// green into a freshly-spawned/reused board's window even though the
    /// live play grid correctly reads windowed
    /// (docs/WINDOWED_COMPLETION.md §Task caches).
    ///
    /// Only event-owning primitives (normal / plain-source counting) resolve
    /// against the board's window via `windowedState(forTaskId:)`. Compound,
    /// achievement, and derived (shared-counter-linked) counting tasks keep
    /// reading the lifetime `Task.isCompleted` cache, unchanged — only
    /// event-owning primitives can go stale across a window rollover, and
    /// these preview surfaces have no compound/achievement evaluation context
    /// of their own (out of scope for this fix).
    ///
    /// - Parameter task: The task to resolve. Title/type may carry staged
    ///   `editTaskOverrides`, but `id`/`isCompleted` always reflect the real
    ///   database values, so the windowed lookup is always against the true task.
    func windowedIsCompleted(for task: Task) -> Bool {
        guard isEventOwningTask(task) else { return task.isCompleted }
        return windowedState(forTaskId: task.id).isCompleted
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
        // Sole consumer is BoardEditPanel (edit mode only), and `seedEditDraft`
        // populates the draft synchronously before the view flips `editMode`, so
        // a MISSING key here always means the cell was removed via
        // `handleEditRemove` — drop it (compactMap → nil) so the grid renders the
        // hole. An all-removed session correctly yields []. (Mirrors the way
        // `editSquaresEditCount` treats an absent draft entry as a removal.)
        //
        // Board-integrity PR-2 (Part 2): resolve `boardTasks` first — a raw
        // duplicate row sharing a cell with `editSquaresDraft`'s winner
        // would otherwise ALSO match that draft key here (the draft is
        // keyed by "row-col", not boardTaskId) and get its taskId
        // overwritten to the staged value too, rendering two BoardTasks for
        // one cell in `BoardEditStaticGrid`.
        return PlacementIntegrity.resolvePlacements(boardTasks, boardSize: gridSize).compactMap { bt in
            let key = "\(bt.row)-\(bt.col)"
            guard let draft = editSquaresDraft[key] else { return nil }
            guard draft.stagedTaskId != bt.taskId else { return bt }
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
        // Staged removals — boardTaskIds seeded from the pre-edit placements but
        // no longer present in the draft (removed via `handleEditRemove`).
        // Diff against the RESOLVED set (matches `seedEditDraft`'s seed
        // source + web's centralized resolution): a pre-repair collision
        // loser is invisible to the edit UI and must not inflate the count
        // as a change the user didn't make (PR-2 review).
        let draftIds = Set(editSquaresDraft.values.map { $0.boardTaskId })
        let removals = PlacementIntegrity.resolvePlacements(boardTasks, boardSize: gridSize)
            .filter { !draftIds.contains($0.id) }.count
        return replacements + overrides + positionMoves + removals
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
    /// Board-integrity PR-4 (Item 5, docs/BOARD_INTEGRITY.md): registered for
    /// this VM's lifetime (init → deinit). iOS had no live-update mechanism
    /// before this — a sync pull landing while a board-play screen was open
    /// (e.g. another device completing a task) sat invisible until the user
    /// navigated away and back; web is reactive via Dexie's `useLiveQuery`.
    private var syncObserver: NSObjectProtocol?

    init(
        boardId: String,
        userId: String?,
        database: AppDatabase = .shared,
        arrivalStore: CounterArrivalStore = CounterArrivalStore()
    ) {
        self.boardId = boardId
        self.userId = userId
        self.database = database
        self.arrivalStore = arrivalStore

        self.syncObserver = NotificationCenter.default.addObserver(
            forName: .oybcSyncDidApplyChanges,
            object: nil,
            queue: .main
        ) { [weak self] _ in
            _Concurrency.Task { @MainActor [weak self] in
                self?.handleSyncDidApplyChanges()
            }
        }
    }

    deinit {
        if let syncObserver {
            NotificationCenter.default.removeObserver(syncObserver)
        }
    }

    /// Supply the authenticated user's id. Called by the view in `.onAppear`
    /// (where its `@EnvironmentObject` is available). Does not trigger a
    /// reload — the caller reloads immediately after.
    func setUserId(_ userId: String?) {
        self.userId = userId
    }

    /// Board-integrity PR-4 (Item 5): reload in response to a sync pull's
    /// post-apply signal.
    ///
    /// Guard: skips while `editSaveInFlight` — `handleEditSave`'s own commit
    /// runs the composed write transaction (Item 3) and then calls `reload()`
    /// itself on success; a pull-triggered reload racing in in the middle
    /// would either be immediately superseded by that follow-up reload (the
    /// `reloadToken` stale-result guard keeps whichever finishes last) or, in
    /// the worst case, briefly show a stale grid mid-Save — never a torn
    /// write, since `reload()` never writes.
    ///
    /// Residual (not guarded here): a reload while the user is IN edit mode
    /// with unsaved staged changes (editMode == true but editSaveInFlight ==
    /// false — `editMode` itself is view-side `@State`, not visible to the
    /// VM). `editSquaresDraft` / `editTaskOverrides` are separate `@Published`
    /// state seeded once from `boardTasks` at edit-mode-entry
    /// (`seedEditDraft`), so a reload's fresh `boardTasks` does NOT
    /// retroactively rewrite the staged draft — only the read-only grid
    /// behind the edit panel would refresh. This matches how a local tap's
    /// reload already behaves while edit mode is open today (no worse than
    /// existing behavior), so it's left unguarded rather than threading a
    /// second view-owned flag down into the VM.
    private func handleSyncDidApplyChanges() {
        guard !editSaveInFlight else { return }
        reload()
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
    ///
    /// Board-integrity PR-4 (Item 4, docs/BOARD_INTEGRITY.md): `board` and
    /// the task-data payload are now fetched together via `fetchSnapshot`
    /// inside ONE `database.read {}` — previously this called
    /// `database.fetchBoard(id:)` and `fetchTaskData` as two separate reads
    /// (each itself doing several MORE separate reads), so a write landing
    /// mid-sequence could hand this reload a torn snapshot (e.g. a board
    /// whose `completedLineIds` reflects a just-pulled rearrange but whose
    /// `boardTasks` still reflect the pre-pull placements).
    func reload() {
        reloadToken += 1
        let token = reloadToken
        let boardId = self.boardId
        let userId = self.userId
        let database = self.database

        DispatchQueue.global(qos: .userInitiated).async { [weak self] in
            guard let self = self else { return }
            let snapshot = Self.fetchSnapshot(boardId: boardId, userId: userId, database: database)
            DispatchQueue.main.async {
                guard token == self.reloadToken else { return }
                self.board = snapshot.board
                self.apply(snapshot.payload)
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
        // The embedded pager reuses this VM/view for a new board — that counts
        // as a board-open, so detect arrivals on the reload that follows.
        shouldDetectArrivals = true
        reload()
    }

    /// Mark that the next `reload()` should run arrival detection. Called by the
    /// view in `.onAppear` (the first board-open on this instance). The standalone
    /// route recreates the VM per board via `.id(boardId)`, so `.onAppear` +
    /// this flag drive detection there; the pager uses `boardChanged(to:)`.
    func markArrivalDetectionPending() {
        shouldDetectArrivals = true
    }

    /// Re-snapshot the current board's shared-counting squares (board disappear).
    /// The once-per-open detect + local-tap reloads already keep the baseline
    /// current, so this is a belt-and-suspenders write on leaving. No-op when the
    /// board has no shared-counting squares.
    func snapshotArrivalsOnDisappear() {
        guard let board = board else { return }
        arrivalStore.save(
            boardId: board.id,
            snapshot: snapshotCounterSquares(squares: sharedCounterArrivalSquares())
        )
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
        guard !isProcessing, taskMap[boardTask.taskId] != nil else { return }
        // Windowed Completion — toggle the WINDOWED completed state (what the
        // grid shows), not the lifetime cache. The DB layer appends a completion
        // event (complete) or window-scoped tombstones (un-complete).
        let windowed = windowedState(forTaskId: boardTask.taskId)
        runOrchestration(
            taskId: boardTask.taskId,
            intent: .setCompleted(!windowed.isCompleted),
            boardTask: boardTask
        )
    }

    /// Resolves the shared-counter SOURCE task id for `task`, or `nil` when
    /// it doesn't participate in any shared-counter group. R3: extracted out
    /// of `handleCountingTap`/`handleCountingDecrement` so `BoardPlayView`
    /// (chip visibility in `RisoCountingStepperSheet`, the context-menu
    /// default amount, `sharedStepperHint`) shares the exact same detection
    /// instead of re-deriving it — three call sites were re-implementing
    /// this before R3.
    ///
    /// - (a) Linked derived counter: `task.sharedCounterId != nil` → that id.
    /// - (b) Source counter: `task.id` appears as a `sharedCounterId` on any
    ///   other live task, OR it's a promoted zero-link counter (P5:
    ///   `isCounter == true`, no members yet) → `task.id`.
    /// - (c) Neither → `nil` (standalone counter).
    ///
    /// Callers are responsible for gating on `task.type == .counting` first
    /// — this helper doesn't check the type (mirrors the pre-existing
    /// call-site convention).
    func sharedCounterSourceId(for task: Task) -> String? {
        if let linkedSourceId = task.sharedCounterId { return linkedSourceId }
        if task.isCounter == true { return task.id }
        if allTasks.contains(where: { $0.sharedCounterId == task.id && !$0.isDeleted }) {
            return task.id
        }
        return nil
    }

    /// Increments a counting task by `amount` (default 1, preserving the
    /// pre-R3 tap-equals-+1 behavior for every existing call site).
    ///
    /// Phase 3 — Shared Counters routing (`sharedCounterSourceId(for:)`):
    ///  (a)/(b) Shared counter (source or linked): routes through
    ///      `runSharedCounterIncrement`, which enforces the overshoot (no
    ///      high-end clamp) and one-way-latch invariants inside a single
    ///      GRDB write transaction.
    ///  (c) Standalone counter (no shared link): falls through to the legacy
    ///      `runOrchestration` path, `amount`-aware since R3 too (still
    ///      always 1 from every current standalone call site — the R3
    ///      amount-chip UI is shared-counter-squares-only per the copy
    ///      contract).
    ///
    /// - Parameters:
    ///   - boardTask: The counting task's `BoardTask` record.
    ///   - task: The `Task` providing `maxCount` and shared-counter fields.
    ///   - amount: Amount to log. Default 1 preserves prior behavior.
    ///   - persistAsDefault: R3 — when `true`, the amount just used also
    ///     becomes the shared counter's new `defaultLogAmount` (mirrors R2
    ///     Detail). Only an explicit custom "#" entry passes `true` — one-tap
    ///     chips (+1 / +default) and every pre-R3 call site pass `false` so a
    ///     quick nudge never silently overwrites the user's preference.
    func handleCountingTap(boardTask: BoardTask, task: Task, amount: Int = 1, persistAsDefault: Bool = false) {
        guard !isProcessing else { return }

        if let sourceId = sharedCounterSourceId(for: task) {
            let sourceTask = taskMap[sourceId]
            let resolvedName = Self.counterDisplayName(sourceTask)
            let counterName = resolvedName.isEmpty ? task.title : resolvedName
            let unit = sourceTask?.unit ?? ""
            runSharedCounterIncrement(
                sourceTaskId: sourceId,
                counterName: counterName,
                unit: unit,
                amount: amount,
                persistAsDefault: persistAsDefault
            )
            return
        }

        // Standalone counter — Windowed Completion. The grid shows the
        // WINDOWED count; `+amount` targets `windowedCount + amount`. NO
        // high-end clamp per feedback_counter_overshoot_is_valid: overshoot
        // is intentional. The DB layer appends a +amount increment event
        // scoped to the board's window.
        guard task.maxCount != nil else { return }
        let windowed = windowedState(forTaskId: boardTask.taskId)
        runOrchestration(
            taskId: boardTask.taskId,
            intent: .setWindowedCount(windowed.count + amount),
            boardTask: boardTask
        )
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
    ///   - counterName: Display name used in the credit toast copy (R3:
    ///     pair-derived, resolved by the caller — never raw `task.title`).
    ///   - unit: The counter's unit noun, threaded into the credit toast
    ///     payload for the unified `CounterLogToastView`.
    ///   - amount: Amount to log (R3; default 1 preserves prior behavior).
    ///   - persistAsDefault: R3 — forwarded to `setCounterDefaultLogAmount`
    ///     after a successful log; only `true` for an explicit custom entry.
    private func runSharedCounterIncrement(
        sourceTaskId: String,
        counterName: String = "",
        unit: String = "",
        amount: Int = 1,
        persistAsDefault: Bool = false
    ) {
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

                let creditResult = try database.incrementSharedCounter(sourceTaskId: sourceTaskId, by: amount)

                // R3 — the amount just used becomes the new default ONLY for an
                // explicit custom "#" entry (Global Constraints: one-tap chips
                // never overwrite the counter's default). No-op if unchanged.
                if persistAsDefault {
                    try? database.setCounterDefaultLogAmount(sourceTaskId: sourceTaskId, amount: amount)
                }

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

                // P2/R3: Build the credited toast for OTHER boards that changed.
                let otherBoards = creditResult.affectedBoards.filter { $0.boardId != currentBoardId }
                let creditPayload: SharedCounterCreditToastPayload? = otherBoards.isEmpty ? nil :
                    SharedCounterCreditToastPayload(
                        sourceTaskId: sourceTaskId,
                        amount: amount,
                        unit: unit,
                        isIncrement: true,
                        message: self.sharedCreditToastText(
                            counterName: counterName, amount: amount, otherBoards: otherBoards, isIncrement: true
                        )
                    )

                await MainActor.run {
                    self.isProcessing = false
                    self.reload()
                    if let msg = newBingoMsg {
                        self.bingoMessage = msg
                        self.scheduleBingoMessageDismiss(msg)
                    }
                    self.emitFlash(risoNotification: newBingoMsg, creditToast: creditPayload)
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
    ///   - counterName: Display name used in the credit toast copy (R3:
    ///     pair-derived, resolved by the caller — never raw `task.title`).
    ///   - unit: The counter's unit noun, threaded into the credit toast payload.
    ///   - amount: Amount to remove (R3; default 1 preserves prior behavior).
    ///     The engine clamps at 0 — the toast/Undo use the CLAMPED
    ///     `effectiveDelta`, not the requested `amount` (Global Constraints:
    ///     the toast's delta must match what Undo will reverse).
    ///   - persistAsDefault: R3 — forwarded to `setCounterDefaultLogAmount`
    ///     using the REQUESTED `amount` (the user's chosen preference, even
    ///     if the write itself got clamped) after a successful log; only
    ///     `true` for an explicit custom entry.
    private func runSharedCounterDecrement(
        sourceTaskId: String,
        counterName: String = "",
        unit: String = "",
        amount: Int = 1,
        persistAsDefault: Bool = false
    ) {
        guard !isProcessing else { return }
        isProcessing = true
        let currentBoardId = board?.id
        let database = self.database

        _Concurrency.Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            do {
                // Capture pre-decrement board stats for the board-transition flash (F1).
                let boardBefore: Board? = currentBoardId.flatMap { id in
                    try? database.read { db in try Board.fetchOne(db, key: id) }
                }

                let decrementResult = try database.decrementSharedCounter(sourceTaskId: sourceTaskId, by: amount)
                guard decrementResult.effectiveDelta > 0 else {
                    // No-op — source was already at 0; nothing to show.
                    await MainActor.run { self.isProcessing = false }
                    return
                }

                if persistAsDefault {
                    try? database.setCounterDefaultLogAmount(sourceTaskId: sourceTaskId, amount: amount)
                }

                // Board-transition flash (F1): windowed completion is derived
                // per-board from the event log, NOT the source task's lifetime
                // latch — so removing a log can drop a completed square below its
                // goal on this window and flip the board COMPLETED → ACTIVE,
                // dropping bingo lines. The increment path already flashes the
                // mirror ACTIVE → COMPLETED case; without this the decrement
                // silently reactivated the board with no feedback. Only the
                // reactivated / lost-bingo rungs can fire on a decrement (never
                // greenlog / new bingos).
                let boardAfter: Board? = currentBoardId.flatMap { id in
                    try? database.read { db in try Board.fetchOne(db, key: id) }
                }
                var newBingoMsg: String? = nil
                if let before = boardBefore, let after = boardAfter {
                    let prevBingos = Set(before.completedLineIds ?? [])
                    let nextBingos = Set(after.completedLineIds ?? [])
                    let lost = prevBingos.subtracting(nextBingos).sorted()
                    if before.status == .completed && after.status == .active {
                        newBingoMsg = "Board reactivated — no longer complete"
                    } else if !lost.isEmpty {
                        newBingoMsg = "Bingo lost: \(lost.joined(separator: ", "))"
                    }
                }

                let otherBoards = decrementResult.affectedBoards.filter { $0.boardId != currentBoardId }
                let creditPayload: SharedCounterCreditToastPayload? = otherBoards.isEmpty ? nil :
                    SharedCounterCreditToastPayload(
                        sourceTaskId: sourceTaskId,
                        amount: decrementResult.effectiveDelta,
                        unit: unit,
                        isIncrement: false,
                        message: self.sharedCreditToastText(
                            counterName: counterName,
                            amount: decrementResult.effectiveDelta,
                            otherBoards: otherBoards,
                            isIncrement: false
                        )
                    )

                await MainActor.run {
                    self.isProcessing = false
                    self.reload()
                    if let msg = newBingoMsg {
                        self.bingoMessage = msg
                        self.scheduleBingoMessageDismiss(msg)
                    }
                    self.emitFlash(risoNotification: newBingoMsg, creditToast: creditPayload)
                }
            } catch {
                print("⚠️ BoardPlayView shared-counter decrement error: \(error)")
                await MainActor.run {
                    self.isProcessing = false
                }
            }
        }
    }

    /// Reverses the SOURCE counter's last log entry (`undoLastCounterLog`) —
    /// wired to the credited toast's Undo pill (R3 board-play touchpoints).
    /// Mirrors `CounterDetailView.handleUndo`: runs the write off-main, then
    /// reloads on the main actor. Reverses the counter's LATEST live entry
    /// at tap time — if a second log landed elsewhere during the toast
    /// window, THAT entry is reversed (not a no-op, and not necessarily the
    /// displayed one); accepted single-user race, same semantics as R2's
    /// Hub/Detail Undo (docs/SHARED_COUNTERS.md §R3) — matches
    /// `undoLastCounterLog`'s own no-op contract.
    ///
    /// - Parameter sourceTaskId: The counter's source task id (the toast's
    ///   `CreditToastState.sourceTaskId` on the view side).
    func undoSharedCounterLog(sourceTaskId: String) {
        let database = self.database
        let currentBoardId = board?.id
        _Concurrency.Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            // Capture pre-undo board stats for the board-transition flash (F1).
            let boardBefore: Board? = currentBoardId.flatMap { id in
                try? database.read { db in try Board.fetchOne(db, key: id) }
            }
            let result = try? database.undoLastCounterLog(sourceTaskId: sourceTaskId)

            // Board-transition flash (F1): reversing a log runs the same board
            // derivation cascade as a decrement, so it can drop a completed
            // square below its goal on this window and flip the board
            // COMPLETED → ACTIVE, dropping bingo lines. Mirror the decrement
            // path so the Undo pill surfaces the same feedback (only the
            // reactivated / lost-bingo rungs can fire). No-op when nothing was
            // reversed (`undoneAmount == 0`).
            var newBingoMsg: String? = nil
            if let result = result, result.undoneAmount > 0 {
                let boardAfter: Board? = currentBoardId.flatMap { id in
                    try? database.read { db in try Board.fetchOne(db, key: id) }
                }
                if let before = boardBefore, let after = boardAfter {
                    let prevBingos = Set(before.completedLineIds ?? [])
                    let nextBingos = Set(after.completedLineIds ?? [])
                    let lost = prevBingos.subtracting(nextBingos).sorted()
                    if before.status == .completed && after.status == .active {
                        newBingoMsg = "Board reactivated — no longer complete"
                    } else if !lost.isEmpty {
                        newBingoMsg = "Bingo lost: \(lost.joined(separator: ", "))"
                    }
                }
            }

            await MainActor.run {
                self.reload()
                if let msg = newBingoMsg {
                    self.bingoMessage = msg
                    self.scheduleBingoMessageDismiss(msg)
                    self.emitFlash(risoNotification: msg, creditToast: nil)
                }
            }
        }
    }

    /// Decrements a counting task by `amount` (default 1, preserving the
    /// pre-R3 tap-equals-−1 behavior for every existing call site).
    /// Routes shared-counter tasks (source or linked) through
    /// `runSharedCounterDecrement`; standalone tasks use the legacy orchestration.
    ///
    /// - Parameters:
    ///   - boardTask: The counting task's `BoardTask` record.
    ///   - task: The `Task` providing current state.
    ///   - amount: Amount to remove. Default 1 preserves prior behavior.
    ///   - persistAsDefault: R3 — see `handleCountingTap`.
    func handleCountingDecrement(boardTask: BoardTask, task: Task, amount: Int = 1, persistAsDefault: Bool = false) {
        guard !isProcessing else { return }

        if let sourceId = sharedCounterSourceId(for: task) {
            let sourceTask = taskMap[sourceId]
            let resolvedName = Self.counterDisplayName(sourceTask)
            let counterName = resolvedName.isEmpty ? task.title : resolvedName
            let unit = sourceTask?.unit ?? ""
            runSharedCounterDecrement(
                sourceTaskId: sourceId,
                counterName: counterName,
                unit: unit,
                amount: amount,
                persistAsDefault: persistAsDefault
            )
            return
        }

        // Standalone counter — Windowed Completion. Target `windowedCount -
        // amount` (floored at 0); the DB layer appends a gated negative-delta
        // increment event scoped to the board's window. isCompleted
        // re-derives from the windowed sum (a windowed count below maxCount
        // is no longer complete for this window — the lifetime latch no
        // longer applies to standalone windowed counters, matching web).
        let windowed = windowedState(forTaskId: boardTask.taskId)
        runOrchestration(
            taskId: boardTask.taskId,
            intent: .setWindowedCount(max(windowed.count - amount, 0)),
            boardTask: boardTask
        )
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
        // Windowed Completion — the child's completion is scoped to the host
        // board's window. Toggle the WINDOWED state (a child completed in a
        // prior window reads incomplete this window).
        let childWindowed = windowedState(forTaskId: childTask.id)
        let desiredCompleted = !childWindowed.isCompleted

        // If the child has a BoardTask on the current board, use the full
        // orchestration pipeline so bingo detection stays consistent.
        if let childBt = boardTasks.first(where: { $0.taskId == childTask.id }) {
            runOrchestration(
                taskId: childTask.id,
                intent: .setCompleted(desiredCompleted),
                boardTask: childBt
            )
            return
        }

        // Fallback: child is not placed on this board, but a parent compound
        // (or the child via another board) may be — so we still need the
        // windowed cross-board cascade to recompute every affected board's bingo
        // state and propagate the change to UI on this board (its compound square
        // derives via CompoundEvaluation against the host window).
        let windowStart = board?.startDate ?? childTask.startDate ?? now
        isProcessing = true
        let currentBoardId = board?.id
        let database = self.database
        _Concurrency.Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            do {
                var newBingoMsg: String? = nil
                // Child isn't on this board — the fallback write (child event
                // append + cache stamp + windowed cross-board cascade) is owned
                // by `AppDatabase.toggleCompoundChildFallback`. This VM derives
                // the current board's flash message from the returned results.
                let cascadeResults = try database.toggleCompoundChildFallback(
                    childTaskId: childTask.id,
                    desiredCompleted: desiredCompleted,
                    windowStart: windowStart,
                    boardId: currentBoardId,
                    now: now
                )
                if let cid = currentBoardId, let result = cascadeResults[cid] {
                    let lost = result.update.lostBingos.sorted()
                    let gained = result.update.newBingos.sorted()
                    if result.wasReactivated {
                        newBingoMsg = "Board reactivated — no longer complete"
                    } else if !lost.isEmpty {
                        newBingoMsg = "Bingo lost: \(lost.joined(separator: ", "))"
                    } else if result.didAutoComplete {
                        newBingoMsg = "GREENLOG!"
                    } else if !gained.isEmpty {
                        newBingoMsg = "Bingo! (\(gained.joined(separator: ", ")))"
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
        guard !isProcessing else { return }
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

    /// Runs the full task-completion orchestration and surfaces the flash.
    ///
    /// The write transaction itself (draft auto-activate, `Task` save,
    /// `BoardTask` bump, cross-board cascade + sync-enqueue) is owned by
    /// `AppDatabase.completeTaskOrchestrated`. That method delegates to
    /// `runBoardCascadeForTaskWithResults` — which uses
    /// `DerivationPass.computeBoardStatsUpdate` to rebuild bingo state for
    /// every affected board (current board plus any other board placing this
    /// task or a compound containing it), applies GREENLOG → COMPLETED
    /// auto-completion + COMPLETED → ACTIVE reactivation, persists each
    /// affected board, queues board sync entries, and returns per-board
    /// results. This VM surfaces a flash message for the *current* board only
    /// (other affected boards update silently — the user isn't looking at them).
    ///
    /// Uses `_Concurrency.Task` to avoid shadowing by the GRDB `Task` model.
    ///
    /// - Parameters:
    ///   - updatedTask: The already-mutated `Task` carrying new completion state.
    ///   - boardTask: The `BoardTask` placement record on the current board
    ///     (updatedAt/version will be bumped + sync-queued).
    private func runOrchestration(
        taskId: String,
        intent: AppDatabase.CompletionIntent,
        boardTask: BoardTask
    ) {
        guard let board = board else { return }
        isProcessing = true
        let now = AppDatabase.currentTimestamp()
        let currentBoardId = board.id
        let database = self.database

        _Concurrency.Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            do {
                var newBingoMsg: String? = nil

                // The complete write transaction (draft auto-activate, TaskEvent
                // append, cache stamp, BoardTask bump, windowed cross-board
                // cascade + sync-enqueue) lives in
                // `AppDatabase.completeTaskOrchestrated`. This VM only derives
                // the flash message for the *current* board from the returned
                // per-board results.
                let cascadeResults = try database.completeTaskOrchestrated(
                    board: board,
                    taskId: taskId,
                    intent: intent,
                    boardTask: boardTask,
                    now: now
                )

                // Surface a flash message for the *current* board only.
                // Other affected boards still updated stats — they just
                // don't get a transient banner since the user isn't on them.
                if let result = cascadeResults[currentBoardId] {
                    let lost = result.update.lostBingos.sorted()
                    let gained = result.update.newBingos.sorted()
                    if result.wasReactivated {
                        newBingoMsg = "Board reactivated — no longer complete"
                    } else if !lost.isEmpty {
                        newBingoMsg = "Bingo lost: \(lost.joined(separator: ", "))"
                    } else if result.didAutoComplete {
                        newBingoMsg = "GREENLOG!"
                    } else if !gained.isEmpty {
                        newBingoMsg = "Bingo! (\(gained.joined(separator: ", ")))"
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

    /// Builds the credited toast copy for an increment or decrement (R3
    /// board-play touchpoints — pinned copy contract, byte-identical to web):
    ///
    /// Increment: `"+{N} {counterName} — also counted on {board list}."`
    /// Decrement:  `"−{N} {counterName} — also removed from {board list}."`
    ///
    /// The board-list join (comma-separated, unchanged from the pre-R3 copy)
    /// is intentionally NOT touched here — the copy contract pins the verb
    /// wording + sign + amount + counter-name only.
    ///
    /// Pure (reads only its parameters) so it is `nonisolated` — the shared-
    /// counter handlers build the copy on their background task before hopping
    /// to the main actor.
    ///
    /// - Parameters:
    ///   - counterName: The counter's display name — pair-derived
    ///     (`Self.counterDisplayName`), never raw `task.title`.
    ///   - amount: The amount just logged/removed (matches what Undo will reverse).
    ///   - otherBoards: Boards OTHER than the current board that were credited.
    ///   - isIncrement: `true` for increment, `false` for decrement.
    private nonisolated func sharedCreditToastText(
        counterName: String,
        amount: Int,
        otherBoards: [AppDatabase.AffectedBoard],
        isIncrement: Bool
    ) -> String {
        let boardNames = otherBoards.map { $0.boardName }.joined(separator: ", ")
        if isIncrement {
            return "+\(amount) \(counterName) — also counted on \(boardNames)."
        } else {
            return "−\(amount) \(counterName) — also removed from \(boardNames)."
        }
    }

    /// Publishes a one-shot `flashEvent` the view observes to fire its
    /// `triggerRisoNotification(from:)` / `triggerCreditToast(payload:)`
    /// animations. No-op when both payloads are nil.
    private func emitFlash(risoNotification: String?, creditToast: SharedCounterCreditToastPayload?) {
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
        //
        // Board-integrity PR-2 (Part 2): resolve through
        // `PlacementIntegrity.resolvePlacements` first — a raw duplicate row
        // at one cell would otherwise seed the draft from whichever row
        // happens to iterate last (arbitrary), instead of the deterministic
        // winner render/derivation agree on.
        editSquaresDraft = [:]
        for bt in PlacementIntegrity.resolvePlacements(boardTasks, boardSize: gridSize) {
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

    /// Stages a cell removal (no DB write). Drops the cell from the squares
    /// draft so it renders empty; the placement is only soft-deleted
    /// (tombstoned) from the board on Save (`handleEditSave`, which diffs
    /// `boardTasks` against the remaining draft). Increments
    /// `editSquaresEditCount` so the panel counter + Save pill reflect the
    /// staged removal.
    ///
    /// A pinned free center has no `editSquaresDraft` entry, so the edit tap-menu
    /// never surfaces Remove for it — pinned centers stay non-removable.
    ///
    /// - Parameter cellKey: The "row-col" key into `editSquaresDraft`.
    func handleEditRemove(cellKey: String) {
        guard let draft = editSquaresDraft[cellKey] else { return }
        let removedBoardTaskId = draft.boardTaskId
        editSquaresDraft.removeValue(forKey: cellKey)
        // Keep an already-seeded rearrange grid in sync so a removal made after
        // switching to Rearrange (which doesn't re-seed) shows the hole. Replace
        // the removed cell in-place with an empty slot at its current position,
        // mirroring `buildRearrangeCells`'s empty representation.
        if let idx = editRearrangeCells?.firstIndex(where: { $0.id == removedBoardTaskId }) {
            let size = gridSize
            let stagedRow = size > 0 ? idx / size : 0
            let stagedCol = size > 0 ? idx % size : 0
            editRearrangeCells![idx] = RearrangeCellData(
                id: "empty-\(stagedRow)-\(stagedCol)",
                taskId: nil,
                isCenter: false,
                isEmpty: true,
                originalRow: stagedRow,
                originalCol: stagedCol
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

        let startISO: String?
        let endISO: String?
        var clearEnd = false

        // Dates are written ONLY when the user actually changed the window
        // (timeframe conversion, or new custom dates). A metadata-only Save
        // must PRESERVE the stored window: under Windowed Completion,
        // `startDate` is the completion window's lower bound — rewriting it
        // silently re-windows the board and wipes the progress of every task
        // whose events predate the new start. The old code recomputed dates
        // on EVERY save (indefinite → re-anchored to today; core → today's
        // window), resetting all progress except tasks completed on the edit
        // day. Nil startDate/endDate in the patch = "leave unchanged".
        let timeframeChanged = editTimeframe != board?.timeframe
        let customDatesChanged = editTimeframe == .custom
            && (editCustomStartDate != editOriginalCustomStartDate
                || editCustomEndDate != editOriginalCustomEndDate)

        if timeframeChanged {
            // Deliberate re-window: converting the board recomputes its dates.
            if editTimeframe == .indefinite {
                startISO = wizardLocalISOString(cal.startOfDay(for: Date()))
                endISO = nil
                clearEnd = true
            } else if editTimeframe == .custom {
                let snappedStart = snapStart(editCustomStartDate)
                let snappedEnd = snapEnd(editCustomEndDate)
                // Carry over EditBoardSheet's guard: the end-date picker's min can lag a
                // start-date change, so re-validate end >= start before persisting.
                guard snappedEnd >= snappedStart else { return false }
                startISO = snappedStart
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
        } else if customDatesChanged {
            // Same CUSTOM timeframe, user picked new dates.
            let snappedStart = snapStart(editCustomStartDate)
            let snappedEnd = snapEnd(editCustomEndDate)
            guard snappedEnd >= snappedStart else { return false }
            startISO = snappedStart
            endISO = snappedEnd
        } else {
            // Window untouched — nil dates preserve the stored window (and
            // every in-window completion event) across the save.
            startISO = nil
            endISO = nil
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

        // Staged removals — boardTaskIds present in the pre-edit placements
        // (the RESOLVED seed source, matching `seedEditDraft` + web) but
        // absent from the draft after one or more `handleEditRemove` actions.
        // Deleted from the board on Save. Diffing the resolved set means a
        // pre-repair collision loser is never folded in as a user-staged
        // removal — the repair pass owns tombstoning losers (PR-2 review).
        let cellRemovals: [String] = {
            let draftIds = Set(editSquaresDraft.values.map { $0.boardTaskId })
            return PlacementIntegrity.resolvePlacements(boardTasks, boardSize: gridSize)
                .filter { !draftIds.contains($0.id) }.map { $0.id }
        }()

        editSaveInFlight = true
        let bid = boardId
        let database = self.database
        _Concurrency.Task.detached(priority: .userInitiated) { [weak self] in
            guard let self = self else { return }
            do {
                // Board-integrity PR-4 (Item 3, docs/BOARD_INTEGRITY.md): the five
                // sub-ops below used to run as five SEPARATE `database.write {}`
                // transactions — a failure partway through left a half-applied
                // board (e.g. metadata renamed but a cell replacement never
                // landed) with only a generic "save failed" surfaced, and no way
                // to roll back the pieces that DID commit. Composing them into
                // ONE `database.write {}` makes the whole Save all-or-nothing.
                //
                // Each sub-op below calls the `db:`-scoped core of its normal
                // instance-method entry point (`updateBoardAndCascade`,
                // `updateBoardTaskAndCascade`, `saveTaskAndCascade`,
                // `updateBoardTaskPositions`, `removeBoardTaskFromBoard`) instead
                // of the instance method itself — GRDB's `DatabaseQueue.write` (and
                // `.read`) are not reentrant, so calling the instance methods
                // (which each open their own `write {}`) from inside this
                // already-open transaction would trap. The op order and cascade
                // semantics are otherwise unchanged.
                try database.write { db in
                    // 1. Metadata patch (name / timeframe / center).
                    try AppDatabase.updateBoardAndCascade(db: db, boardId: bid, patch: patch)

                    // 2. Staged cell replacements — each repoints one BoardTask row
                    //    and re-derives board stats for the old + new task contexts.
                    for replacement in cellReplacements {
                        try AppDatabase.updateBoardTaskAndCascade(
                            db: db,
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
                        try AppDatabase.saveTaskAndCascade(db: db, task: updated)
                    }

                    // 4. Phase 3 — Staged position moves: rewrite row/col on moved
                    //    BoardTask rows, then re-derive bingo lines for this board.
                    if !positionMoves.isEmpty {
                        try AppDatabase.updateBoardTaskPositions(
                            db: db,
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

                    // 5. Staged removals — soft-delete (tombstone) each removed
                    //    BoardTask row. `removeBoardTaskFromBoard` is idempotent
                    //    (no-op if the row is already tombstoned) and re-derives
                    //    stats for every affected board, in the SAME transaction
                    //    as everything above.
                    for removedId in cellRemovals {
                        try AppDatabase.removeBoardTaskFromBoard(db: db, boardTaskId: removedId)
                    }
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
    ///
    /// Board-integrity PR-4 (Item 4, docs/BOARD_INTEGRITY.md): all seven
    /// sub-fetches now run inside ONE `database.read {}` transaction (via
    /// `fetchTaskDataPayload(db:boardId:userId:)` below) instead of seven
    /// separate `read {}` calls, each of which opened its own transaction.
    /// Previously a sync pull (or another write) landing BETWEEN two of
    /// those reads could produce a torn snapshot — e.g. `boardTasks`
    /// reflecting a just-pulled rearrange while `windowEventsByTaskId` still
    /// reflected the pre-pull state — surfacing as a transient lit-ring /
    /// grey-cell mismatch on the grid. A single read transaction sees one
    /// consistent point in time across every field.
    private nonisolated static func fetchTaskData(
        boardId: String,
        userId: String?,
        database: AppDatabase
    ) -> TaskDataPayload {
        (try? database.read { db in
            try fetchTaskDataPayload(db: db, boardId: boardId, userId: userId)
        }) ?? Self.emptyTaskDataPayload
    }

    /// Combined board + task-data snapshot for `reload()`. Board-integrity
    /// PR-4 (Item 4): the pre-fix `reload()` fetched `board` via its own
    /// `database.fetchBoard(id:)` transaction, then separately called
    /// `fetchTaskData` (a second transaction) — a write landing between the
    /// two could still tear the board record against its own
    /// placements/events even after `fetchTaskData` itself became atomic.
    /// Fetching both in ONE `database.read {}` closes that remaining gap.
    private nonisolated static func fetchSnapshot(
        boardId: String,
        userId: String?,
        database: AppDatabase
    ) -> (board: Board?, payload: TaskDataPayload) {
        (try? database.read { db -> (Board?, TaskDataPayload) in
            let board = try Board.fetchOne(db, key: boardId)
            let payload = try fetchTaskDataPayload(db: db, boardId: boardId, userId: userId)
            return (board, payload)
        }) ?? (nil, Self.emptyTaskDataPayload)
    }

    /// Zero-value payload returned when a read fails (mirrors the pre-fix
    /// per-field `?? []` fallbacks, collapsed to one shared constant now
    /// that the fetch is a single all-or-nothing `read {}`).
    /// `nonisolated`: a pure value constructor with no main-actor state,
    /// referenced from the nonisolated background fetch helpers.
    private nonisolated static var emptyTaskDataPayload: TaskDataPayload {
        TaskDataPayload(
            boardTasks: [],
            allTasks: [],
            allCompoundChildren: [],
            allBoardsInWorkspace: [],
            allTemplatesInWorkspace: [],
            allBoardTasksInWorkspace: [],
            windowEventsByTaskId: [:]
        )
    }

    /// The actual per-field queries, run against an already-open `db` handle
    /// so `fetchTaskData` and `fetchSnapshot` above can compose them into
    /// whichever single transaction each needs. Bodies mirror
    /// `AppDatabase.fetchBoardTasks(boardId:)` / `.fetchTasks(userId:)` /
    /// `.fetchAllCompoundChildren()` / `.fetchBoards(userId:)` /
    /// `.fetchRecurringBoardTemplates(userId:)` / `.fetchAllBoardTasks()` /
    /// `.fetchNonDeletedTaskEvents(userId:)` exactly — those public wrappers
    /// each open their OWN `read {}`, which is why they can't be called
    /// directly from in here (GRDB's `read`/`write` aren't reentrant).
    private nonisolated static func fetchTaskDataPayload(
        db: Database,
        boardId: String,
        userId: String?
    ) throws -> TaskDataPayload {
        let boardTasks = try BoardTask
            .filter(Column("boardId") == boardId && Column("isDeleted") == false)
            .order(Column("row"), Column("col"), Column("id"))
            .fetchAll(db)

        let tasks: [Task]
        if let userId {
            tasks = try Task
                .filter(Column("userId") == userId && Column("isDeleted") == false)
                .order(Column("title"))
                .fetchAll(db)
        } else {
            tasks = []
        }

        let children = try CompoundChild
            .filter(Column("isDeleted") == false)
            .fetchAll(db)

        let workspaceBoards: [Board]
        if let userId {
            workspaceBoards = try Board
                .filter(Column("userId") == userId && Column("isDeleted") == false)
                .order(Column("updatedAt").desc)
                .fetchAll(db)
        } else {
            workspaceBoards = []
        }

        let workspaceTemplates: [RecurringBoardTemplate]
        if let userId {
            workspaceTemplates = try RecurringBoardTemplate
                .filter(Column("userId") == userId && Column("isDeleted") == false)
                .order(Column("updatedAt").desc)
                .fetchAll(db)
        } else {
            workspaceTemplates = []
        }

        let workspaceBoardTasks = try BoardTask
            .filter(Column("isDeleted") == false)
            .fetchAll(db)

        // Windowed Completion — group non-deleted events by taskId so the grid
        // + tap handlers resolve each event-owning square windowed.
        let events: [TaskEvent]
        if let userId {
            events = try TaskEvent
                .filter(Column("userId") == userId && Column("isDeleted") == false)
                .fetchAll(db)
        } else {
            events = []
        }
        var eventsByTaskId: [String: [TaskEvent]] = [:]
        for e in events { eventsByTaskId[e.taskId, default: []].append(e) }

        return TaskDataPayload(
            boardTasks: boardTasks,
            allTasks: tasks,
            allCompoundChildren: children,
            allBoardsInWorkspace: workspaceBoards,
            allTemplatesInWorkspace: workspaceTemplates,
            allBoardTasksInWorkspace: workspaceBoardTasks,
            windowEventsByTaskId: eventsByTaskId
        )
    }

    /// Rebuild `kernelCellStates` from the freshly-applied published data.
    /// Called at the end of `apply(_:)` — `reload()` assigns `board` just
    /// before calling it, so every board/data change funnels through here.
    private func rebuildKernelCellStates() {
        guard let board else { kernelCellStates = [:]; return }
        var childrenByCompound: [String: [CompoundChild]] = [:]
        for c in allCompoundChildren {
            childrenByCompound[c.compoundTaskId, default: []].append(c)
        }
        for id in childrenByCompound.keys {
            childrenByCompound[id]?.sort { $0.childIndex < $1.childIndex }
        }
        let resolved = PlacementIntegrity.resolvePlacements(boardTasks, boardSize: board.boardSize)
        let built = DerivationPass.computeBoardGrid(
            board: board,
            boardTasksOnBoard: resolved,
            childrenByCompound: childrenByCompound,
            taskById: taskMap,
            allBoards: allBoardsInWorkspace,
            windowContext: WindowEvaluationContext(eventsByTaskId: windowEventsByTaskId)
        )
        var out: [String: DerivationPass.CellState] = [:]
        for c in built.cells {
            // boardTaskId is non-optional — every CellState maps to a real
            // placement (the FREE-center auto-fill emits no CellState).
            out[c.boardTaskId] = c
        }
        kernelCellStates = out
    }

    private func apply(_ payload: TaskDataPayload) {
        boardTasks = payload.boardTasks
        allTasks = payload.allTasks
        allCompoundChildren = payload.allCompoundChildren
        allBoardsInWorkspace = payload.allBoardsInWorkspace
        allTemplatesInWorkspace = payload.allTemplatesInWorkspace
        allBoardTasksInWorkspace = payload.allBoardTasksInWorkspace
        windowEventsByTaskId = payload.windowEventsByTaskId
        rebuildKernelCellStates()

        // Shared Counters P3 — passive-completion detection. On a board-open
        // reload (flagged), diff the freshly-applied shared-counting squares
        // against the device-local last-seen snapshot and emit an arrival if
        // any increased. Otherwise (a local-tap reload on the already-detected
        // board) keep the baseline current so leaving + returning stays quiet.
        if shouldDetectArrivals {
            shouldDetectArrivals = false
            detectArrivalsAndSeed()
        } else if let detected = arrivalDetectedBoardId, detected == boardId {
            arrivalStore.save(
                boardId: boardId,
                snapshot: snapshotCounterSquares(squares: sharedCounterArrivalSquares())
            )
        }
    }

    // MARK: - Passive completion (Shared Counters P3)

    /// Build the board's current shared-counting `ArrivalSquare`s from the
    /// loaded placements + task graph. One entry per COUNTING square that is a
    /// linked derived counter or a source with ≥1 linked task. `displayed` is
    /// baseline-adjusted for linked members (via `deriveDisplayedCount` — the
    /// lifetime carve-out) and the board-WINDOWED count for sources (issue
    /// #377) — matching what the grid cell shows.
    ///
    /// Mirrors the web `buildArrivalSquares` pure adapter.
    func sharedCounterArrivalSquares() -> [ArrivalSquare] {
        let map = taskMap
        var out: [ArrivalSquare] = []
        for bt in boardTasks {
            guard let task = map[bt.taskId], task.type == .counting else { continue }

            let counterId: String
            if let source = task.sharedCounterId {
                counterId = source
            } else if allTasks.contains(where: { $0.sharedCounterId == task.id && !$0.isDeleted })
                || task.isCounter == true {
                // P5: a promoted zero-link counter (no members yet) is still
                // its own source — mirrors web `useBoardPlayData.ts:176`
                // (`if (t.isCounter === true) sources.add(t.id)`), so it
                // participates in arrival detection from the moment it's
                // promoted, not just once a first member links to it.
                counterId = task.id
            } else {
                continue  // Not part of a shared-counter group.
            }

            let displayed: Int
            if task.sharedCounterId != nil {
                displayed = deriveDisplayedCount(
                    derivedBaseline: task.baseline ?? 0,
                    derivedMaxCount: task.maxCount ?? 0,
                    sourceCurrentCount: task.currentCount ?? 0
                ).displayed
            } else {
                // Issue #377: a SOURCE counting square's grid cell shows the
                // board-WINDOWED count, so the arrival baseline must match —
                // the lifetime cache desyncs when a library decrement
                // tombstones a pre-window event. Mirrors web
                // `buildArrivalSquares`.
                displayed = windowedState(forTaskId: task.id).count
            }

            out.append(ArrivalSquare(
                taskId: task.id,
                counterId: counterId,
                counterName: Self.counterDisplayName(map[counterId]),
                displayed: displayed
            ))
        }
        return out
    }

    /// The counter's display name — pair-derived via
    /// `CounterName.formatCounterName(action, unit)`, falling back to the
    /// source task's stored title only when the pair can't produce one
    /// (R3 board-play touchpoints copy contract: NEVER raw `task.title` for
    /// the COUNTER name — matches `SharedCounterGroups.swift`'s `name`
    /// derivation and the Counters Hub/Detail labels verbatim).
    private static func counterDisplayName(_ source: Task?) -> String {
        guard let source = source else { return "" }
        let derived = CounterName.formatCounterName(action: source.action, unit: source.unit)
        return derived.isEmpty ? source.title : derived
    }

    /// A task's own SQUARE display name — its stored title (e.g. "Do 200
    /// push-ups"), never the pair-derived counter name. R3 copy contract:
    /// the arrival banner's single-square `{taskTitle}` names the SQUARE,
    /// distinct from `counterDisplayName`'s counter reference — see
    /// `detectArrivalsAndSeed`'s `singleTaskName`. Falls back to
    /// `TaskTitle.generateCounterTaskTitle` only when the stored title is
    /// blank (defensive — every counting task's title is stamped at
    /// creation, so this should not normally trigger).
    private static func taskSquareDisplayName(_ task: Task?) -> String {
        guard let task = task else { return "" }
        let trimmed = task.title.trimmingCharacters(in: .whitespaces)
        if !trimmed.isEmpty { return trimmed }
        return TaskTitle.generateCounterTaskTitle(
            action: task.action ?? "",
            maxCount: task.maxCount,
            unit: task.unit ?? ""
        )
    }

    /// Run the once-per-open detect: diff current squares vs the stored last-seen,
    /// seed/refresh the baseline (so an acknowledged arrival or fresh first view
    /// won't re-fire), and emit `arrivalEvent` when anything arrived.
    private func detectArrivalsAndSeed() {
        let squares = sharedCounterArrivalSquares()
        let lastSeen = arrivalStore.lastSeen(boardId: boardId)
        let result = detectCounterArrivals(lastSeen: lastSeen, squares: squares)

        // Seed / refresh the baseline immediately (after-shown + first-view
        // baseline). Establishing it on a fresh first view is what lets the
        // NEXT cross-surface log be caught.
        arrivalStore.save(boardId: boardId, snapshot: snapshotCounterSquares(squares: squares))
        arrivalDetectedBoardId = boardId

        guard result.totalArrivedSquares > 0 else { return }

        // Resolve the single-square copy's TASK name (the SQUARE's own
        // title, e.g. "Do 200 push-ups") from the one arrived square. R3
        // copy contract: this is deliberately NOT `counterDisplayName` (that
        // function is pair-derived and reserved for the COUNTER reference —
        // see `CounterArrivalEvent.singleTaskName`'s doc). Falls back to the
        // pair-derived name only in the defensive case of a blank stored
        // title (should not happen — `TaskTitle.generateCounterTaskTitle`
        // stamps the title at creation).
        let map = taskMap
        let singleTaskName: String? = result.totalArrivedSquares == 1
            ? result.arrivedTaskIds.first.flatMap { id in map[id].map { Self.taskSquareDisplayName($0) } }
            : nil

        arrivalEventCounter += 1
        arrivalEvent = CounterArrivalEvent(
            id: arrivalEventCounter,
            arrivedTaskIds: Set(result.arrivedTaskIds),
            arrivedCounters: result.arrivedCounters,
            totalArrivedSquares: result.totalArrivedSquares,
            singleTaskName: singleTaskName
        )
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
        /// Windowed Completion — non-deleted TaskEvents grouped by taskId.
        let windowEventsByTaskId: [String: [TaskEvent]]
    }
}

// MARK: - SharedCounterCreditToastPayload

/// The credited toast's copy + the data its Undo pill needs (R3 board-play
/// touchpoints — unifies the board-play ripple toast with R2's
/// `CounterLogToastView`, which now renders arbitrary `message` text with an
/// Undo affordance instead of only its own verb-derived copy).
struct SharedCounterCreditToastPayload: Equatable {
    /// The shared counter's SOURCE task id — `Undo` reverses THIS counter's
    /// last log entry via `AppDatabase.undoLastCounterLog(sourceTaskId:)`,
    /// regardless of which board square triggered the toast.
    let sourceTaskId: String
    /// The amount just logged/removed — matches what Undo will reverse
    /// (decrement uses the CLAMPED `effectiveDelta`, not the requested amount).
    let amount: Int
    let unit: String
    let isIncrement: Bool
    /// Full pinned copy contract string — see `sharedCreditToastText`.
    let message: String
}

// MARK: - BoardPlayFlashEvent

/// One-shot UI-effect signal published by `BoardPlayViewModel` after an
/// interaction write completes. The write itself + all domain-state mutation
/// (board stats, sync rows, the `@Published` arrays) happen in the view model;
/// this carries ONLY the residual view-side animation triggers the view owns
/// (`triggerRisoNotification(from:)` + `triggerCreditToast(payload:)`), which
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
    /// Payload for the view's `triggerCreditToast(payload:)` (shared-counter
    /// ripple). Nil ⇒ the ripple reached no OTHER board.
    let creditToast: SharedCounterCreditToastPayload?
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

// MARK: - CounterArrivalEvent

/// One-shot passive-completion signal published by `BoardPlayViewModel` on a
/// board-open when ≥1 shared-counter square filled in from a log made elsewhere
/// (Shared Counters P3). The detection + baseline-seeding happen in the view
/// model; this carries only what the view needs to drive the gold
/// `RisoArrivalBanner` + the per-square pulse (both view-owned `@State`).
///
/// Mirrors `BoardPlayFlashEvent`'s one-shot pattern — a monotonic `id` keeps
/// consecutive emissions distinct for the view's `.onChange`, even if the same
/// squares arrive again.
struct CounterArrivalEvent: Identifiable, Equatable {
    let id: Int
    /// Arrived square task ids — drives the per-cell gold pulse.
    let arrivedTaskIds: Set<String>
    /// Distinct arrived counters (sorted by name) — drives the tap target
    /// (single counter → its Detail; multiple → the Counters Hub).
    let arrivedCounters: [ArrivedCounter]
    /// Total arrived squares — selects the single-vs-multiple banner copy.
    let totalArrivedSquares: Int
    /// The arrived square's task name for the single-square copy (nil for the
    /// multiple-squares variant).
    let singleTaskName: String?
}
