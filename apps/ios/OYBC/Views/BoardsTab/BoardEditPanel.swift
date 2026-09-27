import SwiftUI

// MARK: - BoardEditPanel

/// Leaf full-screen Edit overlay (Board Edit redesign slice 3, T5, expanded
/// by the Edit consolidation to host every board option —
/// docs/BOARD_EDIT_REDESIGN.md). Takes all state as plain props and
/// callbacks — no database access — so it is directly snapshot-testable.
///
/// Slice 3 (D7) retires the Edit-tasks ⇄ Rearrange sub-modes: there is ONE
/// grid now. Tap routes to the square menu / picker (owned by
/// `BoardEditPresenter`, applied on `BoardPlayView`); press-and-hold lifts a
/// movable square for the live cascade (`SquaresEditGrid`). D6 also removed
/// the FREE⇄task center toggle that used to live here as a segmented
/// control — the center now changes ONLY via the grid's own tap-menu
/// ("Make it a free space" / "Make it a task square"), exactly like any
/// other square.
///
/// Edit consolidation (D3/D4/D6): `squaresEditable` (frozen by the caller at
/// Edit entry) gates the SQUARES section — when true it's the grid exactly
/// as before; when false the grid is replaced by one muted
/// `squaresLockedReason` line, the top-left control reads "Done" instead of
/// "Cancel", and the save bar doesn't render (nothing can be dirty). Either
/// way, a `BoardOptionsSectionView` (D6's BOARD section) renders below.
///
/// Layout (vertical scroll):
///   top bar  (Cancel/Done · "Editing" gold pill)
///   → SQUARES section header + hint + grid, OR the locked-reason line
///   → BOARD section (`BoardOptionsSectionView`)
///   sticky bottom (only when `squaresEditable`): edit counter · Shuffle ·
///     "Save changes" pill
///
/// Confirm alert (inline / system): Cancel-if-dirty ("Discard changes?").
/// Handled here; the outcome callback routes to the parent (`BoardPlayView`),
/// which owns the database write.
struct BoardEditPanel: View {

    // MARK: - Props

    /// Original board record — used for display (grid size).
    let board: Board

    /// The unified squares-edit grid, already reflecting every staged edit
    /// (`BoardPlayViewModel.editSquaresEditCells` — D20, rebuilt fresh).
    let cells: [SquareEditCellData]
    let taskMap: [String: Task]

    /// Total staged edit count (D11 — already includes the center toggle;
    /// the panel does not add its own +1).
    var editCount: Int = 0
    /// D10/OQ8 — disabled when fewer than 2 non-fixed slots hold a task.
    var canShuffle: Bool = false

    /// Tap routing — the caller (`BoardPlayView`) resolves the tapped cell
    /// id into a menu / picker target.
    var onTap: (String) -> Void = { _ in }
    /// Fires after a committed hold-drag reorder.
    var onReorder: ([SquareEditCellData]) -> Void = { _ in }
    /// VoiceOver / keyboard fallback move (D9).
    var onKeyboardMove: (String, SquaresEditDirection) -> SquaresEditMoveResult = { _, _ in .ignored }
    /// Fires on the Shuffle button tap.
    var onShuffle: () -> Void = {}

    /// Windowed-Completion-aware completion read (Windowed Completion —
    /// docs/WINDOWED_COMPLETION.md §Task caches).
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

    // MARK: - Board Edit consolidation (D3/D4/D6)

    /// Whether the SQUARES section is editable — frozen by the caller at
    /// Edit entry (`BoardMenuItems.canEditSquares`). `true` preserves every
    /// pre-consolidation behavior; `false` swaps the grid for
    /// `squaresLockedReason`, drops the save bar, and reads "Done" instead
    /// of "Cancel".
    var squaresEditable: Bool = true
    /// D4 — the muted line shown in place of the grid when
    /// `!squaresEditable` (`BoardMenuItems.squaresLockedReason`).
    var squaresLockedReason: String? = nil
    /// D6 — the BOARD section's rows, in display order.
    var boardItems: [BoardMenuItem] = []
    /// Called with a tapped BOARD-section row.
    var onBoardItem: (BoardMenuItem) -> Void = { _ in }

    // MARK: - Local confirm-dialog state

    @State private var showCancelConfirm = false

    /// True while a square is lifted in the grid. Locks the ScrollView so
    /// its pan can't steal the post-hold drag (`SquaresEditGrid.onLiftChange`).
    @State private var isSquareLifted = false

    // MARK: - Derived

    private var isDirty: Bool { editCount > 0 }

    /// True when a save is permitted (dirty + not currently saving).
    private var canSave: Bool { isDirty && !isSaving }

    // MARK: - Body

    var body: some View {
        ZStack(alignment: .bottom) {
            scrollContent
            if squaresEditable {
                saveBar
            }
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
                if squaresEditable {
                    squaresSection
                } else {
                    lockedReasonLine
                }
                BoardOptionsSectionView(items: boardItems, onSelect: onBoardItem)
                if squaresEditable {
                    // Bottom clearance for the sticky save bar so the last row
                    // is always visible above the bar when the scroll view bottoms out.
                    Spacer().frame(height: 76)
                }
            }
            .padding(.horizontal, Riso.gutter)
            .padding(.vertical, 16)
        }
        .scrollDisabled(isSquareLifted)
        .background(Color.risoPaper.ignoresSafeArea())
    }

    // MARK: - Top bar

    private var topBar: some View {
        HStack(spacing: 0) {
            Button(squaresEditable ? "Cancel" : "Done") {
                if squaresEditable {
                    if isDirty {
                        showCancelConfirm = true
                    } else {
                        onCancelConfirmed()
                    }
                } else {
                    onCancelConfirmed()
                }
            }
            .accessibilityLabel(squaresEditable ? "Cancel" : "Done editing")
            .font(.risoBody(15, .semibold))
            .foregroundStyle(Color.risoMuted)

            Spacer()

            editingPill
        }
    }

    /// Gold "Editing" pill with a red recording dot (D5 — copy shortened
    /// from "Editing squares" now that Edit hosts more than the grid).
    ///
    /// Content on gold uses `risoInkStatic` so it reads correctly in dark mode
    /// (plain `risoInk` inverts to cream on the always-bright gold fill).
    private var editingPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color.risoRed)
                .frame(width: 7, height: 7)
            Text("Editing")
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

            // D7 — one hint, verbatim per platform (i2).
            Text("Tap a square to replace, edit, lock or remove it. Hold to move it. Shuffle skips locked squares.")
                .font(.risoBody(12, .regular))
                .foregroundStyle(Color.risoMuted)
                .frame(maxWidth: .infinity, alignment: .leading)

            SquaresEditGrid(
                cells: cells,
                gridSize: board.boardSize,
                taskMap: taskMap,
                sideLength: UIScreen.main.bounds.width - 2 * Riso.gutter,
                onTap: onTap,
                onReorder: onReorder,
                onKeyboardMove: onKeyboardMove,
                onLiftChange: { isSquareLifted = $0 },
                windowedIsCompleted: windowedIsCompleted
            )
        }
    }

    /// D4 — replaces `squaresSection` when `!squaresEditable`.
    private var lockedReasonLine: some View {
        Text(squaresLockedReason ?? "")
            .font(.risoBody(12, .regular))
            .foregroundStyle(Color.risoMuted)
            .frame(maxWidth: .infinity, alignment: .leading)
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

                RisoButton(title: "Shuffle", kind: .neutral, systemImage: "shuffle", small: true, action: onShuffle)
                    .disabled(!canShuffle)
                    .opacity(canShuffle ? 1 : 0.45)

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
        var body: some View {
            let json = """
            {"id":"preview-board","userId":"u1","name":"Spring Goals","status":"active","boardSize":3,"timeframe":"monthly","startDate":"2026-05-01T00:00:00.000","endDate":"2026-05-31T23:59:59.999","centerSquareType":"free","isRandomized":true,"totalTasks":9,"completedTasks":4,"linesCompleted":1,"createdAt":"2026-05-01T00:00:00.000","updatedAt":"2026-05-15T12:00:00.000","version":3,"isDeleted":false}
            """
            let board = try! JSONDecoder().decode(Board.self, from: json.data(using: .utf8)!)
            return BoardEditPanel(
                board: board,
                cells: buildSquaresEditCells(draft: [:], gridSize: 3, centerType: .free),
                taskMap: [:],
                isSaving: false,
                onSave: {},
                onCancelConfirmed: {}
            )
        }
    }
    return PreviewWrapper()
}
