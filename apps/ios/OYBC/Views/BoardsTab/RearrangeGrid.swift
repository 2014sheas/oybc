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
/// - **Jiggle**: autoreversing ±0.8° rotation on all non-center, non-empty tiles. Suspended
///   while a drag or tap-pick is in progress.
///
/// ### Pinning
/// Cells with `isCenter == true` never lift, never accept drops, and never jiggle. Empty slots
/// are also inert (they do shift position during cascades if movable cells slide past them, but
/// they themselves cannot be dragged). The cascade algorithm skips all fixed slots.
///
/// ### Animation
/// Uses a `ZStack` with manually computed offsets (not `LazyVGrid`) so that array reorders
/// produce spring-animated position transitions rather than instant snaps. The dragged cell
/// becomes invisible (dashed hole) at its slot; a ghost tile rendered at the finger position
/// provides the "lifted" visual.
///
/// ### Phase 4 reuse
/// Phase 4 (create arrange) will pass its own `[RearrangeCellData]` with `originalRow/Col`
/// reflecting the wizard's placement array. The view is self-contained; the caller only needs
/// to supply `cells`, `gridSize`, `taskMap`, `centerSquareType`, `sideLength`, and
/// handle `onReorder`.
///
/// - Parameters:
///   - cells: Ordered (row-major) array of all grid slots — task cells, center, empties.
///   - gridSize: Column (= row) count for the square bingo grid.
///   - taskMap: `[Task.id: Task]` — each cell's staged `taskId` is looked up here
///     for title + type display. (NOT keyed by boardTaskId.)
///   - centerSquareType: Controls the center cell label.
///   - centerCustomName: Custom label when `centerSquareType == .customFree`.
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
    var centerCustomName: String = ""
    var rearrange: Bool
    let sideLength: CGFloat
    var onReorder: ([RearrangeCellData]) -> Void

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

    /// Jiggle clock — toggled once to start the autoreversing animation.
    @State private var jigglePhase: Bool = false

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
        let cellSize = (sideLength - CGFloat(gridSize - 1) * Riso.cellGap) / CGFloat(gridSize)
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
                    if cell.isCenter { return false }
                    if dragActive && cell.id != draggingId { return true }
                    if let picked = tapPickedId, cell.id != picked, !cell.isEmpty { return true }
                    return false
                }()
                let showJiggle = rearrange
                    && !cell.isCenter
                    && !cell.isEmpty
                    && !dragActive
                    && tapPickedId == nil

                rearrangeCellView(
                    cell: cell,
                    cellSize: cellSize,
                    isHole: isHole,
                    isSelected: isSelected,
                    isDimmed: isDimmed,
                    jiggleActive: showJiggle
                )
                .frame(width: cellSize, height: cellSize)
                .offset(x: xOff, y: yOff)
                // Animate position changes during live cascade and committed reorders.
                .animation(
                    .spring(response: 0.22, dampingFraction: 0.82),
                    value: slotIdx
                )
                .gesture(rearrange && !cell.isCenter && !cell.isEmpty
                    ? makeDragGesture(for: cell, cellSize: cellSize, stride: stride)
                    : nil)
                .onTapGesture { handleTap(cell: cell) }
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
            if rearrange { kickJiggle() }
        }
        // Sync external changes when no interaction is in flight.
        .onChange(of: cells) { _, newCells in
            guard draggingId == nil && tapPickedId == nil else { return }
            withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) {
                displayCells = newCells
            }
        }
        .onChange(of: rearrange) { _, active in
            if active { kickJiggle() } else { stopJiggle() }
        }
    }

    // MARK: - Jiggle

    /// Starts the autoreversing jiggle by toggling `jigglePhase` with a
    /// `repeatForever(autoreverses: true)` animation. Cells read this phase
    /// to decide their rotation. No-ops when `rearrange` is false.
    private func kickJiggle() {
        withAnimation(
            .easeInOut(duration: 0.14).repeatForever(autoreverses: true)
        ) {
            jigglePhase.toggle()
        }
    }

    /// Snaps the jiggle back to 0° with a brief ease-out.
    private func stopJiggle() {
        withAnimation(.easeOut(duration: 0.12)) {
            jigglePhase = false
        }
    }

    // MARK: - Cell rendering

    @ViewBuilder
    private func rearrangeCellView(
        cell: RearrangeCellData,
        cellSize: CGFloat,
        isHole: Bool,
        isSelected: Bool,
        isDimmed: Bool,
        jiggleActive: Bool
    ) -> some View {
        let task = cell.taskId.flatMap { taskMap[$0] }

        // ── Label ──
        let label: String = {
            if cell.isCenter {
                switch centerSquareType {
                case .free:       return "FREE"
                case .customFree: return centerCustomName.isEmpty ? "FREE" : centerCustomName
                case .chosen:     return task?.title ?? "FREE"
                case .none:       return ""
                }
            }
            if cell.isEmpty { return "" }
            return task?.title ?? ""
        }()

        // ── Fill ──
        let fill: Color = {
            if isHole     { return .clear }
            if cell.isCenter || isSelected { return .risoGold }
            if isDimmed   { return .risoPaper }
            return (task?.isCompleted == true) ? .risoGreen : .risoPaper2
        }()

        // ── Text color ──
        let textColor: Color = {
            if cell.isCenter || isSelected { return .risoInkStatic }
            if task?.isCompleted == true   { return .risoPaper }
            return isDimmed ? .risoMuted : .risoInk
        }()

        // ── Border ──
        let borderColor: Color = {
            if isHole      { return .risoMuted.opacity(0.4) }
            if cell.isCenter || isSelected { return .risoInkStatic.opacity(isSelected ? 0.5 : 0.3) }
            return isDimmed ? .risoMuted.opacity(0.25) : .risoInk
        }()
        let borderStyle: StrokeStyle = isHole
            ? StrokeStyle(lineWidth: 1.5, dash: [6, 4])
            : StrokeStyle(lineWidth: isSelected ? Riso.Keyline.container : Riso.Keyline.dense)

        ZStack(alignment: .topTrailing) {
            // Background + border
            RoundedRectangle(cornerRadius: Riso.cellRadius)
                .fill(fill)
                .overlay(
                    RoundedRectangle(cornerRadius: Riso.cellRadius)
                        .strokeBorder(borderColor, style: borderStyle)
                )

            if !isHole {
                // Center star icon for pure-FREE center
                if cell.isCenter && (centerSquareType == .free || centerSquareType == .customFree)
                    && centerSquareType == .free {
                    Image(systemName: "star.fill")
                        .font(.system(size: cellSize * 0.28, weight: .bold))
                        .foregroundStyle(Color.risoInkStatic.opacity(0.6))
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else if !label.isEmpty {
                    // Cell label
                    Text(label)
                        .font(.risoBody(max(7, min(10, cellSize * 0.19)), .semibold))
                        .foregroundStyle(textColor)
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .padding(4)
                        .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
                }

                // Task-type letter badge (top-trailing) — only on non-center task cells
                if !cell.isCenter, !cell.isEmpty, let task = task {
                    RisoTypeBadge(kind: task.type.rearrangeKind, style: .letterSquare)
                        .scaleEffect(0.75)
                        .padding(2)
                }
            }
        }
        .opacity(isDimmed ? 0.45 : 1.0)
        // Jiggle: autoreversing ±0.8° when the mode is active; suspended during
        // drag and tap-pick. The `jigglePhase` boolean drives the rotation value;
        // the `.repeatForever` animation is started by `kickJiggle()`.
        .rotationEffect(
            .degrees(jiggleActive ? (jigglePhase ? 0.8 : -0.8) : 0)
        )
        .animation(
            jiggleActive
                ? .easeInOut(duration: 0.14).repeatForever(autoreverses: true)
                : .easeOut(duration: 0.1),
            value: jigglePhase
        )
    }

    // MARK: - Ghost tile

    @ViewBuilder
    private func ghostView(for cell: RearrangeCellData, cellSize: CGFloat) -> some View {
        let task = cell.taskId.flatMap { taskMap[$0] }
        let label = task?.title ?? ""

        ZStack {
            RoundedRectangle(cornerRadius: Riso.cellRadius)
                .fill(Color.risoPaper2)
                .overlay(
                    RoundedRectangle(cornerRadius: Riso.cellRadius)
                        .strokeBorder(Color.risoGold, lineWidth: Riso.Keyline.container)
                )
                // Hard shadow beneath the lifted tile
                .background(
                    RoundedRectangle(cornerRadius: Riso.cellRadius)
                        .fill(Color.risoInk.opacity(0.18))
                        .offset(x: 3, y: 4)
                )

            if !label.isEmpty {
                Text(label)
                    .font(.risoBody(max(7, min(10, cellSize * 0.19)), .semibold))
                    .foregroundStyle(Color.risoInk)
                    .multilineTextAlignment(.center)
                    .lineLimit(3)
                    .padding(4)
                    .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .center)
            }
        }
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
        guard rearrange, !cell.isCenter, !cell.isEmpty, !dragActive else { return }

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
    /// or `nil` if the order is unchanged. Fixed slots (center + empty) remain
    /// in their positions; only task cells move.
    ///
    /// Mirrors the prototype's `reorderToSlot` from `arrange-board-ios.jsx`.
    private func reorderToSlot(
        cells: [RearrangeCellData],
        draggingId: String,
        targetIndex: Int
    ) -> [RearrangeCellData]? {
        guard targetIndex < cells.count else { return nil }
        let target = cells[targetIndex]
        // The center is never a drop target.
        guard !target.isCenter else { return nil }

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
            !cells[$0].isCenter && !cells[$0].isEmpty
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

// MARK: - TaskType → RisoTaskKind (file-private)

private extension TaskType {
    var rearrangeKind: RisoTaskKind {
        switch self {
        case .normal:      return .normal
        case .counting:    return .counting
        case .compound:    return .compound
        case .achievement: return .achievement
        }
    }
}
