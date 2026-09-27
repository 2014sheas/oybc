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

// MARK: - BoardEditRepeatInfo

/// Repeat-in-edit — display data for the REPEATS section's repeating-board
/// variant: the board's RESOLVED source repeating record. Plain value type
/// (built by `BoardPlayView` from `viewModel.editSourceTemplate`) so the
/// panel stays a DB-free, snapshot-testable leaf.
struct BoardEditRepeatInfo: Equatable {
    /// e.g. "weekly" — `formatCadenceAdverb(template.timeframe)`.
    let cadenceAdverb: String
    let templateName: String
    /// The record's live `isActive` — the staged toggle's dirty baseline.
    let originalIsActive: Bool
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

    // MARK: - Repeats (repeat-in-edit rework)

    /// Non-nil for a board with a RESOLVED source repeating record → the
    /// "↻ Repeats … · from …" variant with the staged Repeating/Paused
    /// toggle. nil for a one-off board (cadence segmented instead) or an
    /// unresolved (soft-deleted) record (section hidden entirely — same
    /// rule as web's `BoardEditRepeatSection`).
    var repeatInfo: BoardEditRepeatInfo? = nil

    /// Staged Active value for the repeating-board variant. Plain
    /// `Binding` var (not `@Binding`) so it can default to `.constant` for
    /// existing preview/snapshot call sites.
    var repeatActive: Binding<Bool> = .constant(true)

    /// Staged cadence for the one-off variant (`nil` = Off, the default).
    var repeatCadence: Binding<Timeframe?> = .constant(nil)

    /// Read-only spawn-provenance note (computed off-main by the VM only
    /// while the panel is open); nil hides the line.
    var spawnNoteText: String? = nil

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

    /// Repeat-in-edit — whether the one-off REPEATS variant is shown: no
    /// source record on the board AND a non-CHOSEN staged center (a CHOSEN
    /// center can never validate a spawn pool — `validateSpawnPool` rejects
    /// it as `.unsupportedCenter` — so the section is hidden for it).
    private var showsOneOffRepeat: Bool {
        board.spawnedFromTemplateId == nil && centerType != .chosen
    }

    /// Repeat-in-edit — the staged REPEATS draft's contribution to the edit
    /// counter: 1 iff Save would actually run a repeat mutation.
    private var repeatEditCount: Int {
        if let info = repeatInfo {
            return repeatActive.wrappedValue != info.originalIsActive ? 1 : 0
        }
        if showsOneOffRepeat, repeatCadence.wrappedValue != nil { return 1 }
        return 0
    }

    /// True if any draft field has been changed from the original board values,
    /// or if any square has a staged replacement or task-field edit.
    private var isDirty: Bool {
        if squareEditCount > 0 { return true }
        if repeatEditCount > 0 { return true }
        if name.trimmingCharacters(in: .whitespaces) != board.name { return true }
        if timeframe != board.timeframe { return true }
        if centerType != board.centerSquareType { return true }
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
        let centerChanged = centerType != board.centerSquareType
        if centerChanged { n += 1 }
        n += repeatEditCount
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
                    weekStartDay: weekStartDay,
                    chosenCenterDisabled: board.centerTaskId == nil || !hasCandidateTasks
                )
                repeatsSection
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

    // MARK: - Repeats section (repeat-in-edit rework)

    /// Staged cadence options for the one-off variant — Off (default) plus
    /// the four cadences from the retired play-surface "Repeat this
    /// board…" picker (labels unchanged).
    private static let repeatCadenceOptions: [(value: Timeframe?, label: String)] = [
        (nil, "Off"),
        (.daily, "Daily"),
        (.weekly, "Weekly"),
        (.monthly, "Monthly"),
        (.yearly, "Yearly"),
    ]

    /// The staged REPEATS section (replaces the retired play-surface
    /// `RisoRecurringManageRow` / `RisoRepeatBoardCTA`). Both variants are
    /// STAGED like every other edit field — nothing writes until Save;
    /// Cancel discards. A CHOSEN-center one-off board (and a repeating
    /// board whose source record didn't resolve) hides the section.
    @ViewBuilder
    private var repeatsSection: some View {
        if let info = repeatInfo {
            VStack(alignment: .leading, spacing: 10) {
                Text("REPEATS")
                    .risoSectionLabel()
                Text("↻ Repeats \(info.cadenceAdverb) · from \"\(info.templateName)\"")
                    .font(.risoBody(12.5, .semibold))
                    .foregroundStyle(Color.risoInk)
                    .fixedSize(horizontal: false, vertical: true)
                RisoSegmented(
                    options: [(true, "Repeating"), (false, "Paused")],
                    selection: repeatActive
                )
                if let spawnNoteText {
                    Text(spawnNoteText)
                        .font(.risoBody(11.5, .semibold))
                        .foregroundStyle(Color.risoMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        } else if showsOneOffRepeat {
            VStack(alignment: .leading, spacing: 10) {
                Text("REPEATS")
                    .risoSectionLabel()
                RisoSegmented(
                    options: Self.repeatCadenceOptions,
                    selection: repeatCadence
                )
                if repeatCadence.wrappedValue != nil {
                    Text("This becomes a repeating board when you save.")
                        .font(.risoBody(12, .regular))
                        .foregroundStyle(Color.risoMuted)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
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

// MARK: - Preview

#Preview {
    struct PreviewWrapper: View {
        @State var name = "Spring Goals"
        @State var timeframe = Timeframe.monthly
        @State var startDate = Date()
        @State var endDate = Date().addingTimeInterval(30 * 24 * 3600)
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
                weekStartDay: "monday",
                originalCustomStartDate: startDate,
                originalCustomEndDate: endDate,
                name: $name,
                timeframe: $timeframe,
                customStartDate: $startDate,
                customEndDate: $endDate,
                centerType: $centerType,
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
