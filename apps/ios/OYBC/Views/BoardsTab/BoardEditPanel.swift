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
    var hint: String {
        switch self {
        case .editTasks: return "Tap a square to replace or edit a task."
        case .rearrange: return "Drag squares to rearrange. The center square is pinned."
        }
    }
}

// MARK: - BoardEditPanel

/// Leaf in-place edit chrome for an ACTIVE board (Phase 1 of the board-edit flow).
///
/// Replaces the now-retired `EditBoardSheet` modal. Takes all state as plain props
/// and bindings — no database access — so it is directly snapshot-testable.
///
/// Layout (vertical scroll):
///   top bar  (Cancel · "Editing board" gold pill)
///   → immutable-size chip
///   → `BoardSetupFormView` (name · timeframe · custom dates · center)
///   → SQUARES section header
///   → Edit-tasks ⇄ Rearrange sub-mode toggle (hint only in Phase 1)
///   → display-only board grid
///   → Archive ghost button
///   sticky bottom: edit counter · "Save changes" pill
///
/// Confirm alerts (inline / system): Cancel-if-dirty ("Discard changes?") and
/// Archive ("Archive this board?"). Both handled here; outcome callbacks route
/// to the parent (`BoardPlayView`), which owns all database writes.
struct BoardEditPanel: View {

    // MARK: - Props

    /// Original board record — used for display (size chip) and dirty comparison.
    let board: Board

    /// Current placement data for the display-only grid.
    let boardTasks: [BoardTask]
    let taskMap: [String: Task]

    /// Week-start day forwarded to `BoardSetupFormView`'s date-note computation.
    let weekStartDay: String

    /// Original parsed start date (seeded from `board.startDate` by `BoardPlayView`).
    /// Used in the dirty check when `timeframe == .custom` or `.indefinite`.
    let originalCustomStartDate: Date

    /// Original parsed end date (seeded from `board.endDate` by `BoardPlayView`).
    /// Used in the dirty check when `timeframe == .custom`.
    let originalCustomEndDate: Date

    // MARK: - Draft bindings (owned by BoardPlayView)

    @Binding var name: String
    @Binding var timeframe: Timeframe
    @Binding var customStartDate: Date
    @Binding var customEndDate: Date
    @Binding var centerType: CenterSquareType
    @Binding var centerCustomName: String

    /// True when the board already has a center-task placement (so CHOSEN is
    /// available). Loaded asynchronously by `BoardPlayView.seedEditDraft`.
    var hasCandidateTasks: Bool

    /// Which sub-mode the segmented toggle shows. Flips the hint text only
    /// (Rearrange is inert until Phase 3).
    @Binding var subMode: BoardEditSubMode

    // MARK: - Squares draft (Phase 2)

    /// Number of staged square edits — replacements + task-field overrides +
    /// position moves — computed by `BoardPlayView`. Added to `editCount` /
    /// `isDirty` so the panel counter and Save pill react to cell-level changes.
    var squareEditCount: Int = 0

    /// Called when the user taps a non-center square in the `.editTasks`
    /// sub-mode. `BoardPlayView` handles routing to the Replace / Edit menu.
    /// nil in Phase 1 (grid was display-only); provided by the parent in Phase 2+.
    var onCellTap: ((Int, Int) -> Void)? = nil

    // MARK: - Rearrange draft (Phase 3)

    /// Staged rearrange order for `RearrangeGrid`. `nil` until the user enters
    /// Rearrange sub-mode for the first time (built lazily by `BoardPlayView`
    /// from `editSquaresDraft`). Updated via `onReorder`.
    var rearrangeCells: [RearrangeCellData]? = nil

    /// Called when `RearrangeGrid` commits a reorder (drag-to-insert or
    /// tap-to-swap). Parent (`BoardPlayView`) updates `editRearrangeCells`.
    var onReorder: (([RearrangeCellData]) -> Void)? = nil

    // MARK: - Saving indicator

    /// True while the parent is writing to GRDB. Disables the Save pill.
    var isSaving: Bool

    // MARK: - Callbacks

    /// Called when the user taps Save. Parent performs the GRDB write.
    var onSave: () -> Void

    /// Called when the user confirms Discard, or taps Cancel with no dirty state.
    /// Parent exits edit mode.
    var onCancelConfirmed: () -> Void

    /// Called when the user confirms Archive. Parent archives the board and
    /// navigates away.
    var onArchiveConfirmed: () -> Void

    // MARK: - Local confirm-dialog state

    @State private var showCancelConfirm = false
    @State private var showArchiveConfirm = false

    // MARK: - Derived

    /// True if any draft field has been changed from the original board values,
    /// or if any square has a staged replacement or task-field edit.
    private var isDirty: Bool {
        if squareEditCount > 0 { return true }
        if name.trimmingCharacters(in: .whitespaces) != board.name { return true }
        if timeframe != board.timeframe { return true }
        if centerType != board.centerSquareType { return true }
        if centerType == .customFree,
           centerCustomName != (board.centerSquareCustomName ?? "") { return true }
        // Custom-date changes are only meaningful when the timeframe supports user-chosen dates.
        if timeframe == .custom || timeframe == .indefinite {
            if abs(customStartDate.timeIntervalSince(originalCustomStartDate)) > 60 { return true }
        }
        if timeframe == .custom {
            if abs(customEndDate.timeIntervalSince(originalCustomEndDate)) > 60 { return true }
        }
        return false
    }

    /// Count of all staged changes: metadata (name / timeframe / center) +
    /// squares (replacements + task-field overrides from `squareEditCount`).
    private var editCount: Int {
        var n = squareEditCount
        if name.trimmingCharacters(in: .whitespaces) != board.name { n += 1 }
        let tfChanged = timeframe != board.timeframe
        let dateChanged: Bool = {
            guard timeframe == .custom || timeframe == .indefinite else { return false }
            if abs(customStartDate.timeIntervalSince(originalCustomStartDate)) > 60 { return true }
            if timeframe == .custom,
               abs(customEndDate.timeIntervalSince(originalCustomEndDate)) > 60 { return true }
            return false
        }()
        if tfChanged || dateChanged { n += 1 }
        let centerChanged = (centerType != board.centerSquareType)
            || (centerType == .customFree
                && centerCustomName != (board.centerSquareCustomName ?? ""))
        if centerChanged { n += 1 }
        return n
    }

    /// True when a save is permitted (dirty + name non-empty + not currently saving).
    private var canSave: Bool {
        isDirty
            && !name.trimmingCharacters(in: .whitespaces).isEmpty
            && !isSaving
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
        .alert("Archive this board?", isPresented: $showArchiveConfirm) {
            Button("Keep editing", role: .cancel) {}
            Button("Archive", role: .destructive) { onArchiveConfirmed() }
        } message: {
            Text("The board will be archived. Completed tasks and your record stay intact.")
        }
    }

    // MARK: - Scroll content

    private var scrollContent: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 20) {
                topBar
                sizeChip
                BoardSetupFormView(
                    name: $name,
                    timeframe: $timeframe,
                    customStartDate: $customStartDate,
                    customEndDate: $customEndDate,
                    centerType: $centerType,
                    centerCustomName: $centerCustomName,
                    weekStartDay: weekStartDay,
                    chosenCenterDisabled: board.centerTaskId == nil || !hasCandidateTasks
                )
                squaresSection
                archiveButton
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

    /// Gold "Editing board" pill with a red recording dot.
    ///
    /// Content on gold uses `risoInkStatic` so it reads correctly in dark mode
    /// (plain `risoInk` inverts to cream on the always-bright gold fill).
    private var editingPill: some View {
        HStack(spacing: 5) {
            Circle()
                .fill(Color.risoRed)
                .frame(width: 7, height: 7)
            Text("Editing board")
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

    // MARK: - Immutable size chip

    /// Read-only board-size chip — identical to the one in the retired `EditBoardSheet`.
    private var sizeChip: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("BOARD SIZE")
                .risoSectionLabel()
            HStack(spacing: 10) {
                Text("\(board.boardSize)×\(board.boardSize)")
                    .font(.risoHead(16, .extraBold))
                    .foregroundStyle(Color.risoInk)
                Spacer()
                Text("Immutable")
                    .font(.risoBody(11, .semibold))
                    .foregroundStyle(Color.risoMuted)
                    .padding(.horizontal, 8)
                    .padding(.vertical, 3)
                    .background(Capsule().fill(Color.risoPaper))
                    .overlay(Capsule().strokeBorder(Color.risoMuted, lineWidth: Riso.Keyline.dense))
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .risoCard(fill: .risoPaper2)
            Text("Board size cannot be changed on an active board.")
                .font(.risoBody(11, .semibold))
                .foregroundStyle(Color.risoMuted)
        }
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

            Text(subMode.hint)
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
                    centerCustomName: centerCustomName.isEmpty
                        ? (board.centerSquareCustomName ?? "")
                        : centerCustomName,
                    rearrange: true,
                    onReorder: { onReorder?($0) }
                )
            } else {
                // Edit-tasks sub-mode (Phase 2) or rearrange cells not yet seeded —
                // show the static grid with optional tap affordances.
                BoardEditStaticGrid(
                    boardSize: board.boardSize,
                    boardTasks: boardTasks,
                    taskMap: taskMap,
                    centerSquareType: centerType,
                    centerCustomName: centerCustomName.isEmpty
                        ? board.centerSquareCustomName
                        : centerCustomName,
                    onCellTap: subMode == .editTasks ? onCellTap : nil
                )
            }
        }
    }

    // MARK: - Archive ghost button

    private var archiveButton: some View {
        Button {
            showArchiveConfirm = true
        } label: {
            Text("Archive this board")
                .font(.risoBody(14, .semibold))
                .foregroundStyle(Color.risoMuted)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 14)
                .overlay(
                    RoundedRectangle(cornerRadius: Riso.cardRadius)
                        .strokeBorder(
                            Color.risoMuted,
                            style: StrokeStyle(
                                lineWidth: Riso.Keyline.container,
                                dash: [6, 4]
                            )
                        )
                )
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

// MARK: - BoardEditStaticGrid

/// Board grid for edit mode.
///
/// Renders placements with optional tap-gesture support. When `onCellTap` is
/// provided (Phase 2 Edit-tasks sub-mode), tapping a non-center occupied cell
/// triggers the Replace / Edit context menu via the parent. Center cells and
/// empty cells are always inert. Rearrange (Phase 3) and Phase 1 pass nil.
private struct BoardEditStaticGrid: View {
    let boardSize: Int
    let boardTasks: [BoardTask]
    let taskMap: [String: Task]
    let centerSquareType: CenterSquareType
    let centerCustomName: String?
    /// Phase 2: callback for non-center occupied cell taps. nil = display-only.
    var onCellTap: ((Int, Int) -> Void)? = nil

    private var btByPosition: [String: BoardTask] {
        var map: [String: BoardTask] = [:]
        for bt in boardTasks { map["\(bt.row)-\(bt.col)"] = bt }
        return map
    }

    var body: some View {
        let columns = Array(
            repeating: GridItem(.flexible(), spacing: Riso.cellGap),
            count: max(boardSize, 1)
        )
        LazyVGrid(columns: columns, spacing: Riso.cellGap) {
            ForEach(0..<boardSize * boardSize, id: \.self) { idx in
                let row = idx / boardSize
                let col = idx % boardSize
                let bt = btByPosition["\(row)-\(col)"]
                let isCenter = bt?.isCenter == true
                // Tapping: enabled on non-center occupied cells when onCellTap is set.
                let tapEnabled = onCellTap != nil && !isCenter && bt != nil
                BoardEditStaticCell(
                    task: bt.flatMap { taskMap[$0.taskId] },
                    isCenter: isCenter,
                    centerSquareType: centerSquareType,
                    centerCustomName: centerCustomName,
                    isInteractive: tapEnabled,
                    onTap: tapEnabled ? { onCellTap?(row, col) } : nil
                )
            }
        }
    }
}

// MARK: - BoardEditStaticCell

/// A single cell in the edit-mode grid.
///
/// When `isInteractive` is true (Phase 2 Edit-tasks sub-mode, non-center
/// occupied cell), the cell renders with a subtle pencil badge and a tap
/// gesture that calls `onTap`. Center and empty cells are always passive.
private struct BoardEditStaticCell: View {
    let task: Task?
    let isCenter: Bool
    let centerSquareType: CenterSquareType
    let centerCustomName: String?
    /// Phase 2: when true the cell shows an edit-affordance and fires `onTap`.
    var isInteractive: Bool = false
    var onTap: (() -> Void)? = nil

    private var label: String {
        if isCenter {
            switch centerSquareType {
            case .free:
                return "FREE"
            case .customFree:
                let name = centerCustomName ?? ""
                return name.isEmpty ? "FREE" : name
            case .chosen:
                return task?.title ?? "FREE"
            case .none:
                return ""
            }
        }
        return task?.title ?? ""
    }

    private var fill: Color {
        if isCenter { return .risoGold }
        if task?.isCompleted == true { return .risoGreen }
        return task != nil ? .risoPaper2 : .risoPaper
    }

    private var textColor: Color {
        if isCenter { return .risoInkStatic }
        if task?.isCompleted == true { return .risoPaper }
        return .risoInk
    }

    var body: some View {
        ZStack(alignment: .topTrailing) {
            // Cell background + keyline
            RoundedRectangle(cornerRadius: Riso.cellRadius)
                .fill(fill)
                .overlay(
                    RoundedRectangle(cornerRadius: Riso.cellRadius)
                        .strokeBorder(
                            isCenter ? Color.risoInkStatic.opacity(0.3)
                                     : (isInteractive ? Color.risoBlue : Color.risoInk),
                            lineWidth: isInteractive ? Riso.Keyline.container : Riso.Keyline.dense
                        )
                )

            // Cell label
            if !label.isEmpty {
                Text(label)
                    .font(.risoBody(8, .semibold))
                    .foregroundStyle(textColor)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }

            // Pencil affordance — small icon in the top-trailing corner for
            // interactive cells, signalling "tap to edit". Inset slightly so
            // it doesn't overlap the cell keyline.
            if isInteractive {
                Image(systemName: "pencil")
                    .font(.system(size: 7, weight: .bold))
                    .foregroundStyle(Color.risoBlue)
                    .padding(3)
            }
        }
        .aspectRatio(1, contentMode: .fit)
        .contentShape(Rectangle())
        .onTapGesture {
            if isInteractive { onTap?() }
        }
    }
}

// MARK: - Preview

#Preview {
    struct PreviewWrapper: View {
        @State var name = "Spring Goals"
        @State var timeframe = Timeframe.monthly
        @State var startDate = Date()
        @State var endDate = Date().addingTimeInterval(30 * 24 * 3600)
        @State var centerType = CenterSquareType.free
        @State var centerCustomName = ""
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
                weekStartDay: "monday",
                originalCustomStartDate: startDate,
                originalCustomEndDate: endDate,
                name: $name,
                timeframe: $timeframe,
                customStartDate: $startDate,
                customEndDate: $endDate,
                centerType: $centerType,
                centerCustomName: $centerCustomName,
                hasCandidateTasks: false,
                subMode: $subMode,
                isSaving: false,
                onSave: {},
                onCancelConfirmed: {},
                onArchiveConfirmed: {}
                // rearrangeCells + onReorder default to nil (Phase 3 not active in preview)
            )
        }
    }
    return PreviewWrapper()
}
