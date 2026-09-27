import SwiftUI

// MARK: - BoardEditSubMode

/// The two sub-modes available inside board Edit Mode.
///
/// - `editTasks` (default): static grid; tapping a square will open a
///   Replace / Edit context menu (Phase 2 — inert in Phase 1).
/// - `rearrange`: squares jiggle for drag-to-insert / tap-to-swap
///   (Phase 3 — inert in Phase 1).
enum BoardEditSubMode: Hashable {
    case editTasks
    case rearrange

    var label: String {
        switch self {
        case .editTasks: return "Edit tasks"
        case .rearrange: return "Rearrange"
        }
    }

    /// One-line hint shown below the sub-mode toggle.
    ///
    /// - Parameter hasPinnedCenter: Pass `true` when the board's draft
    ///   `centerSquareType != .none` so the rearrange hint accurately
    ///   reports whether the center is pinned.
    func hint(hasPinnedCenter: Bool) -> String {
        switch self {
        case .editTasks: return "Tap a square to replace or edit a task."
        case .rearrange:
            return hasPinnedCenter
                ? "Drag squares to rearrange. The center square is pinned."
                : "Drag squares to rearrange."
        }
    }
}

// MARK: - BoardEditPanel

/// Leaf in-place SQUARES editor for an ACTIVE board (Board Edit redesign
/// slice 2, T3 — docs/BOARD_EDIT_REDESIGN.md). Takes all state as plain
/// props and bindings — no database access — so it is directly
/// snapshot-testable.
///
/// Slice 2 retired everything else this panel used to own: the board-size
/// chip, `BoardSetupFormView` (name/timeframe/dates), the staged REPEATS
/// section, and the Archive ghost button all moved to the "…" menu's own
/// sheets/alerts (`BoardDetailsSheetView`, `BoardRepeatSheetView`,
/// `BoardActionsPresenter`'s Archive confirm) — see
/// `Views/BoardsTab/BoardActions/`. This panel is now ONLY the squares
/// editor: the FREE⇄task center toggle (the one field slice 2 kept here,
/// per D5 — see `BoardDetailsDraft`'s CHOSEN-exit note) plus the
/// Edit-tasks ⇄ Rearrange grid.
///
/// Layout (vertical scroll):
///   top bar  (Cancel · "Editing squares" gold pill)
///   → SQUARES section header
///   → Edit-tasks ⇄ Rearrange sub-mode toggle (hint only in Phase 1)
///   → display-only board grid
///   sticky bottom: edit counter · "Save changes" pill
///
/// Confirm alert (inline / system): Cancel-if-dirty ("Discard changes?").
/// Handled here; the outcome callback routes to the parent (`BoardPlayView`),
/// which owns the database write.
struct BoardEditPanel: View {

    // MARK: - Props

    /// Original board record — used for display (grid size) and the
    /// center-toggle dirty comparison.
    let board: Board

    /// Current placement data for the display-only grid.
    let boardTasks: [BoardTask]
    let taskMap: [String: Task]

    // MARK: - Draft bindings (owned by BoardPlayView)

    @Binding var centerType: CenterSquareType

    /// Which sub-mode the segmented toggle shows. Flips the hint text only
    /// (Rearrange is inert until Phase 3).
    @Binding var subMode: BoardEditSubMode

    // MARK: - Squares draft (Phase 2)

    /// Number of staged square edits — replacements + task-field overrides +
    /// position moves — computed by `BoardPlayView`. Added to `editCount` /
    /// `isDirty` so the panel counter and Save pill react to cell-level changes.
    var squareEditCount: Int = 0

    /// Slice 1 — "row-col" keys of squares with a staged, unsaved edit
    /// (replace / task override / lock change); drawn with the gold pencil
    /// chip. Lock state itself is read from each row's `isLocked`, which the
    /// VM's draft already has the staged overrides applied to.
    var dirtyCellKeys: Set<String> = []

    /// Called when the user taps a non-center square in the `.editTasks`
    /// sub-mode. `BoardPlayView` handles routing to the Replace / Edit menu.
    /// nil in Phase 1 (grid was display-only); provided by the parent in Phase 2+.
    var onCellTap: ((Int, Int) -> Void)? = nil

    /// Called when the user taps the center cell in `.editTasks` sub-mode
    /// and the center is currently a free space (`.free`).
    /// `BoardPlayView` presents the "Make it a task square" action sheet.
    /// nil = center is inert (Phase 1; non-edit-tasks sub-mode; non-free center).
    var onCenterTap: (() -> Void)? = nil

    // MARK: - Rearrange draft (Phase 3)

    /// Staged rearrange order for `RearrangeGrid`. `nil` until the user enters
    /// Rearrange sub-mode for the first time (built lazily by `BoardPlayView`
    /// from `editSquaresDraft`). Updated via `onReorder`.
    var rearrangeCells: [RearrangeCellData]? = nil

    /// Called when `RearrangeGrid` commits a reorder (drag-to-insert or
    /// tap-to-swap). Parent (`BoardPlayView`) updates `editRearrangeCells`.
    var onReorder: (([RearrangeCellData]) -> Void)? = nil

    /// Windowed-Completion-aware completion read (Windowed Completion —
    /// docs/WINDOWED_COMPLETION.md §Task caches). `BoardPlayView` passes
    /// `viewModel.windowedIsCompleted(for:)` so this panel's Edit-tasks static
    /// grid and Rearrange preview match the live grid's windowed reads instead
    /// of bleeding a stale lifetime-complete state into a fresh board window.
    /// Defaults to the lifetime `Task.isCompleted` cache — the pre-fix
    /// behavior — so existing previews/snapshot call sites are unaffected.
    var windowedIsCompleted: (Task) -> Bool = { $0.isCompleted }

    // MARK: - Saving indicator

    /// True while the parent is writing to GRDB. Disables the Save pill.
    var isSaving: Bool

    // MARK: - Callbacks

    /// Called when the user taps Save. Parent performs the GRDB write.
    var onSave: () -> Void

    /// Called when the user confirms Discard, or taps Cancel with no dirty state.
    /// Parent exits edit mode.
    var onCancelConfirmed: () -> Void

    // MARK: - Local confirm-dialog state

    @State private var showCancelConfirm = false

    // MARK: - Derived

    /// True when the center toggle differs from the board's stored value.
    private var centerChanged: Bool { centerType != board.centerSquareType }

    /// True if any square has a staged replacement / task-field edit /
    /// position move, or the center toggle changed.
    private var isDirty: Bool {
        squareEditCount > 0 || centerChanged
    }

    /// Count of all staged changes: squares (`squareEditCount`) + the
    /// center toggle (0 or 1).
    private var editCount: Int {
        squareEditCount + (centerChanged ? 1 : 0)
    }

    /// True when a save is permitted (dirty + not currently saving).
    private var canSave: Bool {
        isDirty && !isSaving
    }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottom) {
            scrollContent
            saveBar
        }
        .alert("Discard changes?", isPresented: $showCancelConfirm) {
            Button("Keep editing", role: .cancel) {}
            Button("Discard", role: .destructive) { onCancelConfirmed() }
        } message: {
            Text("Your unsaved changes will be lost.")
        }
    }

    // MARK: - Scroll content

    private var scrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                topBar
                squaresSection
                // Bottom clearance for the sticky save bar so the last row
                // is always visible above the bar when the scroll view bottoms out.
                Spacer().frame(height: 76)
            }
            .padding(.horizontal, Riso.gutter)
            .padding(.vertical, 16)
        }
        .background(Color.risoPaper.ignoresSafeArea())
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 0) {
            Button("Cancel") {
                if isDirty {
                    showCancelConfirm = true
                } else {
                    onCancelConfirmed()
                }
            }
            .font(.risoBody(15, .semibold))
            .foregroundStyle(Color.risoMuted)

            Spacer()

            editingPill
        }
    }

    /// Gold "Editing squares" pill with a red recording dot.
    ///
    /// Content on gold uses `risoInkStatic` so it reads correctly in dark mode
    /// (plain `risoInk` inverts to cream on the always-bright gold fill).
    private var editingPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color.risoRed)
                .frame(width: 7, height: 7)
            Text("Editing squares")
                .font(.risoBody(13, .bold))
                .foregroundStyle(Color.risoInkStatic)
        }
        .padding(.vertical, 6)
        .padding(.horizontal, 12)
        .background(Capsule().fill(Color.risoGold))
        .overlay(
            Capsule().strokeBorder(
                Color.risoInkStatic.opacity(0.25),
                lineWidth: Riso.Keyline.dense
            )
        )
    }

    // MARK: - Squares section

    private var squaresSection: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("SQUARES")
                .risoSectionLabel()

            RisoSegmented(
                options: [
                    (.editTasks, "Edit tasks"),
                    (.rearrange, "Rearrange"),
                ],
                selection: $subMode
            )

            Text(subMode.hint(hasPinnedCenter: centerType != .none))
                .font(.risoBody(12, .regular))
                .foregroundStyle(Color.risoMuted)
                .frame(maxWidth: .infinity, alignment: .leading)

            if subMode == .rearrange, let cells = rearrangeCells {
                // Phase 3 — Rearrange sub-mode: live drag/tap grid. RearrangeGrid
                // resolves each cell's staged taskId against this taskId-keyed map.
                RearrangeGrid(
                    cells: cells,
                    gridSize: board.boardSize,
                    taskMap: taskMap,
                    centerSquareType: centerType,
                    rearrange: true,
                    sideLength: UIScreen.main.bounds.width - 2 * Riso.gutter,
                    onReorder: { onReorder?($0) },
                    windowedIsCompleted: windowedIsCompleted,
                    dirtyCellIds: Set(boardTasks.filter { dirtyCellKeys.contains("\(($0.row))-\(($0.col))") }.map { $0.id })
                )
            } else {
                // Edit-tasks sub-mode (or rearrange cells not yet seeded): the
                // board's own grid + cell renderer (slice 1 — one square
                // everywhere), with the tap affordances layered on top.
                editSquaresGrid
            }
        }
    }

    /// The shared board grid in edit-tasks mode. Every occupied square and
    /// the FREE center are tappable (routed to `onCellTap` / `onCenterTap`);
    /// the lock chip reads the row's (draft-applied) `isLocked`, the pencil
    /// chip marks cells listed in `dirtyCellKeys`.
    private var editSquaresGrid: some View {
        let byPosition = Dictionary(boardTasks.map { ("\(($0.row))-\(($0.col))", $0) }, uniquingKeysWith: { a, _ in a })
        let size = board.boardSize
        let mid = size / 2
        return RisoBoardGrid(gridSize: size) { row, col, _ in
            let key = "\(row)-\(col)"
            let bt = byPosition[key]
            let task = bt.flatMap { taskMap[$0.taskId] }
            // Phase-2b predicate: the center is pinned (gold FREE, inert to
            // normal cell taps) only when centerSquareType != .none.
            let isPositionalCenter = size % 2 == 1 && row == mid && col == mid
            let isPinnedCenter = isPositionalCenter && centerType != .none
            let centerTapEnabled = isPositionalCenter && centerType == .free
                && subMode == .editTasks && onCenterTap != nil
            let taskTapEnabled = subMode == .editTasks && onCellTap != nil
                && !isPinnedCenter && bt != nil

            Group {
                if isPinnedCenter {
                    RisoBoardPlayCell(
                        title: centerType == .chosen ? (task?.title ?? "FREE") : "FREE",
                        taskType: .normal,
                        isCompleted: false,
                        isCenter: true,
                        showsLockChip: bt?.isLocked ?? false,
                        showsDirtyChip: dirtyCellKeys.contains(key)
                    )
                } else if let task {
                    RisoBoardPlayCell(
                        title: task.title,
                        taskType: CellTaskType(task: task),
                        isCompleted: windowedIsCompleted(task),
                        showsLockChip: bt?.isLocked ?? false,
                        showsDirtyChip: dirtyCellKeys.contains(key),
                        currentCount: task.currentCount ?? 0,
                        maxCount: task.maxCount ?? 0
                    )
                } else {
                    RoundedRectangle(cornerRadius: Riso.cellRadius)
                        .fill(Color.risoPaper)
                        .overlay(
                            RoundedRectangle(cornerRadius: Riso.cellRadius)
                                .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense)
                        )
                        .aspectRatio(1, contentMode: .fit)
                }
            }
            .contentShape(Rectangle())
            .onTapGesture {
                if centerTapEnabled { onCenterTap?() }
                else if taskTapEnabled { onCellTap?(row, col) }
            }
        }
    }

    // MARK: - Sticky save bar

    private var saveBar: some View {
        VStack(spacing: 0) {
            Divider()
                .background(Color.risoInk.opacity(0.12))
            HStack(spacing: 12) {
                // Live edit counter — "No changes" when clean, "N edit(s)" when dirty.
                Text(isDirty
                     ? "\(editCount) edit\(editCount == 1 ? "" : "s")"
                     : "No changes")
                    .font(.risoBody(13, .semibold))
                    .foregroundStyle(isDirty ? Color.risoInk : Color.risoMuted)
                    .animation(.easeOut(duration: 0.15), value: isDirty)

                Spacer()

                // Gold pill — disabled when nothing to save or save in flight.
                RisoToolbarPill(title: isSaving ? "Saving…" : "Save changes") {
                    onSave()
                }
                .disabled(!canSave)
            }
            .padding(.horizontal, Riso.gutter)
            .padding(.top, 12)
            .padding(.bottom, 16)
        }
        .background(Color.risoPaper.ignoresSafeArea(edges: .bottom))
    }
}

// MARK: - Preview

#Preview {
    struct PreviewWrapper: View {
        @State var centerType = CenterSquareType.free
        @State var subMode = BoardEditSubMode.editTasks

        var body: some View {
            let json = """
            {"id":"preview-board","userId":"u1","name":"Spring Goals","status":"active","boardSize":3,"timeframe":"monthly","startDate":"2026-05-01T00:00:00.000","endDate":"2026-05-31T23:59:59.999","centerSquareType":"free","isRandomized":true,"totalTasks":9,"completedTasks":4,"linesCompleted":1,"createdAt":"2026-05-01T00:00:00.000","updatedAt":"2026-05-15T12:00:00.000","version":3,"isDeleted":false}
            """
            let board = try! JSONDecoder().decode(Board.self, from: json.data(using: .utf8)!)
            return BoardEditPanel(
                board: board,
                boardTasks: [],
                taskMap: [:],
                centerType: $centerType,
                subMode: $subMode,
                isSaving: false,
                onSave: {},
                onCancelConfirmed: {}
                // rearrangeCells + onReorder default to nil (Phase 3 not active in preview)
            )
        }
    }
    return PreviewWrapper()
}
