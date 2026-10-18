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
            // to avoid duplicate back/name affordances. (Edit lives in the
            // in-content title row too — the toolbar item is gone.)
            content
                .navigationBarTitleDisplayMode(.inline)
                .navigationBarBackButtonHidden(true)
                .background(InteractivePopEnabler()) // swipe-back survives the hidden back button
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
struct CreditToastState {
    /// The shared counter's SOURCE task id — what `Undo` reverses.
    let sourceTaskId: String
    let amount: CountValue
    let unit: String
    let verb: CounterLogToastView.Verb
    let message: String
    let undo: SharedCounterCreditToastPayload.UndoKind
    let toastKey: String
    /// A Normal toggle's toast: second line + the placement an Undo re-toggles.
    var detail: String? = nil
    var retoggle: BoardTask? = nil
    var wasDone: Bool? = nil // completed state BEFORE the toggle (Undo restores it)
    var squareUndo: SquareLogUndo? = nil // a menu log's exact reversal
}

// MARK: - ArrivalBannerData / ArrivalNavTarget (Shared Counters P3)

/// The showing arrival-banner's copy inputs, derived from a `CounterArrivalEvent`.
private struct ArrivalBannerData {
    /// Total arrived squares — selects the single-vs-multiple copy.
    let squareCount: Int
    /// The arrived square's task name (single-square variant only).
    let taskName: String?
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
    /// Owner-reported (2026-09-16): a horizontal pager swipe that starts on
    /// (or releases over) a tappable square must NOT fire the tap — a
    /// mid-swipe release was toggling completion. The pager passes true
    /// for the whole drag/snap; the cell dispatch guards on it. Default
    /// false keeps standalone behavior untouched.
    var pagerSwipeActive: Bool = false
    /// Catch-all draft guard: a DRAFT board is never rendered as a playable
    /// grid. When a draft is loaded (non-embedded) this fires with the board
    /// id so the host can resume it in the wizard. Covers every navigation
    /// path that lands on a board id (core-board browser, task-detail Usage
    /// jump, stray deep-links) — the list/core-grid/pager route to resume
    /// directly before reaching here, so this is the safety net. Nil ⇒ the
    /// guard still suppresses the grid but offers no resume action.
    var onResumeDraft: ((String) -> Void)? = nil
    /// Notifies a host (the core-board window pager) when in-place edit
    /// mode toggles, so it can disable window stepping / dim its chip
    /// while editing. Nil for the standalone destination.
    var onEditModeChange: ((Bool) -> Void)? = nil
    /// Board Edit redesign slice 2 (D8) — fired after a successful Archive
    /// or Delete from the BOARD section on a CORE board (the pager stays put;
    /// its window falls back to the lazy setup prompt). A standalone
    /// (non-core) board just `dismiss()`s instead — see
    /// `BoardActionsPresenter`'s `onRemoved` wiring below. Nil for the
    /// standalone destination, where it's never called.
    var onBoardRemoved: (() -> Void)? = nil
    @EnvironmentObject var authService: AuthService
    // internal for the +BoardActions extension split (Board Edit consolidation)
    @Environment(\.dismiss) var dismiss

    // MARK: - State

    /// Owns the data-loading layer (B2-I1). The seven data arrays the play
    /// surface reads are now `@Published private(set)` on the view model and
    /// exposed here as read-only computed shims so every existing read site
    /// (`board`, `boardTasks`, …) is untouched. Constructed in `init` with
    /// the board id + user id.
    // internal for the +Header extension split (Board Edit redesign slice 2)
    @StateObject var viewModel: BoardPlayViewModel

    // internal for the +Header extension split
    var board: Board? { viewModel.board }
    var boardTasks: [BoardTask] { viewModel.boardTasks }
    private var allTasks: [Task] { viewModel.allTasks }
    // Phase 6.3 — workspace-wide boards + templates feed both the
    // achievement-square config sheet (for the pickers) and the per-
    // cell badge data computation. Refreshed alongside the task data
    // so the sheet always sees up-to-date data when opened.
    private var allBoardsInWorkspace: [Board] { viewModel.allBoardsInWorkspace }
    private var allTemplatesInWorkspace: [RecurringBoardTemplate] { viewModel.allTemplatesInWorkspace }

    // Interaction write-state now lives on the view model (B2-I2). Read-only
    // shim so the many render sites that gate on `isProcessing` are untouched;
    // `bingoMessage` is read/written through `viewModel.bingoMessage` directly.
    private var isProcessing: Bool { viewModel.isProcessing }
    // MARK: Riso visual layer state
    /// The open moment and the trigger awaiting its reload — see `BoardPlayView+Moment.swift`.
    @State var moment: MomentPresentation? = nil
    @State var momentPending: MomentPending? = nil
    /// Compact greenlog-streak value (e.g. "3d"/"2w") for the title-row chip.
    /// Non-nil only for core boards with a streak ≥ 1.
    // internal for the +Header extension split
    @State var greenlogStreakValue: String? = nil
    /// The numeric greenlog streak the moment's chip rule reads (> 1).
    @State var greenlogStreakCount: Int = 0
    /// The bingo streak for the share poster's STREAK card (bingo kind).
    @State var bingoStreakCount: Int = 0
    /// Whether to show the Share Board sheet (opened from the moment overlay).
    @State var showShareBoardSheet: Bool = false
    // MARK: P2/R3 — Shared-counter credited toast
    /// The showing credited toast's data (message + Undo target), or nil
    /// when no toast is up. R3: unified onto `CounterLogToastView` (amount-
    /// aware copy + Undo pill) — see `triggerCreditToast(payload:)`.
    @State var creditToast: CreditToastState? = nil
    /// Board task id whose square sheet is open (`BoardPlayView+SquareSheet.swift`).
    @State var squareSheetBoardTaskId: String?
    /// The Undo strip under the sheet's chips after a log.
    @State var squareLogStrip: SquareLogStrip?
    @State var squareSheetEntry: SquareSheetEntry? // opens the sheet straight into an entry
    /// Hand-offs drained once the square sheet has unmounted (library, late log).
    @State var pendingTaskDetailTaskId: String?
    @State var pendingLateLogBoardTaskId: String?
    /// D15 late-log sheet target + its inline error (internal for `+LateLog`).
    @State var lateLogTarget: LateLogSheetItem?
    @State var lateLogErrorMessage: String?
    // MARK: P3 — Shared-counter arrival banner (passive completion)
    /// The showing arrival banner's data, or nil when no banner is up.
    @State private var arrivalBanner: ArrivalBannerData? = nil
    /// Arrived square task ids — drives the per-cell gold pulse.
    @State private var arrivedTaskIds: Set<String> = []
    /// Monotonic token so only the latest arrival's ~5.2s auto-clear fires.
    @State private var arrivalBannerGeneration: Int = 0
    /// Sheet-presented nav target for the banner tap (Counter Detail / Hub).
    @State private var arrivalNavTarget: ArrivalNavTarget? = nil
    /// Drives the task-detail library sheet (separate from the square sheet).
    @State var taskDetailSheetTaskId: TaskIdItem?
    // Windowed Completion (docs Decision 9): which tasks' un-complete would be inert (every
    // completion sealed-window-immune) is computed per apply from the loaded data —
    // `viewModel.derived.sealBlockedTaskIds` — never by a database read at render time.
    // MARK: Edit-mode draft state (Board Edit redesign slice 3)
    // The edit-draft *data* layer lives entirely on `BoardPlayViewModel`
    // (`editSquaresDraft` / `editCenterType` / `editSquaresEditCells`, D20 —
    // always rebuilt fresh). `BoardEditPresenter` (T5) owns the square
    // tap-menu / picker / edit-task sheets and the Save-failure / Board-
    // closed alerts. This view keeps only the overlay gate, the Save
    // spinner mirror, the "Board saved" toast flag, and the two routing
    // targets a grid tap sets (read by `BoardEditPresenter` via bindings).
    /// True while the in-place `BoardEditPanel` is overlaid on `BoardPlayView`.
    // internal for the +Header extension split
    @State var editMode: Bool = false
    /// D3 — SQUARES-section-editable, frozen at Edit entry (`onEdit` in `+Header`).
    // internal for the +Header extension split
    @State var editSquaresEditable: Bool = false
    /// Board Edit redesign slice 2 (T2) — which BOARD-section sheet/alert is
    /// active. Owned here (not the VM) since it's pure presentation state;
    /// `BoardActionsPresenter` reads/writes it via a binding.
    // internal for the +Header extension split
    @State var boardAction: BoardAction? = nil
    /// True while a `handleEditSave` commit is in flight — disables the Save
    /// pill. UI mirror driven by `viewModel.handleEditSave`'s return value +
    /// `viewModel.editEvent`; the authoritative re-entry guard is VM-side.
    // internal for the +Header extension split
    @State var editSaving: Bool = false
    /// Controls the "Board saved" success toast (auto-dismissed after 2.4 s).
    @State private var showEditSavedToast: Bool = false
    /// Which square's tap-menu is open (`BoardEditPresenter`, D16).
    @State private var editSquareMenuTarget: SquareMenuCellTarget? = nil
    /// Which square the picker sheet is filling (D13) — a tap on an empty
    /// non-center square routes straight here without the menu.
    @State private var editPickerTarget: SquarePickerRouteTarget? = nil

    /// Stashed target for cross-board navigation requested from inside
    /// the task-detail sheet. We can't mutate `boardsPath` while the
    /// sheet is dismissing — SwiftUI swallows the path change during
    /// the transition, leaving the user on the original board. Setting
    /// this stash + watching `taskDetailSheetTaskId` for nil-transition
    /// (see `.onChange` below) sequences dismiss-then-navigate
    /// correctly.
    @State var pendingOpenBoardId: String?

    /// Sheet `onDismiss` drain for `pendingOpenBoardId` (task-detail,
    /// nested child-detail, and counter arrival sheets all use it).
    func drainPendingOpenBoard() {
        guard let target = pendingOpenBoardId else { return }
        pendingOpenBoardId = nil
        onOpenBoard(target)
    }

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
        pagerSwipeActive: Bool = false,
        onResumeDraft: ((String) -> Void)? = nil,
        onEditModeChange: ((Bool) -> Void)? = nil,
        onBoardRemoved: (() -> Void)? = nil
    ) {
        self.boardId = boardId
        self.onOpenBoard = onOpenBoard
        self.embedded = embedded
        self.pagerSwipeActive = pagerSwipeActive
        self.onResumeDraft = onResumeDraft
        self.onEditModeChange = onEditModeChange
        self.onBoardRemoved = onBoardRemoved
        _viewModel = StateObject(
            wrappedValue: BoardPlayViewModel(boardId: boardId, userId: nil)
        )
    }

    // MARK: - Computed

    /// O(1) task lookup by task ID. Delegates to the view model (B2-I2), which
    /// owns the same lookup for its interaction handlers.
    var taskMap: [String: Task] { viewModel.taskMap }

    // MARK: - Windowed reads (Windowed Completion)

    /// Windowed completed state of a primitive square. A linked counter reads
    /// `resolveLinkedCounterDisplay` — a window-stamped row's root sum in its
    /// own window (the kernel's rule), a hub-linked row's latch — so a cell
    /// never paints green while stats count it incomplete. Callers must branch
    /// compound / achievement before calling.
    func windowedIsCompleted(_ task: Task) -> Bool { viewModel.windowedCompletedValue(task) }

    /// Windowed count of a counting square (see `BoardPlayViewModel.windowedCountValue`).
    func windowedCount(_ task: Task) -> CountValue { viewModel.windowedCountValue(task) }

    // MARK: - Edit-mode squares draft (Board Edit redesign slice 3)
    //
    // `editDraftTaskMap` / `editSquaresEditCells` / `editSquaresEditCount` /
    // the tap-menu title all live on `BoardPlayViewModel` /
    // `BoardEditPresenter` now — this view only routes a grid tap to
    // `editSquareMenuTarget` / `editPickerTarget` (`handleSquareTap` below).

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

    /// Position lookup for fast grid rendering: "row-col" → BoardTask. Built once per apply by the
    /// view model through `PlacementIntegrity.resolvePlacements` (board-integrity PR-2), so this map
    /// can't disagree with what derivation counted.
    private var btByPosition: [String: BoardTask] { viewModel.derived.placementsByPosition }

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
    // internal for the +LateLog extension split
    var isBoardLocked: Bool {
        guard let b = board else { return false }
        return isBoardPlayLocked(b)
    }

    /// Windowed Completion — whether the current board is sealed (docs
    /// §Effects of sealed). Sealed boards render read-only from
    /// `sealedCompletedCells` rather than live event queries.
    // internal for the +Header extension split
    var isSealed: Bool {
        board?.sealedAt != nil
    }

    /// D13/D14 "Ended, not closed". Internal for `+Header`/`+LateLog`.
    var isEnded: Bool {
        guard let b = board else { return false }
        return isBoardEnded(b, nowMs: Date().timeIntervalSince1970 * 1000)
    }

    /// Set of 0-based cell indices (row * gridSize + col) that are part of a
    /// completed bingo line. Drives the gold-ring highlight on `RisoBoardPlayCell`.
    private var highlightedSquareIndices: Set<Int> {
        guard let lines = board?.completedLineIds, !lines.isEmpty else { return [] }
        return BingoDetection.getHighlightedSquares(completedLines: lines, gridSize: gridSize)
    }

    // `boardKicker` moved to `BoardPlayView+Header.swift` (Board Edit
    // redesign slice 2 — file-size guardrail).

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

                    // Repeat-in-edit rework: the recurring management section
                    // (manage row / "Repeat this board…" CTA / provenance
                    // note) moved into Board Edit's REPEATS section.

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
                        statBarSection // ── Stat bar ──

                        // ── Grid ──
                        if board != nil {
                            risoGridSection
                                .padding(.horizontal, Riso.gutter)
                                // Sealed: flat, slightly faded frozen record.
                                .opacity(isSealed ? 0.92 : 1)
                        }

                        endedClosedBanners // D14 (ended) + OQ6 (closed)
                    }

                    Spacer(minLength: 20)
                }
            }

            // ── P3: Shared-counter arrival banner (drops from top) ──
            if let banner = arrivalBanner {
                RisoArrivalBanner(
                    squareCount: banner.squareCount,
                    taskName: banner.taskName,
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
            // now with the pinned "+N counterName" copy
            // and an Undo pill that reverses the whole logged entry.
            if let creditToast {
                VStack {
                    Spacer()
                    CounterLogToastView(
                        amount: creditToast.amount,
                        unit: creditToast.unit,
                        verb: creditToast.verb,
                        message: creditToast.message,
                        detail: creditToast.detail,
                        onUndo: {
                            if undoCreditToastState(creditToast) { withAnimation(.easeOut(duration: 0.2)) { self.creditToast = nil } } // busy keeps the toast
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

            momentOverlayLayer // Bingo / Greenlog moment (full-bleed)

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
                .zIndex(31) // D10 — above the edit overlay (30); was 11.
            }

            // ── In-place SQUARES editor (Board Edit redesign slice 3, T5) ──
            // Full-screen overlay. Sits above the GREENLOG overlay (zIndex 20)
            // so it covers celebrations triggered just before the user taps
            // Save. D7 retired the Edit-tasks ⇄ Rearrange sub-modes — ONE
            // grid, always derived fresh from the VM's draft (D20).
            if editMode, let b = board {
                BoardEditPanel(
                    board: b,
                    cells: viewModel.editSquaresEditCells,
                    taskMap: viewModel.editDraftTaskMap,
                    editCount: viewModel.editSquaresEditCount,
                    canShuffle: viewModel.canShuffle,
                    onTap: { cellId in handleSquareTap(cellId: cellId) },
                    onReorder: viewModel.handleEditMove,
                    onKeyboardMove: viewModel.handleEditKeyboardMove,
                    onShuffle: { viewModel.handleEditShuffle() },
                    // Windowed Completion parity (d16ff21, sub-slice 3 review
                    // finding): the edit preview must show the WINDOWED
                    // state, not the lifetime cache.
                    windowedIsCompleted: viewModel.windowedIsCompleted,
                    windowedCount: windowedCount,
                    isSaving: editSaving,
                    onSave: {
                        // The VM validates + dispatches the commit; it returns
                        // true iff the save actually started, so `editSaving`
                        // (view-owned) flips synchronously in the same tick the
                        // pre-move code did — the reset runs on `.editEvent`.
                        if viewModel.handleEditSave() {
                            editSaving = true
                        }
                    },
                    onCancelConfirmed: {
                        withAnimation(.easeInOut(duration: 0.22)) { editMode = false }
                    },
                    // D3/D6 — squares gate + BOARD rows (live `now`).
                    squaresEditable: editSquaresEditable,
                    boardItems: BoardMenuItems.items(
                        board: b, sourceTemplate: viewModel.editSourceTemplate,
                        now: Date().timeIntervalSince1970 * 1000
                    ),
                    onBoardItem: handleBoardItem
                )
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(Color.risoPaper.ignoresSafeArea())
                .transition(.opacity)
                .zIndex(30)
            }

            // ── Counting stepper sheet ──
            // Presented as a sheet (see .sheet modifier below)
        }
        .modifier(BoardPlayTitleChrome(title: board?.name ?? "Board", enabled: !embedded))
        // Core-board surface rework — the Edit affordance moved from the
        // toolbar into the in-content title row (`risoPlayHeader`), with
        // ONE gate on both platforms:
        // `status == .active && sealedAt == nil && !editMode`.
        // Notify the host pager when edit mode toggles (chip dim + step lock).
        .onChange(of: editMode) { _, editing in
            onEditModeChange?(editing)
        }
        // Board Edit consolidation — the BOARD section's sheets + confirm
        // alerts, keyed off `boardAction`. Construction moved to
        // `+BoardActions.swift` (file-size split).
        .modifier(boardActionsPresenter)
        // Board Edit redesign slice 3 (T5) — the square tap-menu, the picker
        // sheet, the Edit-task sheet, and the Save-failure / Board-closed
        // alerts, keyed off `editSquareMenuTarget` / `editPickerTarget`.
        .modifier(
            BoardEditPresenter(
                viewModel: viewModel,
                userId: authService.currentUser?.id ?? "",
                allTasks: allTasks,
                editMode: $editMode,
                editSaving: $editSaving,
                squareMenuTarget: $editSquareMenuTarget,
                pickerTarget: $editPickerTarget,
                onSaved: { triggerBoardSavedToast() }
            )
        )
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
            // Core-board surface rework — the streak chip now sits inline
            // in the title row, so the streak is computed on open (not only
            // when a GREENLOG fires). No-op for non-core boards.
            refreshStreaks()
        }
        // Recompute the title-row streak chip when the loaded board changes
        // (the embedded pager reuses this view instance across windows).
        .onChange(of: viewModel.board?.id) { _, _ in
            refreshStreaks()
        }
        .onDisappear {
            // P3 — re-snapshot the last-seen baseline on leaving (belt-and-suspenders).
            viewModel.snapshotArrivalsOnDisappear()
            momentPending = nil // a trigger awaiting its reload dies with the view
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
            if let trigger = event.moment {
                triggerMoment(trigger, applyCount: event.applyCount)
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
        // Board Edit redesign slice 3 (T5) — the `.editEvent` outcome
        // observer (saved / saveFailed / boardClosed) moved into
        // `BoardEditPresenter`, which owns the alerts it drives.
        // The square sheet (counting / compound / achievement taps, Normal
        // "View Details", every closed-board tap) — content, hand-offs and the
        // drains live in `BoardPlayView+SquareSheet.swift`. The library and
        // late-log sheets open from `onDismiss` (SwiftUI queues a sibling sheet).
        .sheet(
            isPresented: Binding(
                get: { squareSheetBoardTaskId != nil },
                set: { if !$0 { squareSheetBoardTaskId = nil } }
            ),
            onDismiss: drainSquareSheetHandOffs
        ) {
            squareSheet
        }
        // D15 closed-board late-log sheet.
        .sheet(item: $lateLogTarget) { item in lateLogSheet(for: item) }
        .onChange(of: squareSheetBoardTaskId) { _, _ in squareLogStrip = nil }
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
                drainPendingOpenBoard()
                // Board-integrity PR-5 (Item 5): this sheet edits/deletes its task
                // itself (bypasses this VM) — refresh so the grid reflects an edited
                // title/type or a cascade-deleted placement.
                viewModel.reloadBoardTasksAndTaskData()
            }
        ) { item in
            TaskDetailSheetView(
                taskId: item.id,
                onClose: { taskDetailSheetTaskId = nil },
                onOpenBoard: { newBoardId in
                    pendingOpenBoardId = newBoardId
                    taskDetailSheetTaskId = nil
                },
                originBoardId: viewModel.board?.id,
                database: viewModel.database
            )
        }
        // Share sheet — presented from the moment overlay's share button
        // (the overlay stays beneath it); the kind is the open moment's.
        .sheet(isPresented: $showShareBoardSheet) { shareSheetContent }
        // P3 — arrival banner tap → Counter Detail (single counter) / Counters
        // Hub (multiple). Presented as a sheet (wrapped in its own
        // NavigationStack for the hub → detail push) to match how this view
        // presents every other secondary surface — and to avoid a nav-push
        // conflicting with the embedded pager's own chrome. A member→board
        // tap closes the sheet and routes via `onOpenBoard` on dismiss (same
        // clean-transaction pattern as the task-detail sheets above), so a
        // core board lands in its pager window.
        .sheet(item: $arrivalNavTarget, onDismiss: drainPendingOpenBoard) { target in
            let openBoard: (String) -> Void = { pendingOpenBoardId = $0; arrivalNavTarget = nil }
            NavigationStack {
                switch target {
                case .counter(let counterId):
                    CounterDetailView(counterId: counterId, onOpenBoard: openBoard)
                case .hub:
                    CountersHubView(onOpenBoard: openBoard)
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

    // `risoPlayHeader` + `risoBackButton` + `risoEndedText` + `risoExpiryText`
    // moved to `BoardPlayView+Header.swift`; `handleBoardItem` +
    // `boardActionsPresenter` moved to `BoardPlayView+BoardActions.swift`
    // (file-size guardrail).

    // Repeat-in-edit rework: the recurring management section
    // (`recurringManagementSection` + `RisoRecurringManageRow` /
    // `RisoRepeatBoardCTA`, the spawn-note recompute, and the immediate
    // pause/repeat writes) moved into Board Edit — the panel's REPEATS
    // section renders it, `BoardPlayViewModel` owns the staged state +
    // Save-time mutations (`handleEditSave` phase 2), and the note is
    // computed only while the panel is open.

    /// Draft-guard body: shown in place of the stat bar + grid when a draft
    /// board is loaded outside the wizard. Drafts are never playable; this
    /// offers to resume the draft in the wizard instead.
    @ViewBuilder
    private func draftResumeSection(board: Board) -> some View {
        VStack(spacing: 16) {
            RisoMiniBoardArt(size: 56, state: .draft)

            Text("This board is still a draft.")
                .risoH2()
                .multilineTextAlignment(.center)

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

    // MARK: - P2/R3: Shared-counter credited toast helpers
    // `triggerCreditToast(payload:)` lives in `BoardPlayView+SquareSheet.swift`.

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
        arrivalBanner = ArrivalBannerData(
            squareCount: event.totalArrivedSquares,
            taskName: event.singleTaskName,
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

    /// Computes the streaks for the current board (core boards only) and
    /// stores a compact label in `greenlogStreakValue` for the title-row chip, plus
    /// the greenlog / bingo counts the moment overlay and share poster read.
    /// Non-core boards → nil (the STREAK card hides). Reads boards off-main.
    func refreshStreaks() {
        guard let b = board, b.isCore else {
            greenlogStreakValue = nil
            greenlogStreakCount = 0
            bingoStreakCount = 0
            return
        }
        let userId = b.userId
        let timeframe = b.timeframe
        let weekStartDay = authService.userPreferences.weekStartDay.rawValue
        let db = viewModel.database
        _Concurrency.Task.detached {
            let boards = (try? db.fetchBoards(userId: userId)) ?? []
            let count = computeStreak(
                timeframe: timeframe, criterion: .greenlog,
                boards: boards, weekStartDay: weekStartDay, now: Date()
            )
            let bingo = computeStreak(
                timeframe: timeframe, criterion: .bingo,
                boards: boards, weekStartDay: weekStartDay, now: Date()
            )
            let value = count >= 1 ? compactStreakLabel(count, timeframe: timeframe) : nil
            await MainActor.run { greenlogStreakValue = value; greenlogStreakCount = count; bingoStreakCount = bingo }
        }
    }

    // MARK: - Riso Grid Section

    @ViewBuilder
    private var risoGridSection: some View {
        let highlighted = highlightedSquareIndices
        RisoBoardGrid(gridSize: gridSize) { row, col, index in
            risoGridCell(row: row, col: col, index: index, highlighted: highlighted)
        }
        .padding(.bottom, 8)
    }

    /// One play-grid cell (extracted from the closure for type-check speed).
    @ViewBuilder
    private func risoGridCell(row: Int, col: Int, index: Int, highlighted: Set<Int>) -> some View {
        let mid: Int = gridSize / 2
        let isCenter: Bool = gridSize % 2 == 1 && row == mid && col == mid

        if let bt = btByPosition["\(row)-\(col)"] {
            risoPlaySquare(boardTask: bt, index: index, highlighted: highlighted)
        } else if isCenter,
                  let b = board,
                  CenterSquare.effectiveCenter(b.centerSquareType) == .free {
            // FREE center — gold, inert. Not getCenterDisplayText ("FREE SPACE"):
            // matches the edit grid's shorter "FREE" face.
            RisoBoardPlayCell(
                title: "FREE",
                taskType: .normal,
                isCompleted: false,
                isBingoLine: highlighted.contains(index),
                isCenter: true
            )
        } else {
            // D17 — no play-mode "+": every empty square (center too, once
            // `.none`) is a plain dashed square; adding is staged in Edit.
            RoundedRectangle(cornerRadius: Riso.cellRadius)
                .strokeBorder(
                    Color.risoInk.opacity(0.35),
                    style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                )
                .aspectRatio(1, contentMode: .fit)
        }
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
        // Everything below is resolved ONCE per apply (`BoardPlayViewModel+Derived.swift`); a body
        // pass only reads it. The count adds the write in flight's optimistic delta.
        let render = viewModel.placementRender(for: boardTask)
        let task = render.task // slice 2a: placement-adjusted
        let taskType = task?.type ?? .normal

        let cellKind: CellTaskType = {
            switch taskType {
            case .normal:      return .normal
            case .counting:    return .counting
            case .compound:    return .compound
            case .achievement: return .achievement
            }
        }()

        // Board Edit redesign slice 3 (D1/D16) — CHOSEN is legacy: a placed
        // cell NEVER renders the gold center styling anymore, even when it
        // sits at the positional center of a still-CHOSEN-on-disk board. It
        // renders as a normal cell with the lock chip — the effective lock
        // folds in the implicit legacy-CHOSEN center lock
        // (`CenterSquare.isLegacyChosenCenterLocked`) until the next squares
        // Save normalizes the row (D2).
        let effectiveLockChip: Bool = {
            guard let b = board else { return boardTask.isLocked }
            return boardTask.isLocked || CenterSquare.isLegacyChosenCenterLocked(
                centerType: b.centerSquareType, row: index / gridSize, col: index % gridSize,
                gridSize: gridSize
            )
        }()

        RisoBoardPlayCell(
            title: task?.title ?? "Unknown",
            taskType: cellKind,
            isCompleted: viewModel.displayCompleted(of: render),
            isBingoLine: highlighted.contains(index),
            isCenter: false,
            isInteractionLocked: false, // a closed board still opens the read-only square sheet
            showsLockChip: effectiveLockChip,
            currentCount: viewModel.displayCount(of: render),
            maxCount: render.maxCount,
            countKind: render.countKind,
            isSharedCounter: render.isSharedCounter,
            compoundDoneCount: render.compoundDoneCount,
            compoundChildCount: render.compoundChildCount,
            compoundRequiredCount: render.compoundRequiredCount,
            onTap: { handlePlaySquareTap(boardTask: boardTask, task: task) }
        )
        .contextMenu { squareMenu(boardTask: boardTask, task: task, render: render) }
        // P3 — pulse the square when it just arrived from an elsewhere log.
        // Applied at the call site (not inside RisoBoardPlayCell) so the
        // snapshot-covered cell internals stay untouched.
        .arrivePulse(active: task.map { arrivedTaskIds.contains($0.id) } ?? false)
    }

    // MARK: - Interaction handlers moved to BoardPlayViewModel (B2-I2)
    //
    // handleNormalTap / handleCountingTap / handleCountingDecrement /
    // handleCompoundChildToggle (plus the private runOrchestration /
    // runSharedCounterIncrement / runSharedCounterDecrement they call) now
    // live on `viewModel`. The view's tap closures call `viewModel.handleX(...)`
    // and observe `viewModel.flashEvent` to fire the residual toast/overlay
    // animations (see the `.onChange(of: viewModel.flashEvent)` observer).
    // `handleAddTaskToCell` (the play-mode "+") was retired in slice 3 (D17).

    // MARK: - Edit Mode
    //
    // The edit-draft data layer lives entirely on `BoardPlayViewModel` —
    // `seedEditDraft`, the staged mutators (`handleEditAdd` /
    // `handleEditReplace` / `handleEditMove` / `handleEditShuffle` /
    // `handleEditCenterFree` / `handleEditCenterTask`), and the DB commit
    // (`handleEditSave`). The view keeps only the tap-routing handler below
    // (it sets the view-owned `editSquareMenuTarget` / `editPickerTarget`
    // that `BoardEditPresenter` binds to) and `triggerBoardSavedToast` (a
    // pure view animation).

    // MARK: - Squares editor tap routing (D13/D16)

    /// Called by `BoardEditPanel.onTap` (via `SquaresEditGrid`) when the
    /// user taps ANY square — a non-center empty square routes straight to
    /// the Add picker (OQ5); everything else (occupied, locked, the FREE
    /// center, or an empty NONE center) opens the tap-menu, which
    /// `BoardEditPresenter` branches further.
    private func handleSquareTap(cellId: String) {
        let cells = viewModel.editSquaresEditCells
        let size = viewModel.gridSize
        guard size > 0, let idx = cells.firstIndex(where: { $0.id == cellId }) else { return }
        let cell = cells[idx]
        let row = idx / size, col = idx % size
        let cellKey = "\(row)-\(col)"

        if cell.isEmpty && !cell.isCenter {
            editPickerTarget = SquarePickerRouteTarget(cellKey: cellKey, mode: .add)
            return
        }
        editSquareMenuTarget = SquareMenuCellTarget(
            id: cellId, cellKey: cellKey, isCenter: cell.isCenter, isEmpty: cell.isEmpty
        )
    }

    /// Flashes the "Board saved" success toast for 2.4 s, then hides it.
    /// Safe to call multiple times — the latest invocation wins.
    // internal for the +BoardActions extension split
    func triggerBoardSavedToast() {
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
// internal for the +Header extension split
struct BackButton: View {
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
            .environmentObject(NotificationService())
    }
}
