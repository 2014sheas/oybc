import SwiftUI
import UIKit
import GRDB

// NOTE (B2-I2 → B4): the play-interaction WRITE layer moved to
// `ViewModels/BoardPlayViewModel.swift`, then in B4 the write transactions
// themselves (task completion + compound-child fallback + their sync/cascade
// enqueue) were absorbed into `AppDatabase` (`completeTaskOrchestrated` /
// `toggleCompoundChildFallback` / `runBoardCascadeForTaskWithResults` +
// `CascadeBoardResult` in `Database/AppDatabase+Tasks.swift`). This view
// delegates every write (tap / stepper / swap / add / remove) to the view
// model and observes its one-shot `flashEvent` to fire the residual view-side
// toast/overlay animations.

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

// MARK: - CreditToastState (P2/R3 — shared-counter credited toast)

/// The showing credited toast's render + Undo inputs, derived from a
/// `SharedCounterCreditToastPayload` flash event. A distinct `toastKey`
/// (fresh `UUID` per trigger) drives `CounterLogToastView`'s `.id(...)` so
/// back-to-back logs restart the auto-dismiss timer cleanly — mirrors
/// `CounterDetailView`'s `DetailToastState` pattern.
private struct CreditToastState {
    /// The shared counter's SOURCE task id — what `Undo` reverses.
    let sourceTaskId: String
    let amount: Int
    let unit: String
    let verb: CounterLogToastView.Verb
    let message: String
    let toastKey: String
}

// MARK: - ArrivalBannerData / ArrivalNavTarget (Shared Counters P3)

/// The showing arrival-banner's copy inputs, derived from a `CounterArrivalEvent`.
private struct ArrivalBannerData {
    /// Total arrived squares — selects the single-vs-multiple copy.
    let squareCount: Int
    /// The arrived square's task name (single-square variant only).
    let taskName: String?
    /// The arrived counter's display name (single-square variant only).
    let counterName: String?
    /// The distinct arrived counters — resolves the tap target.
    let arrivedCounters: [ArrivedCounter]
}

/// Sheet-presented navigation target when the arrival banner is tapped.
/// A single distinct arrived counter opens its Counter Detail; multiple
/// counters (the "N squares … your counters" copy names none in particular)
/// open the Counters Hub.
private enum ArrivalNavTarget: Identifiable {
    case counter(String)
    case hub

    var id: String {
        switch self {
        case .counter(let counterId): return "counter-\(counterId)"
        case .hub: return "hub"
        }
    }
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

    // Interaction write-state now lives on the view model (B2-I2). Read-only
    // shim so the many render sites that gate on `isProcessing` are untouched;
    // `bingoMessage` is read/written through `viewModel.bingoMessage` directly.
    private var isProcessing: Bool { viewModel.isProcessing }
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
    // MARK: P2/R3 — Shared-counter credited toast
    /// The showing credited toast's data (message + Undo target), or nil
    /// when no toast is up. R3: unified onto `CounterLogToastView` (amount-
    /// aware copy + Undo pill) — see `triggerCreditToast(payload:)`.
    @State private var creditToast: CreditToastState? = nil
    /// Board task id of the counting cell whose stepper sheet is open.
    @State private var countingStepperBoardTaskId: String?
    // MARK: P3 — Shared-counter arrival banner (passive completion)
    /// The showing arrival banner's data, or nil when no banner is up.
    @State private var arrivalBanner: ArrivalBannerData? = nil
    /// Arrived square task ids — drives the per-cell gold pulse.
    @State private var arrivedTaskIds: Set<String> = []
    /// Monotonic token so only the latest arrival's ~5.2s auto-clear fires.
    @State private var arrivalBannerGeneration: Int = 0
    /// Sheet-presented nav target for the banner tap (Counter Detail / Hub).
    @State private var arrivalNavTarget: ArrivalNavTarget? = nil
    @State private var detailBoardTaskId: String?
    /// Drives the task-detail library sheet (separate from the board-play detail sheet).
    @State private var taskDetailSheetTaskId: TaskIdItem?
    /// Child task detail opened from INSIDE the on-board detail sheet (the
    /// compound child ⓘ button). Deliberately a separate item from
    /// `taskDetailSheetTaskId`: that sheet presents from the view root, and
    /// SwiftUI silently queues a sibling sheet until the detail sheet is
    /// manually dismissed. This item's sheet presents from the detail
    /// sheet's own content instead, stacking immediately — matching web's
    /// overlay behavior (DetailModal + TaskDetailSheet are independent).
    @State private var compoundChildDetailTaskId: TaskIdItem?
    /// Windowed Completion (docs Decision 9 + §Write paths — "the toggle is
    /// disabled with an explanatory affordance"). Task ids whose un-complete
    /// affordance in `detailSheet` would be inert because every live
    /// completion is sealed-window-immune. Populated on-demand when the
    /// detail sheet opens (see `loadSealBlockedTaskIds`), not per grid render.
    @State private var sealBlockedTaskIds: Set<String> = []
    // MARK: Edit-mode draft state (Phase 1 board-edit chrome)
    // NOTE (B2-I3): the edit-draft *data* layer moved to `BoardPlayViewModel`.
    // The `BoardEditPanel`'s seven two-way bindings are now `$viewModel.editName`
    // … projections, and the staged-square dictionaries + draft-derived helpers
    // + the seed/save/archive commit live on the view model. The view keeps only
    // the render-level edit chrome below (`editMode` overlay gate, the Save
    // spinner mirror, the alert/toast flags, and the cell-menu routing state).
    /// True while the in-place `BoardEditPanel` is overlaid on `BoardPlayView`.
    @State private var editMode: Bool = false
    /// True while a `handleEditSave` commit is in flight — disables the Save
    /// pill. UI mirror driven by `viewModel.handleEditSave`'s return value +
    /// `viewModel.editEvent`; the authoritative re-entry guard is VM-side.
    @State private var editSaving: Bool = false
    /// Surfaces a board-edit Save failure (the edit panel overlays the inline
    /// flash, so a system alert is used — it pierces the overlay).
    @State private var editSaveError: String?
    /// Controls the "Board saved" success toast (auto-dismissed after 2.4 s).
    @State private var showEditSavedToast: Bool = false
    // MARK: Edit-mode squares draft (Phase 2 — Edit tasks)
    // NOTE (B2-I3): `editSquaresDraft` / `editTaskOverrides` moved to the view
    // model (read via `viewModel.editSquaresDraft` / `.editTaskOverrides`).
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
    /// M4 — live-edit add to empty cell: the grid position awaiting task selection.
    @State private var addCellPos: (row: Int, col: Int)? = nil
    /// M4 — tracks whether the add-cell sheet was dismissed via a confirmed selection.
    /// `onDismiss` skips the reload when true because `handleAddTaskToCell` already reloads.
    @State private var addTaskConfirmed: Bool = false
    // NOTE (B2-I3): `editRearrangeCells` moved to the view model (read via
    // `viewModel.editRearrangeCells`).

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

    /// O(1) task lookup by task ID. Delegates to the view model (B2-I2), which
    /// owns the same lookup for its interaction handlers.
    private var taskMap: [String: Task] { viewModel.taskMap }

    // MARK: - Windowed reads (Windowed Completion)

    /// The current board's window lower bound (`board.startDate`). Every
    /// event-owning square resolves against `[windowStart, ∞)`.
    private var windowStart: String? { viewModel.windowStart }

    /// The workspace's non-deleted TaskEvents grouped by taskId (from the VM).
    private var windowEventsByTaskId: [String: [TaskEvent]] { viewModel.windowEventsByTaskId }

    /// The compound window context for the current board — passed into
    /// `CompoundEvaluation.evaluate` so compound squares resolve their primitive
    /// children windowed (docs §Semantics). Derived-counting children are carved
    /// out inside the kernel.
    private var boardWindowContext: CompoundWindowContext {
        CompoundWindowContext(windowStart: windowStart, eventsByTaskId: windowEventsByTaskId)
    }

    /// Windowed completed state of an event-owning primitive square. Callers must
    /// branch derived / compound / achievement before calling.
    private func windowedIsCompleted(_ task: Task) -> Bool {
        resolveTaskWindowState(
            task: task,
            events: windowEventsByTaskId[task.id] ?? [],
            windowStart: windowStart
        ).isCompleted
    }

    /// Windowed count of an event-owning counting square (source / plain).
    private func windowedCount(_ task: Task) -> Int {
        resolveTaskWindowState(
            task: task,
            events: windowEventsByTaskId[task.id] ?? [],
            windowStart: windowStart
        ).count
    }

    // MARK: - Edit-mode squares draft (Phase 2)
    //
    // NOTE (B2-I3): `editDraftBoardTasks` / `editDraftTaskMap` /
    // `editSquaresEditCount` / `countPositionMoves` moved to `BoardPlayViewModel`
    // (read via `viewModel.editDraftBoardTasks` etc.). `editCellMenuTitle`
    // stays here — it reads view-owned state (the cell-menu routing / `editMode`)
    // alongside the VM draft state.

    /// Display title for the tap-menu confirmationDialog.
    ///
    /// - For a free-center tap (no draft entry): returns "Center square".
    /// - For any task cell: returns the staged task title.
    private var editCellMenuTitle: String {
        // Free center tap has no squaresDraft entry — give it a clear title.
        if editCellMenuIsCenter
            && (viewModel.editCenterType == .free || viewModel.editCenterType == .customFree) {
            return "Center square"
        }
        let key = "\(editCellMenuRow)-\(editCellMenuCol)"
        guard let draft = viewModel.editSquaresDraft[key] else { return "Square" }
        let map = viewModel.editDraftTaskMap
        return map[draft.stagedTaskId]?.title ?? "Square"
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

    /// Board-integrity PR-3 — kernel-derived per-cell state for THIS board,
    /// keyed by `boardTaskId`. `DerivationPass.computeBoardGrid` is now the
    /// ONE implementation of the ACHIEVEMENT branch (trigger/reference
    /// resolution); this re-runs it against the same live inputs already
    /// assembled for compound/primitive rendering below and is consulted
    /// ONLY for achievement cells (`risoPlaySquare`'s achievement branch,
    /// `achievementBadge(for:)`, `achievementDetailContent`) — those three
    /// surfaces used to hand-copy the trigger/meets/spawn-filter logic
    /// separately and could drift; now they can't. Compound + windowed-
    /// primitive cells keep resolving inline above (their `@Published`-backed
    /// reactive paths), per the PR-3 judgment rule: at most one thin
    /// windowed-primitive path outside the kernel, with the achievement
    /// branch unified. Not used for sealed boards — those short-circuit to
    /// the frozen `sealedCompletedCells` snapshot before ever consulting this.
    ///
    /// Stored on the VM (rebuilt once per `apply(_:)` data change) rather
    /// than computed here — the review flagged that a computed property runs
    /// the full kernel pass once per rendered CELL (O(size²) derivations per
    /// render).
    private var kernelCellStates: [String: DerivationPass.CellState] {
        viewModel.kernelCellStates
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
    ///
    /// Board-integrity PR-2 (Part 2): resolves `boardTasks` through
    /// `PlacementIntegrity.resolvePlacements` first, so a raw duplicate row
    /// (pre-repair, or a sealed board whose corrupt rows aren't touched by
    /// the repair pass's stats side) can't make this map disagree with what
    /// derivation counted — both consume the SAME deterministic winner.
    private var btByPosition: [String: BoardTask] {
        var map: [String: BoardTask] = [:]
        for bt in PlacementIntegrity.resolvePlacements(boardTasks, boardSize: gridSize) {
            map["\(bt.row)-\(bt.col)"] = bt
        }
        return map
    }

    /// Whether the current board is a frozen, read-only historical record
    /// (docs §Effects of sealed: "Not editable" — a sealed board can never be
    /// interacted with again). Sealing REPLACES the old expiry lock: an
    /// expired-but-unsealed board stays fully live (docs §Lifecycle — the
    /// closing-out banner's Log action opens it to log late activity) until
    /// the user seals it or the backstop does. Gates every play interaction:
    /// tap-to-complete, counter stepper, context-menu actions, the empty-cell
    /// "+" add affordance, and the toolbar Edit entry. Delegates to the
    /// standalone `isBoardPlayLocked` predicate (Helpers/Sealing.swift) so
    /// the gating rule is unit-testable.
    private var isBoardLocked: Bool {
        guard let b = board else { return false }
        return isBoardPlayLocked(b)
    }

    /// Windowed Completion — whether the current board is sealed (docs
    /// §Effects of sealed). Sealed boards render read-only from
    /// `sealedCompletedCells` rather than live event queries.
    private var isSealed: Bool {
        board?.sealedAt != nil
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

                        // ── Sealed banner (below grid) ── locked == sealed;
                        // an expired-but-unsealed board stays live (no banner).
                        if isBoardLocked {
                            Text("Board closed — a permanent record")
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

            // ── P3: Shared-counter arrival banner (drops from top) ──
            if let banner = arrivalBanner {
                RisoArrivalBanner(
                    squareCount: banner.squareCount,
                    taskName: banner.taskName,
                    counterName: banner.counterName,
                    onOpen: { openArrivalTarget(banner) },
                    onDismiss: dismissArrivalBanner
                )
                .padding(.horizontal, Riso.gutter)
                .padding(.top, 54)
                .transition(
                    .asymmetric(
                        insertion: .move(edge: .top).combined(with: .opacity),
                        removal: .move(edge: .top).combined(with: .opacity)
                    )
                )
                .zIndex(12)
            }

            // ── P2/R3: Shared-counter credited toast (slides from bottom) ──
            // Unified onto `CounterLogToastView` (R2) via its `message`
            // override — same card chrome as the Counters Hub/Detail toasts,
            // now with the pinned "+N counterName — also counted on…" copy
            // and an Undo pill that reverses the whole logged entry.
            if let creditToast {
                VStack {
                    Spacer()
                    CounterLogToastView(
                        amount: creditToast.amount,
                        unit: creditToast.unit,
                        verb: creditToast.verb,
                        message: creditToast.message,
                        onUndo: {
                            viewModel.undoSharedCounterLog(sourceTaskId: creditToast.sourceTaskId)
                            withAnimation(.easeOut(duration: 0.2)) { self.creditToast = nil }
                        },
                        onDone: {
                            withAnimation(.easeOut(duration: 0.2)) { self.creditToast = nil }
                        }
                    )
                    .padding(.horizontal, Riso.gutter)
                    .padding(.bottom, 100)
                }
                .id(creditToast.toastKey)
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
                    boardTasks: viewModel.editDraftBoardTasks,
                    taskMap: viewModel.editDraftTaskMap,
                    weekStartDay: authService.currentUser?.decodedPreferences.weekStartDay.rawValue ?? "monday",
                    originalCustomStartDate: viewModel.editOriginalCustomStartDate,
                    originalCustomEndDate: viewModel.editOriginalCustomEndDate,
                    // B2-I3: the seven two-way bindings are now `$viewModel.…`
                    // projections (`@StateObject` projections are two-way, so
                    // these behave exactly like the pre-move `@State` bindings).
                    name: $viewModel.editName,
                    timeframe: $viewModel.editTimeframe,
                    customStartDate: $viewModel.editCustomStartDate,
                    customEndDate: $viewModel.editCustomEndDate,
                    centerType: $viewModel.editCenterType,
                    centerCustomName: $viewModel.editCenterCustomName,
                    hasCandidateTasks: viewModel.editHasCandidateTasks,
                    subMode: $viewModel.editSubMode,
                    squareEditCount: viewModel.editSquaresEditCount,
                    onCellTap: { row, col in handleEditCellTap(row: row, col: col) },
                    // Phase 2b — center toggle (free center → task square).
                    onCenterTap: handleFreeCenterTap,
                    // Phase 3 — Rearrange
                    rearrangeCells: viewModel.editRearrangeCells,
                    onReorder: viewModel.handleRearrange,
                    // Windowed Completion parity (d16ff21, sub-slice 3 review
                    // finding): the edit/rearrange preview must show the
                    // WINDOWED state, not the lifetime cache.
                    windowedIsCompleted: viewModel.windowedIsCompleted,
                    isSaving: editSaving,
                    onSave: {
                        let weekStart = authService.currentUser?.decodedPreferences
                            .weekStartDay.rawValue ?? "monday"
                        // The VM validates + dispatches the commit; it returns
                        // true iff the save actually started, so `editSaving`
                        // (view-owned) flips synchronously in the same tick the
                        // pre-move code did — the reset runs on `.editEvent`.
                        if viewModel.handleEditSave(weekStartDay: weekStart) {
                            editSaving = true
                        }
                    },
                    onCancelConfirmed: {
                        withAnimation(.easeInOut(duration: 0.22)) { editMode = false }
                    },
                    onArchiveConfirmed: viewModel.handleEditArchive
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.risoPaper.ignoresSafeArea())
                .transition(.opacity)
                .zIndex(30)
                // Phase 3 — seed rearrange cells lazily on sub-mode switch to
                // Rearrange. Kept as a view `.onChange` (observing the VM's
                // published `editSubMode`) rather than a VM `didSet`: SwiftUI's
                // onChange fires AFTER the view update, a `didSet` fires
                // synchronously before it — preserving the post-update timing
                // matters here (see the B2-I3 report), so this stays an observer.
                .onChange(of: viewModel.editSubMode) { _, newMode in
                    if newMode == .rearrange {
                        viewModel.seedRearrangeCells(for: b)
                    }
                }
                // Phase 2b — when center type changes (via the toggle or the
                // BoardSetupFormView picker), rebuild the staged rearrange cells
                // so the Rearrange sub-mode immediately reflects the new pinning.
                // If no rearrange cells exist yet, seedRearrangeCells will build
                // them with the correct type on the next sub-mode switch. Same
                // onChange-vs-didSet rationale as above.
                .onChange(of: viewModel.editCenterType) { _, newType in
                    guard let current = viewModel.editRearrangeCells else { return }
                    // Preserve any staged rearrange order: map each non-center,
                    // non-empty cell's CURRENT slot index back to (row, col) and pass
                    // it as the positionDraft, so changing the center type doesn't
                    // discard the user's in-progress rearrange.
                    let size = b.boardSize
                    var positions: [String: (row: Int, col: Int)] = [:]
                    for (i, cell) in current.enumerated() where !cell.isCenter && !cell.isEmpty {
                        positions[cell.id] = (row: i / size, col: i % size)
                    }
                    viewModel.editRearrangeCells = buildRearrangeCells(
                        squaresDraft: viewModel.editSquaresDraft,
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
            // Windowed Completion — a sealed board is never editable (docs
            // §Effects of sealed: rearranging squares under a frozen snapshot
            // would desync the frozen record; no unseal gesture in v1).
            if let b = board, b.status == .active, !embedded, !editMode, !isSealed {
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button("Edit") {
                        viewModel.seedEditDraft(from: b)
                        // The pre-move `seedEditDraft` reset `editSaving = false`
                        // inline; `editSaving` stays view-side, so reset it here.
                        editSaving = false
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
            if viewModel.editSquaresDraft[cellKey] != nil {
                Button("Replace task") {
                    if let draft = viewModel.editSquaresDraft[cellKey] {
                        editModeReplaceTarget = EditModeSwapTarget(
                            id: cellKey,
                            currentTaskId: draft.stagedTaskId
                        )
                    }
                }
                Button("Edit task") {
                    if let draft = viewModel.editSquaresDraft[cellKey] {
                        let map = viewModel.editDraftTaskMap
                        if let task = map[draft.stagedTaskId] {
                            editModeTaskTarget = EditModeTaskTarget(id: cellKey, task: task)
                        }
                    }
                }
                // Staged removal — empties the cell in the draft; the placement
                // is only deleted from the DB on Save (handleEditSave). A free
                // center has no draft entry so this block is skipped for it,
                // keeping a pinned center non-removable.
                Button("Remove from board", role: .destructive) {
                    viewModel.handleEditRemove(cellKey: cellKey)
                }
            }

            // Phase 2b — Center toggle buttons. Only shown when the tapped cell
            // is the positional center. .chosen is intentionally excluded — the
            // BoardSetupFormView chrome is the way out of CHOSEN.
            if editCellMenuIsCenter {
                if viewModel.editCenterType == .free || viewModel.editCenterType == .customFree {
                    // Free center → task square (empty; fill via the live "+" flow).
                    // The .onChange(of: editCenterType) handler rebuilds the rearrange
                    // cells (preserving any staged order) — no inline rebuild here.
                    Button("Make it a task square") { viewModel.editCenterType = .none }
                } else if viewModel.editCenterType == .none {
                    // Task square (or empty slot) → free space.
                    Button("Make it a free space") { viewModel.editCenterType = .free }
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
                    viewModel.handleEditCellReplace(cellKey: target.id, newTaskId: newTaskId)
                }
            )
        }
        // Phase 2 — Edit task sheet (staged; no DB write on Done).
        .sheet(item: $editModeTaskTarget) { target in
            SquareEditTaskSheet(
                task: target.task,
                onDone: { patch in
                    editModeTaskTarget = nil
                    viewModel.handleEditTaskOverride(taskId: target.task.id, patch: patch)
                },
                onCancel: { editModeTaskTarget = nil }
            )
        }
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
                        viewModel.handleAddTaskToCell(taskId: taskId, row: pos.row, col: pos.col)
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
            // P3 — this board-open should run arrival detection on the reload
            // that follows (the reused pager instance uses boardChanged instead).
            viewModel.markArrivalDetectionPending()
            viewModel.reload()
        }
        .onDisappear {
            // P3 — re-snapshot the last-seen baseline on leaving so local taps
            // don't re-fire on the next open (belt-and-suspenders; the once-
            // per-open detect + local-tap reloads already keep it current).
            viewModel.snapshotArrivalsOnDisappear()
        }
        // Defensive: also reload on boardId prop change. With `.id(boardId)`
        // on the standalone destination, SwiftUI re-creates the view (and the
        // view model) so .onAppear fires — but the embedded core-board pager
        // reuses the SAME BoardPlayView instance (no `.id()`), so this points
        // the existing view model at the new board and reloads.
        .onChange(of: boardId) { _, newBoardId in
            viewModel.boardChanged(to: newBoardId)
        }
        // B2-I2 — the view model's interaction handlers publish a one-shot
        // `flashEvent` after each write; the view fires the residual toast /
        // overlay animations here (they read view `@State` + `AuthService`, so
        // they can't move into the view model). A single event may carry both a
        // bingo/GREENLOG notification and a shared-counter credit toast.
        .onChange(of: viewModel.flashEvent) { _, event in
            guard let event else { return }
            if let msg = event.risoNotification {
                triggerRisoNotification(from: msg)
            }
            if let payload = event.creditToast {
                triggerCreditToast(payload: payload)
            }
        }
        // P3 — passive-completion arrival. The VM detects + seeds the baseline
        // on a board-open reload and publishes this one-shot; the view drives
        // the gold banner + per-square pulse + the ~5.2s auto-clear (all
        // view-owned `@State`). Suppressed in edit mode.
        .onChange(of: viewModel.arrivalEvent) { _, event in
            guard let event, !editMode else { return }
            triggerArrivalBanner(from: event)
        }
        // B2-I3 — edit-commit outcome observer. The VM's `handleEditSave` /
        // `handleEditArchive` DB commits (+ the domain `reload()`) run VM-side;
        // this runs the residual view-owned UI mutations they still trigger
        // (which read view `@State` / the `dismiss` environment), reproducing
        // the pre-move MainActor tails exactly.
        .onChange(of: viewModel.editEvent) { _, event in
            guard let event else { return }
            switch event.outcome {
            case .saved:
                editSaving = false
                withAnimation(.easeInOut(duration: 0.22)) { editMode = false }
                triggerBoardSavedToast()
            case .saveFailed(let message):
                editSaving = false
                editSaveError = message
            case .archived:
                withAnimation(.easeInOut(duration: 0.22)) { editMode = false }
                dismiss()
            }
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
                // Windowed Completion — the stepper shows the WINDOWED count for
                // event-owning source/plain counters; derived members stay on the
                // baseline-derived display (carve-out).
                let displayed: Int = {
                    if task.sharedCounterId != nil {
                        return deriveDisplayedCount(
                            derivedBaseline: task.baseline ?? 0,
                            derivedMaxCount: maxVal,
                            sourceCurrentCount: rawCount
                        ).displayed
                    }
                    return windowedCount(task)
                }()
                // P2: Compute shared hint — other ACTIVE boards where a member
                // task lives, excluding the current board.
                let sharedHint: String? = sharedStepperHint(for: task)
                // R3: resolve the shared-counter SOURCE (if any) to gate the
                // amount-chip row and seed its "+{default}" chip — the chip
                // row is shared-counting-squares-only per the copy contract;
                // standalone counters keep the plain +/- stepper.
                let sourceId = viewModel.sharedCounterSourceId(for: task)
                let isSharedCounter = sourceId != nil
                let defaultLogAmount = sourceId.flatMap { taskMap[$0]?.defaultLogAmount }
                RisoCountingStepperSheet(
                    taskTitle: task.title,
                    currentCount: displayed,
                    maxCount: maxVal,
                    unitText: task.unit ?? "",
                    isLinkedCounter: isLinked,
                    sharedHint: sharedHint,
                    isSharedCounter: isSharedCounter,
                    defaultLogAmount: defaultLogAmount,
                    onIncrement: { amount, persistAsDefault in
                        viewModel.handleCountingTap(boardTask: bt, task: task, amount: amount, persistAsDefault: persistAsDefault)
                    },
                    onDecrement: { amount, persistAsDefault in
                        viewModel.handleCountingDecrement(boardTask: bt, task: task, amount: amount, persistAsDefault: persistAsDefault)
                    }
                    // Dismissal clears `countingStepperBoardTaskId` via the
                    // .sheet(isPresented:) binding setter above.
                )
            }
        }
        .sheet(isPresented: Binding(
            get: { detailBoardTaskId != nil },
            set: { if !$0 { detailBoardTaskId = nil } }
        ), onDismiss: {
            // Drains cross-board nav requested from the NESTED child detail
            // sheet (see `compoundChildDetailTaskId`): child dismiss closes
            // this sheet, then navigation lands here post-unmount — same
            // clean-transaction pattern as the library sheet below.
            if let target = pendingOpenBoardId {
                pendingOpenBoardId = nil
                onOpenBoard(target)
            }
            // Board-integrity PR-5 (Item 5): this sheet's own content
            // (`detailSheet`) can complete/edit the boardTask's task
            // directly, and its NESTED child-detail sheet
            // (`compoundChildDetailTaskId`) edits/deletes a compound
            // child's `Task` via `AppDatabase.shared` — neither write goes
            // through this VM, so refresh on dismiss the same way the M4
            // add-cell sheet does on cancel.
            viewModel.reloadBoardTasksAndTaskData()
        }) {
            detailSheet
        }
        // Windowed Completion — resolve seal-immunity for the un-complete
        // affordance(s) the detail sheet is about to show. On-demand (sheet
        // open only), not per grid render.
        .onChange(of: detailBoardTaskId) { _, newValue in
            loadSealBlockedTaskIds(for: newValue)
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
                // Board-integrity PR-5 (Item 5): this sheet edits/deletes its
                // task via `AppDatabase.shared` directly (bypasses this VM) —
                // refresh so the grid reflects an edited title/type or a
                // cascade-deleted placement.
                viewModel.reloadBoardTasksAndTaskData()
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
        // P3 — arrival banner tap → Counter Detail (single counter) / Counters
        // Hub (multiple). Presented as a sheet (wrapped in its own
        // NavigationStack so the destinations' member→board NavigationLinks work)
        // to match how this view presents every other secondary surface — and to
        // avoid a nav-push conflicting with the embedded pager's own chrome.
        .sheet(item: $arrivalNavTarget) { target in
            NavigationStack {
                switch target {
                case .counter(let counterId):
                    CounterDetailView(counterId: counterId)
                case .hub:
                    CountersHubView()
                }
            }
        }
    }

    // MARK: - Phase 6.3: per-cell achievement-task badge data

    /// Compute the achievement-task badge for one BoardTask. nil if the
    /// backing Task is not ACHIEVEMENT-typed (or the kernel has no
    /// achievement metadata for it — e.g. no reference set). Mirrors the
    /// TS-side `achievementBadgesByBoardTaskId` memo in BoardPlayPage.tsx.
    ///
    /// Board-integrity PR-3 — the met/count/required numbers come straight
    /// from `kernelCellStates`; only the display NAME lookups (board /
    /// template name) stay local, since names aren't part of the kernel's
    /// completion-derivation domain.
    private func achievementBadge(for bt: BoardTask) -> AchievementSquareBadgeData? {
        guard let task = taskMap[bt.taskId], task.type == .achievement else { return nil }
        guard let achievement = kernelCellStates[bt.id]?.achievement else { return nil }
        switch achievement.mode {
        case .specificBoard:
            let ref = achievement.referencedBoardId.flatMap { refId in
                allBoardsInWorkspace.first(where: { $0.id == refId && !$0.isDeleted })
            }
            return AchievementSquareBadgeData(
                mode: .specificBoard,
                referencedBoardName: ref?.name,
                referencedBoardCompleted: achievement.referencedBoardCompleted ?? false
            )
        case .recurringTemplate:
            let template = achievement.referencedTemplateId.flatMap { tid in
                allTemplatesInWorkspace.first(where: { $0.id == tid })
            }
            return AchievementSquareBadgeData(
                mode: .recurringTemplate,
                templateName: template?.name,
                templateInWindowMet: achievement.templateInWindowMet ?? 0,
                templateRequiredCount: achievement.templateRequiredCount ?? 0
            )
        }
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

            // Status badge (+ recurring-provenance tag, issue #321). Windowed
            // Completion — a sealed board shows the "Sealed" pill in place of
            // the live status badge (docs §Effects of sealed; OQ1 resolution).
            if let b = board {
                VStack(alignment: .trailing, spacing: 4) {
                    if b.sealedAt != nil {
                        RisoSealedBadge()
                    } else {
                        risoStatusBadge(status: b.status)
                    }
                    if RisoRecurringBadge.shouldShow(for: b) {
                        RisoRecurringBadge()
                    }
                }
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
    /// A custom board with an end date counts down like a timed board (it seals
    /// at that date too); only INDEFINITE / no-endDate boards read "No end".
    private func risoExpiryText(board: Board) -> String {
        guard !board.isIndefinite else { return "No end" }
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

    // MARK: - P2/R3: Shared-counter credited toast helpers

    /// Fires the credited toast for a shared-counter ripple that reached
    /// other boards. R3: mounts a fresh `CreditToastState` (distinct
    /// `toastKey`) so `CounterLogToastView`'s own `.id(...)`-scoped
    /// auto-dismiss `.task` restarts cleanly for back-to-back logs — the
    /// manual generation-token timer this used to hand-roll is now owned by
    /// the shared component (mirrors `CounterDetailView`'s toast pattern).
    ///
    /// - Parameter payload: The credited toast's copy + Undo target.
    private func triggerCreditToast(payload: SharedCounterCreditToastPayload) {
        withAnimation(.spring(response: 0.45, dampingFraction: 0.8)) {
            creditToast = CreditToastState(
                sourceTaskId: payload.sourceTaskId,
                amount: payload.amount,
                unit: payload.unit,
                verb: payload.isIncrement ? .logged : .removed,
                message: payload.message,
                toastKey: UUID().uuidString
            )
        }
    }

    // `sharedCreditToastText(counterName:otherBoards:isIncrement:)` moved to
    // `BoardPlayViewModel` (B2-I2) — its only callers are the shared-counter
    // handlers that now live there.

    // MARK: - P3: Shared-counter arrival banner helpers

    /// Shows the gold arrival banner + starts the per-square pulse from a
    /// one-shot `CounterArrivalEvent`, then schedules a ~5.2s auto-clear guarded
    /// by a generation token (a newer arrival supersedes the stale timer).
    ///
    /// - Parameter event: The VM's published arrival payload.
    private func triggerArrivalBanner(from event: CounterArrivalEvent) {
        let counterName = event.arrivedCounters.first?.counterName
        arrivalBanner = ArrivalBannerData(
            squareCount: event.totalArrivedSquares,
            taskName: event.singleTaskName,
            counterName: event.totalArrivedSquares == 1 ? counterName : nil,
            arrivedCounters: event.arrivedCounters
        )
        arrivedTaskIds = event.arrivedTaskIds
        arrivalBannerGeneration &+= 1
        let generation = arrivalBannerGeneration
        _Concurrency.Task.detached { @MainActor in
            try? await _Concurrency.Task.sleep(nanoseconds: 5_200_000_000)
            guard generation == arrivalBannerGeneration else { return }
            withAnimation(.easeOut(duration: 0.25)) {
                arrivalBanner = nil
            }
            arrivedTaskIds = []
        }
    }

    /// Dismiss the arrival banner immediately (the ✕ tap). Invalidates the
    /// pending auto-clear via the generation bump.
    private func dismissArrivalBanner() {
        arrivalBannerGeneration &+= 1
        withAnimation(.easeOut(duration: 0.2)) { arrivalBanner = nil }
        arrivedTaskIds = []
    }

    /// Resolve + present the banner's tap target: the single distinct arrived
    /// counter's Detail, or the Counters Hub when squares arrived from more than
    /// one counter.
    private func openArrivalTarget(_ data: ArrivalBannerData) {
        if data.arrivedCounters.count == 1 {
            arrivalNavTarget = .counter(data.arrivedCounters[0].counterId)
        } else {
            arrivalNavTarget = .hub
        }
        dismissArrivalBanner()
    }

    /// Computes the "↔ Shared · also counts on …" hint shown in the stepper sheet
    /// for a shared-counter task. Returns `nil` when the task is not in a shared group
    /// or has no OTHER active boards to mention.
    ///
    /// - Parameter task: The `Task` backing the tapped counting square.
    private func sharedStepperHint(for task: Task) -> String? {
        // R3: source detection extracted to `viewModel.sharedCounterSourceId(for:)`
        // — shares the exact same rule as the tap-routing handlers and the
        // chip-visibility gate below, instead of re-deriving it a third time.
        guard task.type == .counting, let sourceId = viewModel.sharedCounterSourceId(for: task) else {
            return nil
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
                    // FREE center cell — gold label, not interactive in play mode.
                    // A CUSTOM_FREE center shows its custom name (issue #345 —
                    // was hardcoded "FREE", discarding the stored name). Empty
                    // custom name / plain FREE falls back to "FREE" to match the
                    // wizard preview (RearrangeGrid) — deliberately NOT
                    // getCenterDisplayText, which would rename every plain FREE
                    // center to "FREE SPACE".
                    let centerName: String = {
                        guard b.centerSquareType == .customFree,
                              let custom = b.centerSquareCustomName?.trimmingCharacters(in: .whitespacesAndNewlines),
                              !custom.isEmpty
                        else { return "FREE" }
                        return custom
                    }()
                    RisoBoardPlayCell(
                        title: centerName,
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
        // Windowed Completion — a SEALED board renders `done` from the frozen
        // `sealedCompletedCells` snapshot (docs §Effects of sealed), never
        // live event queries (which could bleed a post-seal log of the same
        // task from another live board).
        let isCompleted: Bool = {
            if isSealed {
                return board?.sealedCompletedCells?.contains(index) ?? false
            }
            guard let task = task else { return false }
            if task.type == .compound {
                return CompoundEvaluation.evaluate(
                    compound: task,
                    childrenByCompound: compoundChildrenByCompound,
                    taskById: taskMap,
                    windowContext: boardWindowContext
                )
            }
            if task.type == .achievement {
                // Board-integrity PR-3 — the kernel's ACHIEVEMENT branch is
                // the single source of truth; see `kernelCellStates`.
                return kernelCellStates[boardTask.id]?.isCompleted ?? false
            }
            // Windowed Completion — derived counters (sharedCounterId set) stay
            // on their propagation-stamped lifetime cache (carve-out); every
            // other primitive resolves windowed via events.
            if task.sharedCounterId != nil { return task.isCompleted }
            return windowedIsCompleted(task)
        }()

        // Counting display values — windowed for event-owning source/plain
        // counters; baseline-derived for linked members (carve-out).
        let rawCount = task?.currentCount ?? 0
        let maxVal = task?.maxCount ?? 0
        let isLinkedCounter = task?.sharedCounterId != nil
        // Windowed Completion — only completion was snapshotted at seal time
        // (not partial progress), so a frozen counting square reads max/max
        // when green and 0/max otherwise — an honest read of what was frozen.
        let current: Int = {
            if isSealed { return isCompleted ? maxVal : 0 }
            guard let t = task else { return 0 }
            if t.sharedCounterId != nil {
                return deriveDisplayedCount(
                    derivedBaseline: t.baseline ?? 0,
                    derivedMaxCount: t.maxCount ?? 0,
                    sourceCurrentCount: rawCount
                ).displayed
            }
            if t.type == .counting { return windowedCount(t) }
            return rawCount
        }()

        // P2: Shared-counter marker — true for source tasks that have linked tasks
        // pointing at them, for linked tasks with sharedCounterId set, or (P5)
        // for a promoted zero-link counter (`isCounter == true`) — mirrors web
        // `useBoardPlayData.ts`'s `sharedCounterSourceIds` set exactly. R3:
        // routed through `viewModel.sharedCounterSourceId(for:)` (single
        // source of truth for this detection, shared with `sharedStepperHint`
        // and the tap-routing handlers).
        let isSharedCounterCell: Bool = {
            guard let t = task, t.type == .counting else { return false }
            return viewModel.sharedCounterSourceId(for: t) != nil
        }()

        // Compound child progress — mirrors original playSquare.
        let compoundLinks = task.map { compoundChildrenByCompound[$0.id] ?? [] } ?? []
        let compoundDoneCount = compoundLinks.filter { link in
            guard let childTask = taskMap[link.childTaskId], !childTask.isDeleted else { return false }
            if childTask.type == .compound {
                return CompoundEvaluation.evaluate(
                    compound: childTask,
                    childrenByCompound: compoundChildrenByCompound,
                    taskById: taskMap,
                    windowContext: boardWindowContext
                )
            }
            // Windowed child progress — carve out derived counters.
            if childTask.sharedCounterId != nil { return childTask.isCompleted }
            return windowedIsCompleted(childTask)
        }.count

        // Operator-aware completion target for the cell's progress bar —
        // mirrors web's DetailModal fractions (OR → any one child completes;
        // M_OF_N → threshold; AND → all children) and matches the
        // `CompoundEvaluation` semantics that color the cell green.
        let compoundRequiredCount: Int = {
            guard let t = task, t.type == .compound, !compoundLinks.isEmpty else {
                return compoundLinks.count
            }
            switch t.operatorType {
            case .or:        return 1
            case .mOfN:      return Swift.max(1, t.threshold ?? 1)
            case .and, nil:  return compoundLinks.count
            }
        }()

        let cellKind: CellTaskType = {
            switch taskType {
            case .normal:      return .normal
            case .counting:    return .counting
            case .compound:    return .compound
            case .achievement: return .achievement
            }
        }()

        // Positional center-ness (PR-5, parity with web): never trust the
        // row's OWN isCenter flag — a stray duplicate-center row (pre-guard
        // corruption) would misrender a real task as the gold center cell. A
        // placed cell renders center styling only when it actually SITS at
        // the positional center of a CHOSEN-center board.
        let renderAsCenter: Bool = {
            guard let b = board, gridSize % 2 == 1 else { return false }
            let isPositionalCenter = index / gridSize == gridSize / 2
                && index % gridSize == gridSize / 2
            return isPositionalCenter && b.centerSquareType == .chosen
        }()

        RisoBoardPlayCell(
            title: task?.title ?? "Unknown",
            taskType: cellKind,
            isCompleted: isCompleted,
            isBingoLine: highlighted.contains(index),
            isCenter: renderAsCenter,
            isLocked: isBoardLocked,
            currentCount: current,
            maxCount: maxVal,
            isSharedCounter: isSharedCounterCell,
            compoundDoneCount: compoundDoneCount,
            compoundChildCount: compoundLinks.count,
            compoundRequiredCount: compoundRequiredCount,
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
                    viewModel.handleNormalTap(boardTask: boardTask)
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
        // P3 — pulse the square when it just arrived from an elsewhere log.
        // Applied at the call site (not inside RisoBoardPlayCell) so the
        // snapshot-covered cell internals stay untouched.
        .arrivePulse(active: task.map { arrivedTaskIds.contains($0.id) } ?? false)
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
                viewModel.handleNormalTap(boardTask: boardTask)
            }
            .disabled(isProcessing || isBoardLocked)

            Button("View Details", systemImage: "info.circle") {
                detailBoardTaskId = boardTask.id
            }
            Button("Open in library", systemImage: "book") {
                taskDetailSheetTaskId = TaskIdItem(id: boardTask.taskId)
            }

        case .counting:
            if let t = task {
                let actionLabel = t.action ?? "item"
                // R3: shared counting squares use the counter's persisted
                // default amount for this quick single-tap action (was
                // hardcoded +1/-1) — the "#" custom entry still lives in the
                // stepper sheet's chip row; this menu quick-action never
                // persists a new default (mirrors the sheet's plain-tap rule).
                let quickAmount = viewModel.sharedCounterSourceId(for: t).flatMap { taskMap[$0]?.defaultLogAmount } ?? 1
                Button("+ Add \(quickAmount) \(actionLabel)", systemImage: "plus") {
                    guard !isBoardLocked else { return }
                    viewModel.handleCountingTap(boardTask: boardTask, task: t, amount: quickAmount)
                }
                // No maxVal gate — overshoot is a feature (never clamp);
                // matches the cell-tap stepper + detail-sheet stepper.
                .disabled(isProcessing || isBoardLocked)
                Button("− Remove \(quickAmount) \(actionLabel)", systemImage: "minus") {
                    guard !isBoardLocked else { return }
                    viewModel.handleCountingDecrement(boardTask: boardTask, task: t, amount: quickAmount)
                }
                // P2: isLinkedCounter no longer disables − (decrementSharedCounter handles fan-out).
                .disabled(current == 0 || isProcessing || isBoardLocked)
                Button("View Details", systemImage: "info.circle") {
                    detailBoardTaskId = boardTask.id
                }
                Button("Open in library", systemImage: "book") {
                    taskDetailSheetTaskId = TaskIdItem(id: t.id)
                }
            }

        case .compound:
            Button("View Children", systemImage: "list.bullet") {
                detailBoardTaskId = boardTask.id
            }
            Button("Open in library", systemImage: "book") {
                taskDetailSheetTaskId = TaskIdItem(id: boardTask.taskId)
            }

        case .achievement:
            Button("View Details", systemImage: "info.circle") {
                detailBoardTaskId = boardTask.id
            }
            Button("Open in library", systemImage: "book") {
                taskDetailSheetTaskId = TaskIdItem(id: boardTask.taskId)
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
                                achievementDetailContent(boardTask: bt, task: task)
                            }
                        }
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 24)
                    }
                }
            }
            .presentationDetents([.medium, .large])
            // Nested child detail — presented from the detail sheet's own
            // content so it stacks immediately instead of waiting for the
            // parent to dismiss (SwiftUI queues sibling sheets on one host).
            .sheet(
                item: $compoundChildDetailTaskId,
                onDismiss: {
                    // Cross-board nav from the nested sheet: also close the
                    // parent detail sheet; its onDismiss drains
                    // `pendingOpenBoardId` in a clean transaction.
                    if pendingOpenBoardId != nil { detailBoardTaskId = nil }
                    // Board-integrity PR-5 (Item 5): this nested sheet
                    // edits/deletes the compound CHILD's `Task` directly via
                    // `AppDatabase.shared` — the parent `detailSheet`'s
                    // compound-progress display and the underlying grid both
                    // read stale in-memory state until refreshed. Reload
                    // unconditionally (not just on cross-board nav) so a
                    // plain "Done" dismiss after an edit/delete still picks
                    // up the change. When `detailBoardTaskId` is ALSO about
                    // to nil out (the cross-board branch above), the outer
                    // sheet's own onDismiss reloads again — redundant but
                    // harmless (cheap local reads).
                    viewModel.reloadBoardTasksAndTaskData()
                }
            ) { item in
                TaskDetailSheetView(
                    taskId: item.id,
                    onClose: { compoundChildDetailTaskId = nil },
                    onOpenBoard: { newBoardId in
                        pendingOpenBoardId = newBoardId
                        compoundChildDetailTaskId = nil
                    }
                )
            }
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

    /// 0-based grid index (row * gridSize + col) for a BoardTask — used to
    /// look up its membership in a sealed board's frozen `sealedCompletedCells`.
    private func cellIndex(for boardTask: BoardTask) -> Int {
        boardTask.row * gridSize + boardTask.col
    }

    /// Windowed Completion (docs Decision 9) — resolve `isUncompleteBlockedBySeal`
    /// for every un-complete affordance the detail sheet is about to render:
    /// the boardTask's own task (normal/counting Mark-complete button), plus
    /// every compound child row (the sheet's "Children" list). Off-main; the
    /// result populates `sealBlockedTaskIds` so the sheet renders
    /// disabled-with-explanation for any task whose green is held entirely by
    /// a sealed-window-immune completion.
    ///
    /// - Parameter boardTaskId: The `detailBoardTaskId` that just changed, or
    ///   `nil` when the sheet closed (clears the set).
    private func loadSealBlockedTaskIds(for boardTaskId: String?) {
        guard let boardTaskId,
              let bt = boardTasks.first(where: { $0.id == boardTaskId }),
              let task = taskMap[bt.taskId] else {
            sealBlockedTaskIds = []
            return
        }
        var candidateIds: [String] = [task.id]
        if task.type == .compound {
            let children = compoundChildrenByCompound[task.id] ?? []
            candidateIds.append(contentsOf: children.map { $0.childTaskId })
        }
        _Concurrency.Task.detached(priority: .utility) {
            var blocked: Set<String> = []
            for id in candidateIds {
                if let isBlocked = try? AppDatabase.shared.isUncompleteBlockedBySeal(taskId: id), isBlocked {
                    blocked.insert(id)
                }
            }
            await MainActor.run { self.sealBlockedTaskIds = blocked }
        }
    }

    @ViewBuilder
    private func normalDetailContent(boardTask: BoardTask) -> some View {
        // Windowed Completion — a SEALED board reads `done` from the frozen
        // snapshot (docs §Effects of sealed), never live events.
        let isCompleted = isSealed
            ? (board?.sealedCompletedCells?.contains(cellIndex(for: boardTask)) ?? false)
            : (taskMap[boardTask.taskId].map { windowedIsCompleted($0) } ?? false)
        // Windowed Completion (docs Decision 9) — if every live completion is
        // sealed-window-immune, un-completing here would be inert (the
        // tombstone finds nothing to tombstone). Disable + explain instead of
        // a tap that silently does nothing.
        let sealBlocked = isCompleted && sealBlockedTaskIds.contains(boardTask.taskId)
        detailSection("Completion") {
            CompletionToggleView(
                isCompleted: isCompleted,
                sealBlocked: sealBlocked,
                disabled: isProcessing || isBoardLocked
            ) {
                viewModel.handleNormalTap(boardTask: boardTask)
                detailBoardTaskId = nil
            }
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
            // Windowed Completion — a SEALED board only snapshotted completion
            // (not partial progress): max/max when the frozen cell is green,
            // 0/max otherwise (docs §Effects of sealed).
            if isSealed {
                let done = board?.sealedCompletedCells?.contains(cellIndex(for: boardTask)) ?? false
                return done ? maxVal : 0
            }
            if task.sharedCounterId != nil {
                return deriveDisplayedCount(
                    derivedBaseline: task.baseline ?? 0,
                    derivedMaxCount: maxVal,
                    sourceCurrentCount: rawCount
                ).displayed
            }
            // Windowed Completion — event-owning source/plain counter shows the
            // windowed count.
            return windowedCount(task)
        }()

        // R3: shared counting squares' quick +/- here use the counter's
        // persisted default amount (was hardcoded 1) — same rule as the
        // context-menu quick actions; the "#" custom entry lives in the
        // stepper sheet's chip row, not this modal.
        let quickAmount = viewModel.sharedCounterSourceId(for: task).flatMap { taskMap[$0]?.defaultLogAmount } ?? 1

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
                        viewModel.handleCountingDecrement(boardTask: boardTask, task: task, amount: quickAmount)
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
                        viewModel.handleCountingTap(boardTask: boardTask, task: task, amount: quickAmount)
                    }
                }

                // R3 contract: "labels disclose the amount" on BOTH platforms —
                // when the stepper moves by the counter's default (not 1), say
                // so; bare ± glyphs silently logging 10 broke the contract
                // (#342 final review I1).
                if quickAmount != 1 {
                    Text("Steps by \(quickAmount)\(unitText.isEmpty ? "" : " \(unitText)")")
                        .font(.risoBody(11, .semibold))
                        .foregroundStyle(Color.risoMuted)
                        .frame(maxWidth: .infinity, alignment: .center)
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
                                    taskById: taskMap,
                                    windowContext: boardWindowContext
                                )
                            }
                            // Windowed child state — carve out derived counters.
                            if ct.sharedCounterId != nil { return ct.isCompleted }
                            return windowedIsCompleted(ct)
                        }()
                        // Windowed Completion (docs Decision 9) — a child whose
                        // only live completion(s) are sealed-window-immune
                        // can't be un-completed from here; disable + explain.
                        let sealBlocked = isDone && sealBlockedTaskIds.contains(link.childTaskId)

                        VStack(alignment: .leading, spacing: 3) {
                            HStack(spacing: 10) {
                                Button {
                                    guard let ct = childTask, !isBoardLocked, !isProcessing, !sealBlocked else { return }
                                    viewModel.handleCompoundChildToggle(childTask: ct)
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
                                .disabled(isProcessing || isBoardLocked || childTask == nil || sealBlocked)

                                // Info button — opens the child task's detail, stacked
                                // on top of this sheet (see `compoundChildDetailTaskId`).
                                Button {
                                    compoundChildDetailTaskId = TaskIdItem(id: link.childTaskId)
                                } label: {
                                    Image(systemName: "info.circle")
                                        .font(.system(size: 16))
                                        .foregroundStyle(Color.risoMuted)
                                }
                                .buttonStyle(.plain)
                                .accessibilityLabel("Open \(childTask?.title ?? "task") in library")
                            }
                            if sealBlocked {
                                Text("Completed in a closed window")
                                    .font(.risoBody(11, .semibold))
                                    .foregroundStyle(Color.risoMuted)
                                    .padding(.leading, 24)
                            }
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
    /// understand why the cell is (or isn't) complete.
    ///
    /// Board-integrity PR-3 — met/count/required numbers come straight from
    /// `kernelCellStates` (the same lookup `achievementBadge(for:)` and the
    /// play-grid completion branch consult), so this is no longer a THIRD
    /// hand-copy of the trigger/meets/spawn-filter logic; only the display
    /// NAME lookups (board/template name — outside the kernel's domain) stay
    /// local.
    @ViewBuilder
    private func achievementDetailContent(boardTask: BoardTask, task: Task) -> some View {
        let trigger = task.achievementTrigger ?? .greenlog
        let achievement = kernelCellStates[boardTask.id]?.achievement

        if let refBoardId = task.referencedBoardId {
            // Match the !isDeleted filter used by achievementBadge(for:) so
            // a soft-deleted watched board doesn't show here while the cell
            // reads as not-complete.
            let ref = allBoardsInWorkspace.first(where: { $0.id == refBoardId && !$0.isDeleted })
            let isMet = achievement?.referencedBoardCompleted ?? false
            detailSection("Watching board") {
                if let ref {
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
            let metCount = achievement?.templateInWindowMet ?? 0
            let required = achievement?.templateRequiredCount ?? (task.requiredCount ?? 0)
            // Total in-window spawn count (not just those meeting the
            // trigger) is a display-only detail outside the kernel's
            // completion-derivation domain (the kernel's CellState only
            // carries `templateInWindowMet`, the met subset) — mirrors how
            // board/template NAME lookups above also stay local. Recomputed
            // with a plain filter (no trigger evaluation), so it can't drift
            // on completion semantics.
            let inWindowCount: Int = {
                guard let parent = board else { return 0 }
                return allBoardsInWorkspace.filter { b in
                    !b.isDeleted
                        && b.spawnedFromTemplateId == refTemplateId
                        && DateFormatting.isWithinTimeframe(
                            b.startDate,
                            startDate: parent.startDate,
                            endDate: parent.endDate
                        )
                }.count
            }()
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
                    Text("\(inWindowCount) in-window spawn\(inWindowCount == 1 ? "" : "s")")
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

    // MARK: - Interaction handlers moved to BoardPlayViewModel (B2-I2)
    //
    // handleNormalTap / handleCountingTap / handleCountingDecrement /
    // handleCompoundChildToggle /
    // handleAddTaskToCell (plus the private runOrchestration /
    // runSharedCounterIncrement / runSharedCounterDecrement they call) now
    // live on `viewModel`. The view's tap closures call `viewModel.handleX(...)`
    // and observe `viewModel.flashEvent` to fire the residual toast/overlay
    // animations (see the `.onChange(of: viewModel.flashEvent)` observer).

    // MARK: - Edit Mode
    //
    // NOTE (B2-I3): the edit-draft data layer moved to `BoardPlayViewModel` —
    // `seedEditDraft`, the Phase-3 rearrange seed/handle (`seedRearrangeCells` /
    // `handleRearrange`), the staged mutators (`handleEditCellReplace` /
    // `handleEditTaskOverride`), and the DB commits (`handleEditSave` /
    // `handleEditArchive`). The view keeps only the cell-menu routing handlers
    // below (they mutate view-owned `editCellMenu*` `@State`) and
    // `triggerBoardSavedToast` (a pure view animation).

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
