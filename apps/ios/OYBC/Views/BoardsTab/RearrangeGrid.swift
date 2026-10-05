import SwiftUI

// MARK: - RearrangeCellData

/// One slot in the Rearrange sub-mode grid.
///
/// Identifiable by a stable `id`:
///   - Task cells: the `BoardTask.id` (boardTaskId).
///   - FREE / custom-FREE center: `"center"`.
///   - Empty non-center slots: `"empty-\(originalRow)-\(originalCol)"`.
///
/// Display data (title, task type) is looked up at render time from an
/// externally-supplied `taskMap` so that Phase-2 task-field overrides
/// remain reflected without rebuilding this array.
struct RearrangeCellData: Identifiable, Equatable {
    /// Stable unique identifier — `BoardTask.id`, `"center"`, or `"empty-R-C"`.
    let id: String
    /// The cell's CURRENT (staged) `Task.id` — used to look the task up in the
    /// taskId-keyed map. Reflects a same-session Replace. nil for center/empty.
    let taskId: String?
    let isCenter: Bool
    let isEmpty: Bool
    /// Original DB `(row, col)` — used to compute position moves at Save time.
    let originalRow: Int
    let originalCol: Int
    /// Board Edit redesign slice 1 — per-square lock (`BoardTask.isLocked`,
    /// with any staged override applied). A locked cell is pinned exactly
    /// like the center: it never lifts, never jiggles, is not a drop target,
    /// and the cascade routes around it.
    var isLocked: Bool = false

    /// Pinned = fixed in place for every rearrange gesture and the cascade.
    var isPinned: Bool { isCenter || isLocked }
}

// MARK: - RearrangeGrid

/// Reusable drag-to-insert + tap-to-swap grid for Phase 3 (board edit) and Phase 4
/// (create arrange wizard).
///
/// ### Interactions (when `rearrange == true`)
/// - **Drag-to-insert** (default): Press + move past ~6 px lifts a tile; a tilted ghost
///   follows the finger while the source slot shows as a dashed hole. As the drag moves
///   over other slots the grid cascades live (spring slide) and the gap follows the insertion
///   point. Release commits the new order via `onReorder`. One staged edit per drop.
/// - **Tap-to-swap**: tap a tile to pick it up (gold ring; rest dims). Tap another to swap;
///   tap the same to cancel. One staged edit per swap.
/// - **Jiggle**: a gentle ±`RearrangeJiggle.amplitudeDegrees` sway on all non-center,
///   non-empty tiles, driven by a `TimelineView` that pauses — and snaps to exactly 0° —
///   the moment `rearrange` goes false. Suspended while a drag or tap-pick is in progress;
///   off entirely under Reduce Motion.
///
/// ### Pinning
/// Cells with `isPinned` (the center, or a per-square lock — slice 1) never lift, never accept
/// drops, and never jiggle. Empty slots are also inert (they do shift position during cascades if
/// movable cells slide past them, but they themselves cannot be dragged). The cascade algorithm
/// skips all fixed slots.
///
/// ### Cell face
/// Every non-hole slot renders `RisoBoardPlayCell` — the same square the board itself draws —
/// with the lock chip for locked cells and the gold pencil chip for cells that moved from their
/// original slot or are listed in `dirtyCellIds` (slice 1: one renderer everywhere).
///
/// ### Animation
/// Uses a `ZStack` with manually computed offsets (not `LazyVGrid`) so that array reorders
/// produce spring-animated position transitions rather than instant snaps. The dragged cell
/// becomes invisible (dashed hole) at its slot; a ghost tile rendered at the finger position
/// provides the "lifted" visual.
///
/// ### Callers
/// Board Edit redesign slice 3 (D7) retired this view's board-EDIT caller —
/// `BoardEditPanel` now renders `SquaresEditGrid` (a sibling view forked from
/// this one: press-and-hold instead of jiggle/tap-to-swap, no sub-mode,
/// dashed empty squares are tappable). The ONE remaining caller is the
/// wizard's Preview step (`BoardWizardPreviewStepView`, whose cells'
/// `originalRow/Col` reflect the wizard's placement array) — the wizard's
/// authoring-time rearrange is out of scope for the board-edit rework. The
/// view is self-contained; the caller only needs to supply `cells`,
/// `gridSize`, `taskMap`, `centerSquareType`, `sideLength`, and handle
/// `onReorder`.
///
/// - Parameters:
///   - cells: Ordered (row-major) array of all grid slots — task cells, center, empties.
///   - gridSize: Column (= row) count for the square bingo grid.
///   - taskMap: `[Task.id: Task]` — each cell's staged `taskId` is looked up here
///     for title + type display. (NOT keyed by boardTaskId.)
///   - centerSquareType: Controls the center cell label.
///   - rearrange: When `false` the grid is display-only — no jiggle, no gestures.
///   - sideLength: Explicit side length for the square grid in points. The caller provides
///     this (e.g. `UIScreen.main.bounds.width - 2 * Riso.gutter`). Derived explicitly
///     rather than via internal `GeometryReader` to avoid a known SwiftUI issue where
///     `proxy.size.width` reflects the pre-padding or screen width instead of the
///     correctly inset width when nested inside `.padding()` modifier chains.
///   - onReorder: Fires after each committed reorder with the new full ordered array.
struct RearrangeGrid: View {

    // MARK: - Props

    let cells: [RearrangeCellData]
    let gridSize: Int
    let taskMap: [String: Task]
    let centerSquareType: CenterSquareType
    var rearrange: Bool
    let sideLength: CGFloat
    var onReorder: ([RearrangeCellData]) -> Void

    /// Windowed-Completion-aware completion read for a cell's task (Windowed
    /// Completion — docs/WINDOWED_COMPLETION.md §Task caches).
    ///
    /// ⚠️ The default falls back to the lifetime `Task.isCompleted` cache and
    /// is UNSAFE for any surface that can display shared/library tasks — a
    /// task completed in a previous window renders green (the bleed-green
    /// class). An earlier version of this comment claimed the wizard preview
    /// "has no completed tasks yet" and could rely on the default; that was
    /// FALSE (PR #373's root cause) — the wizard preview now injects
    /// `previewIsCompleted` (windowed against the prospective board), and
    /// `BoardEditPanel` injects `BoardPlayViewModel.windowedIsCompleted(for:)`.
    /// Every PRODUCTION caller overrides this; the two snapshot-test call
    /// sites (`RearrangeGridSnapshotTests`, `WizardArrangePreviewSnapshotTests`)
    /// still rely on the default, which is safe only because their fixtures
    /// never carry completed tasks — don't copy that pattern into a real
    /// surface.
    var windowedIsCompleted: (Task) -> Bool = { $0.isCompleted }
    /// Windowed count twin for counting squares (the wizard preview injects
    /// `previewCount`, windowed against the prospective board).
    var windowedCount: (Task) -> Int = { $0.currentCount ?? 0 }

    /// Cell ids (boardTaskIds) with a staged, unsaved edit other than a move
    /// (replace / task override / lock change) — drawn with the pencil chip.
    /// Position moves are derived here from slot vs original.
    var dirtyCellIds: Set<String> = []

    // MARK: - Internal state

    /// Current display order — optimistically updated during drag preview;
    /// reset to `cells` when no interaction is in flight.
    @State private var displayCells: [RearrangeCellData] = []

    /// boardTaskId being dragged — its slot renders as a hole.
    @State private var draggingId: String? = nil

    /// Drag position in the "rearrangeGrid" named coordinate space (grid-local pixels).
    @State private var dragPosition: CGPoint = .zero

    /// True once the drag has crossed the minimumDistance threshold and a ghost
    /// + hole should be shown.
    @State private var dragActive: Bool = false

    /// Cell id picked for tap-to-swap (highlighted; others dimmed).
    @State private var tapPickedId: String? = nil

    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    // MARK: - Body

    var body: some View {
        // `displayCells` is empty until `onAppear` fires. When the caller provides
        // cells before the first appearance (e.g. Phase 4 wizard — `cells` updates
        // via a computed prop, `displayCells` lags one frame), fall back to `cells`
        // so the initial render is never blank.  After `onAppear` fires, both are
        // identical and `displayCells` is used for all animation / drag state.
        let renderCells = displayCells.isEmpty ? cells : displayCells

        // Cell geometry derived from the caller-supplied side length.
        // Previously used GeometryReader to measure the available width, but
        // GeometryReader.proxy.size.width can reflect the pre-padding or screen width
        // instead of the inset width when nested inside .padding() modifier chains —
        // a known SwiftUI quirk that caused cells to be sized and positioned incorrectly.
        let cellSize = RisoBoardGrid<EmptyView>.cellSide(forSideLength: sideLength, gridSize: gridSize)
        let stride = cellSize + Riso.cellGap

        ZStack(alignment: .topLeading) {
            // Transparent fill so the ZStack accepts the full proposed size from
            // .frame(width: sideLength, height: sideLength) below. Without this,
            // ZStack's natural size = one cell (cellSize × cellSize), and the .frame()
            // modifier centers the small ZStack within the larger frame — producing a
            // (sideLength - cellSize) / 2 centering offset on both axes. Color.clear
            // fills the full proposed space, giving ZStack a natural size of sideLength²
            // so the .frame() wraps it with no centering offset.
            Color.clear

            // ── Grid cells ──
            ForEach(renderCells) { cell in
                let slotIdx = renderCells.firstIndex(where: { $0.id == cell.id }) ?? 0
                let col = slotIdx % gridSize
                let row = slotIdx / gridSize
                let xOff = CGFloat(col) * stride
                let yOff = CGFloat(row) * stride

                let isHole = dragActive && cell.id == draggingId
                let isSelected = cell.id == tapPickedId
                // Dim when: dragging anything (except the dragged cell itself and center),
                // or a tap-pick is active (except the picked cell and center/empty).
                let isDimmed: Bool = {
                    if cell.isPinned { return false }
                    if dragActive && cell.id != draggingId { return true }
                    if let picked = tapPickedId, cell.id != picked, !cell.isEmpty { return true }
                    return false
                }()
                let showJiggle = rearrange
                    && !cell.isPinned
                    && !cell.isEmpty
                    && !dragActive
                    && tapPickedId == nil
                let isMoved = !cell.isPinned && !cell.isEmpty
                    && (row != cell.originalRow || col != cell.originalCol)

                rearrangeCellView(
                    cell: cell,
                    slot: slotIdx,
                    cellSize: cellSize,
                    isHole: isHole,
                    isSelected: isSelected,
                    isDimmed: isDimmed,
                    isDirty: isMoved || dirtyCellIds.contains(cell.id),
                    jiggleActive: showJiggle
                )
                .frame(width: cellSize, height: cellSize)
                // Hit region + gestures sit BEFORE `.offset`: `.offset` moves
                // rendering, not the layout frame, so a `contentShape` placed
                // after it would hit-test at the un-offset spot (every cell
                // stacked on slot 0 — the #516 SquaresEditGrid bug). The face
                // itself is non-hit-testable (see `rearrangeCellView`), so this
                // shape owns every touch on the cell.
                .contentShape(Rectangle())
                .gesture(rearrange && !cell.isPinned && !cell.isEmpty
                    ? makeDragGesture(for: cell, cellSize: cellSize, stride: stride)
                    : nil)
                .onTapGesture { handleTap(cell: cell) }
                .offset(x: xOff, y: yOff)
                // Animate position changes during live cascade and committed reorders.
                .animation(
                    .spring(response: 0.22, dampingFraction: 0.82),
                    value: slotIdx
                )
            }

            // ── Ghost (lifted tile that follows the finger) ──
            if dragActive,
               let dragId = draggingId,
               let draggedCell = displayCells.first(where: { $0.id == dragId }) {
                ghostView(for: draggedCell, cellSize: cellSize)
                    .frame(width: cellSize, height: cellSize)
                    .offset(
                        x: dragPosition.x - cellSize / 2,
                        y: dragPosition.y - cellSize / 2
                    )
                    .allowsHitTesting(false)
                    .zIndex(20)
            }
        }
        // Exact square frame from the caller-supplied side length.
        .frame(width: sideLength, height: sideLength)
        .coordinateSpace(name: "rearrangeGrid")
        .onAppear {
            displayCells = cells
        }
        // Sync external changes when no interaction is in flight.
        .onChange(of: cells) { _, newCells in
            guard draggingId == nil && tapPickedId == nil else { return }
            withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) {
                displayCells = newCells
            }
        }
    }

    // MARK: - Cell rendering

    /// One slot's face: `RisoBoardPlayCell` for every real cell (the board's
    /// own renderer — FREE center, task cells, chips), a dashed hole for the
    /// lifted tile, and a quiet paper tile for an empty slot (the drop
    /// target). Selection (tap-to-swap) is a gold ring around the cell;
    /// dimming is opacity — both applied outside the shared face so the
    /// face stays byte-identical to the board's.
    @ViewBuilder
    private func rearrangeCellView(
        cell: RearrangeCellData,
        slot: Int,
        cellSize: CGFloat,
        isHole: Bool,
        isSelected: Bool,
        isDimmed: Bool,
        isDirty: Bool,
        jiggleActive: Bool
    ) -> some View {
        let task = cell.taskId.flatMap { taskMap[$0] }

        ZStack {
            if isHole {
                RoundedRectangle(cornerRadius: Riso.cellRadius)
                    .strokeBorder(
                        Color.risoMuted.opacity(0.4),
                        style: StrokeStyle(lineWidth: Riso.Keyline.dense, dash: [6, 4])
                    )
            } else if cell.isEmpty {
                RoundedRectangle(cornerRadius: Riso.cellRadius)
                    .fill(Color.risoPaper)
                    .overlay(
                        RoundedRectangle(cornerRadius: Riso.cellRadius)
                            .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense)
                    )
            } else {
                faceCell(for: cell, task: task, isDirty: isDirty)
                    // Positional id for `OYBCUITests` (`WizardRearrangeUITests`);
                    // lands on the face's own accessibility element.
                    .accessibilityIdentifier("rearrangeCell.\(slot)")
                    .overlay(
                        Group {
                            if isSelected {
                                RoundedRectangle(cornerRadius: Riso.cellRadius)
                                    .stroke(Color.risoGold, lineWidth: 3)
                                    .padding(-3)
                            }
                        }
                    )
            }
        }
        .opacity(isDimmed ? 0.45 : 1.0)
        .modifier(RearrangeJiggleModifier(active: jiggleActive && !reduceMotion))
        // `RisoBoardPlayCell` always attaches its own (play-mode) tap gesture;
        // as a child gesture it outranks the grid's `onTapGesture`, so
        // tap-to-swap never fired. The grid's cell-level `contentShape` takes
        // every touch instead. Accessibility is unaffected.
        .allowsHitTesting(false)
    }

    /// The shared board square for a real cell (center or task). Windowed
    /// Completion parity: completion resolves via the injected closure, never
    /// the raw lifetime cache (docs/WINDOWED_COMPLETION.md §Task caches).
    private func faceCell(for cell: RearrangeCellData, task: Task?, isDirty: Bool) -> RisoBoardPlayCell {
        let isTaskCompleted = task.map(windowedIsCompleted) ?? false
        if cell.isCenter {
            // FREE → the gold star + "FREE"; CHOSEN → the star + the task's
            // title, exactly as the board renders its center.
            return RisoBoardPlayCell(
                title: centerSquareType == .chosen ? (task?.title ?? "FREE") : "FREE",
                taskType: .normal,
                isCompleted: false,
                isCenter: true,
                showsLockChip: cell.isLocked,
                showsDirtyChip: isDirty
            )
        }
        return RisoBoardPlayCell(
            title: task?.title ?? "",
            taskType: task.map { CellTaskType(task: $0) } ?? .normal,
            isCompleted: isTaskCompleted,
            showsLockChip: cell.isLocked,
            showsDirtyChip: isDirty,
            currentCount: task.map(windowedCount) ?? 0,
            maxCount: task?.maxCount ?? 0
        )
    }

    // MARK: - Ghost tile

    @ViewBuilder
    private func ghostView(for cell: RearrangeCellData, cellSize: CGFloat) -> some View {
        let task = cell.taskId.flatMap { taskMap[$0] }

        // The lifted tile is the same square, ringed gold, over a hard shadow.
        faceCell(for: cell, task: task, isDirty: false)
            .overlay(
                RoundedRectangle(cornerRadius: Riso.cellRadius)
                    .strokeBorder(Color.risoGold, lineWidth: Riso.Keyline.container)
            )
            .background(
                RoundedRectangle(cornerRadius: Riso.cellRadius)
                    .fill(Color.risoInk.opacity(0.18))
                    .offset(x: Riso.Shadow.button, y: Riso.Shadow.card)
            )
            // Tilt + slight scale to convey "lifted" state
            .rotationEffect(.degrees(4))
            .scaleEffect(1.06)
    }

    // MARK: - Drag gesture

    /// Builds a `DragGesture` for the given cell. Returns `nil` when the cell
    /// should be inert (center, empty, or `rearrange == false`).
    private func makeDragGesture(
        for cell: RearrangeCellData,
        cellSize: CGFloat,
        stride: CGFloat
    ) -> some Gesture {
        DragGesture(minimumDistance: 6, coordinateSpace: .named("rearrangeGrid"))
            .onChanged { value in
                if !dragActive {
                    // Drag just crossed the threshold — activate
                    draggingId = cell.id
                    tapPickedId = nil   // cancel any tap-pick
                    dragActive = true
                }
                dragPosition = value.location

                // Slot hit-test: compute target from finger position in grid-local coords.
                // This is always stable regardless of in-flight cascade animation positions
                // because it uses the fixed slot geometry, not the live tile positions.
                let targetCol = max(0, min(gridSize - 1, Int(value.location.x / stride)))
                let targetRow = max(0, min(gridSize - 1, Int(value.location.y / stride)))
                let targetIndex = targetRow * gridSize + targetCol

                if let reordered = reorderToSlot(
                    cells: displayCells,
                    draggingId: cell.id,
                    targetIndex: targetIndex
                ) {
                    withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                        displayCells = reordered
                    }
                }
            }
            .onEnded { _ in
                let finalCells = displayCells
                // Determine if the order actually changed vs. the committed `cells` prop.
                let changed = !zip(finalCells, cells).allSatisfy { $0.id == $1.id }

                withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
                    draggingId = nil
                    dragActive = false
                    dragPosition = .zero
                }

                if changed {
                    onReorder(finalCells)
                }
            }
    }

    // MARK: - Tap-to-swap

    private func handleTap(cell: RearrangeCellData) {
        guard rearrange, !cell.isPinned, !cell.isEmpty, !dragActive else { return }

        if let picked = tapPickedId {
            if picked == cell.id {
                // Tap the same cell → cancel pick
                withAnimation(.easeOut(duration: 0.15)) { tapPickedId = nil }
            } else {
                // Tap a different cell → swap
                performSwap(idA: picked, idB: cell.id)
                withAnimation(.easeOut(duration: 0.15)) { tapPickedId = nil }
            }
        } else {
            // No pick in flight → pick this cell
            withAnimation(.easeOut(duration: 0.15)) { tapPickedId = cell.id }
        }
    }

    private func performSwap(idA: String, idB: String) {
        var newCells = displayCells
        guard
            let iA = newCells.firstIndex(where: { $0.id == idA }),
            let iB = newCells.firstIndex(where: { $0.id == idB })
        else { return }
        newCells.swapAt(iA, iB)
        withAnimation(.spring(response: 0.28, dampingFraction: 0.78)) {
            displayCells = newCells
        }
        onReorder(newCells)
    }

    // MARK: - Reorder algorithm

    /// Translates the dragged cell to `targetIndex` (row-major slot), cascading
    /// other movable cells around it in row-major order. Returns the new array,
    /// or `nil` if the order is unchanged. Fixed slots (pinned — center or
    /// locked — and empty) remain in their positions; only movable task cells
    /// move.
    ///
    /// Mirrors the prototype's `reorderToSlot` from `arrange-board-ios.jsx`.
    private func reorderToSlot(
        cells: [RearrangeCellData],
        draggingId: String,
        targetIndex: Int
    ) -> [RearrangeCellData]? {
        guard targetIndex < cells.count else { return nil }
        let target = cells[targetIndex]
        // A pinned slot (center, locked square) is never a drop target.
        guard !target.isPinned else { return nil }

        // Empty target: drop the tile straight into the empty slot (swap their
        // array positions). The vacated slot becomes empty; index-based position
        // mapping commits only the moved tile's new row/col. (Boards with fewer
        // tasks than cells — parity with web, which also allows drop-to-empty.)
        if target.isEmpty {
            guard
                let fromIdx = cells.firstIndex(where: { $0.id == draggingId }),
                fromIdx != targetIndex
            else { return nil }
            var result = cells
            result.swapAt(fromIdx, targetIndex)
            return result
        }

        // Build the list of movable slot indices (non-fixed, in row-major order).
        let movableIndices = cells.indices.filter {
            !cells[$0].isPinned && !cells[$0].isEmpty
        }
        // Find which position in the movable list corresponds to targetIndex.
        guard let toK = movableIndices.firstIndex(of: targetIndex) else { return nil }

        let movable = movableIndices.map { cells[$0] }
        guard let dragged = movable.first(where: { $0.id == draggingId }) else { return nil }

        var without = movable.filter { $0.id != draggingId }
        without.insert(dragged, at: toK)

        var result = cells
        for (k, slotIdx) in movableIndices.enumerated() {
            result[slotIdx] = without[k]
        }

        // Return nil if the order is unchanged (avoids a redundant animation).
        let changed = !zip(result, cells).allSatisfy { $0.id == $1.id }
        return changed ? result : nil
    }
}

// MARK: - Jiggle

/// The Rearrange-mode jiggle's values + angle curve. Shared with web
/// `ArrangeGrid.module.css` `.jiggle` / `@keyframes wbJiggle` — keep the two
/// in lockstep: ±0.4°, 0.28 s per half-cycle.
///
/// Pure time → angle, so the sway is a function of the clock rather than a
/// running animation. The previous implementation started a
/// `.repeatForever(autoreverses:)` transaction on a toggled `@State` phase;
/// a repeat-forever animation can't be cancelled by later state changes, so
/// the tiles kept shaking after leaving Rearrange. Now nothing is "running":
/// when inactive the angle is exactly 0.
enum RearrangeJiggle {
    /// Peak rotation either side of 0°.
    static let amplitudeDegrees: Double = 0.4
    /// Seconds from one extreme to the other (one `alternate` leg on web).
    static let halfCycleSeconds: Double = 0.28

    /// Rotation in degrees at `time` (seconds). `0` whenever `active` is false.
    /// - Parameters:
    ///   - active: Whether this tile is jiggling (rearrange on, not dragging,
    ///     not tap-picked, Reduce Motion off).
    ///   - time: Any monotonic clock in seconds.
    /// - Returns: An angle in `[-amplitudeDegrees, amplitudeDegrees]`.
    static func angle(active: Bool, time: TimeInterval) -> Double {
        guard active else { return 0 }
        return amplitudeDegrees * sin(.pi * time / halfCycleSeconds)
    }
}

/// Applies `RearrangeJiggle` to a tile. The `TimelineView` is always present
/// (stable view identity for the tile underneath) but its schedule pauses when
/// inactive, and the angle is then exactly 0 — so the shake stops the moment
/// `rearrange` flips false, deterministically.
private struct RearrangeJiggleModifier: ViewModifier {
    let active: Bool

    func body(content: Content) -> some View {
        TimelineView(.animation(paused: !active)) { context in
            content.rotationEffect(.degrees(
                RearrangeJiggle.angle(
                    active: active,
                    time: context.date.timeIntervalSinceReferenceDate
                )
            ))
        }
    }
}
