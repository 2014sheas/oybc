import SwiftUI
import UIKit

// MARK: - SquaresEditGrid
//
// Board Edit redesign slice 3 (D7–D9) — evolved from the retired
// `RearrangeGrid`: ONE mode, no jiggle, no tap-to-swap toggle. Every square
// (including the FREE center and empty dashed squares) is tappable —
// routed by the caller to the square menu / picker. A movable square
// (not locked, not FREE, not empty) additionally lifts on a long-press then
// drags with the same cascade math `RearrangeGrid` used.
//
/// Reusable squares-edit grid for Board Edit (D7).
///
/// ### Interactions
/// - **Tap** any square (task, locked, empty, or the FREE center) → `onTap`.
///   Routed by the caller to the square menu (occupied) or the picker
///   (empty) or the center dialog (FREE).
/// - **Long-press (0.35s) then drag** a movable square → lift + live
///   cascade (identical slot-rect hit-testing to `RearrangeGrid`); release
///   commits the new order via `onReorder`. Attached via `.simultaneousGesture`
///   so a quick tap still resolves as `onTap` (D8).
/// - Locked squares and the FREE center never lift and are never drop
///   targets (`SquareEditCellData.isPinned`).
///
/// ### Accessibility (D9)
/// Movable cells expose `accessibilityActions` — "Move up/down/left/right" —
/// which call `onKeyboardMove` to swap with the neighbor one step over.
struct SquaresEditGrid: View {

    // MARK: - Props

    let cells: [SquareEditCellData]
    let gridSize: Int
    let taskMap: [String: Task]
    let sideLength: CGFloat
    var onTap: (String) -> Void
    var onReorder: ([SquareEditCellData]) -> Void
    var onKeyboardMove: (String, SquaresEditDirection) -> Void

    /// Windowed-Completion-aware completion read (docs/WINDOWED_COMPLETION.md
    /// §Task caches) — see the equivalent doc on the retired `RearrangeGrid`.
    var windowedIsCompleted: (Task) -> Bool = { $0.isCompleted }

    // MARK: - Internal state

    @State private var displayCells: [SquareEditCellData] = []
    @State private var liftedId: String? = nil
    @State private var dragActive: Bool = false
    @State private var dragPosition: CGPoint = .zero

    // MARK: - Body

    var body: some View {
        let renderCells = displayCells.isEmpty ? cells : displayCells
        let cellSize = RisoBoardGrid<EmptyView>.cellSide(forSideLength: sideLength, gridSize: gridSize)
        let stride = cellSize + Riso.cellGap

        ZStack(alignment: .topLeading) {
            Color.clear

            ForEach(renderCells) { cell in
                let slotIdx = renderCells.firstIndex(where: { $0.id == cell.id }) ?? 0
                let col = slotIdx % gridSize
                let row = slotIdx / gridSize
                let xOff = CGFloat(col) * stride
                let yOff = CGFloat(row) * stride

                let isHole = dragActive && cell.id == liftedId
                let isMovable = !cell.isPinned && !cell.isEmpty
                let isDimmed = dragActive && cell.id != liftedId && !cell.isEmpty

                squareCellView(
                    cell: cell,
                    isHole: isHole,
                    isDimmed: isDimmed
                )
                .frame(width: cellSize, height: cellSize)
                .offset(x: xOff, y: yOff)
                .animation(.spring(response: 0.22, dampingFraction: 0.82), value: slotIdx)
                .contentShape(Rectangle())
                .onTapGesture { onTap(cell.id) }
                .simultaneousGesture(
                    isMovable ? longPressDragGesture(for: cell, stride: stride) : nil
                )
                .accessibilityElement(children: .combine)
                .accessibilityActions {
                    if isMovable {
                        Button("Move up") { onKeyboardMove(cell.id, .up) }
                        Button("Move down") { onKeyboardMove(cell.id, .down) }
                        Button("Move left") { onKeyboardMove(cell.id, .left) }
                        Button("Move right") { onKeyboardMove(cell.id, .right) }
                    }
                }
            }

            if dragActive,
               let dragId = liftedId,
               let draggedCell = displayCells.first(where: { $0.id == dragId }) {
                ghostView(for: draggedCell, cellSize: cellSize)
                    .frame(width: cellSize, height: cellSize)
                    .offset(x: dragPosition.x - cellSize / 2, y: dragPosition.y - cellSize / 2)
                    .allowsHitTesting(false)
                    .zIndex(20)
            }
        }
        .frame(width: sideLength, height: sideLength)
        .coordinateSpace(name: "squaresEditGrid")
        .onAppear { displayCells = cells }
        .onChange(of: cells) { _, newCells in
            guard liftedId == nil else { return }
            withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) {
                displayCells = newCells
            }
        }
    }

    // MARK: - Cell rendering

    @ViewBuilder
    private func squareCellView(cell: SquareEditCellData, isHole: Bool, isDimmed: Bool) -> some View {
        ZStack {
            if isHole {
                RoundedRectangle(cornerRadius: Riso.cellRadius)
                    .strokeBorder(
                        Color.risoMuted.opacity(0.4),
                        style: StrokeStyle(lineWidth: Riso.Keyline.dense, dash: [6, 4])
                    )
            } else if cell.isEmpty {
                // D16 — "a dashed paper cell" (handoff `DIRTY_DAILY[18]`,
                // `board-edit-data.js:307`, keyline 1.5px dashed). Matches
                // the play-mode empty square's dash style (BoardPlayView).
                RoundedRectangle(cornerRadius: Riso.cellRadius)
                    .fill(Color.risoPaper)
                    .overlay(
                        RoundedRectangle(cornerRadius: Riso.cellRadius)
                            .strokeBorder(
                                Color.risoInk.opacity(0.35),
                                style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])
                            )
                    )
            } else {
                faceCell(for: cell)
            }
        }
        .opacity(isDimmed ? 0.45 : 1.0)
    }

    /// The shared board square for a real cell (FREE center or task/pending
    /// task). Reads a pending cell's title/type from its payload rather
    /// than `taskMap` (the task doesn't exist in the DB yet).
    private func faceCell(for cell: SquareEditCellData) -> RisoBoardPlayCell {
        if cell.isCenter {
            return RisoBoardPlayCell(
                title: "FREE",
                taskType: .normal,
                isCompleted: false,
                isCenter: true,
                showsLockChip: false,
                showsDirtyChip: false
            )
        }
        let task = cell.pending?.task ?? cell.taskId.flatMap { taskMap[$0] }
        let isTaskCompleted = task.map(windowedIsCompleted) ?? false
        return RisoBoardPlayCell(
            title: task?.title ?? "",
            taskType: task.map { CellTaskType(task: $0) } ?? .normal,
            isCompleted: isTaskCompleted,
            showsLockChip: cell.isLocked,
            showsDirtyChip: cell.isDirty,
            currentCount: task?.currentCount ?? 0,
            maxCount: task?.maxCount ?? 0
        )
    }

    // MARK: - Ghost tile

    @ViewBuilder
    private func ghostView(for cell: SquareEditCellData, cellSize: CGFloat) -> some View {
        faceCell(for: cell)
            .overlay(
                RoundedRectangle(cornerRadius: Riso.cellRadius)
                    .strokeBorder(Color.risoGold, lineWidth: Riso.Keyline.container)
            )
            .background(
                RoundedRectangle(cornerRadius: Riso.cellRadius)
                    .fill(Color.risoInk.opacity(0.18))
                    .offset(x: Riso.Shadow.button, y: Riso.Shadow.card)
            )
            .rotationEffect(.degrees(4))
            .scaleEffect(1.06)
    }

    // MARK: - Long-press-then-drag gesture (D8)

    private func longPressDragGesture(
        for cell: SquareEditCellData,
        stride: CGFloat
    ) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35)
            .sequenced(before: DragGesture(minimumDistance: 0, coordinateSpace: .named("squaresEditGrid")))
            .onChanged { value in
                switch value {
                case .first(true):
                    guard liftedId != cell.id else { return }
                    liftedId = cell.id
                    dragActive = true
                    UIImpactFeedbackGenerator(style: .medium).impactOccurred()
                case .second(true, let dragValue):
                    guard let dragValue else { return }
                    dragPosition = dragValue.location
                    let targetCol = max(0, min(gridSize - 1, Int(dragValue.location.x / stride)))
                    let targetRow = max(0, min(gridSize - 1, Int(dragValue.location.y / stride)))
                    let targetIndex = targetRow * gridSize + targetCol
                    if let reordered = reorderSquaresToSlot(
                        cells: displayCells, draggingId: cell.id, targetIndex: targetIndex
                    ) {
                        withAnimation(.spring(response: 0.22, dampingFraction: 0.82)) {
                            displayCells = reordered
                        }
                    }
                default:
                    break
                }
            }
            .onEnded { _ in
                let finalCells = displayCells
                let changed = !zip(finalCells, cells).allSatisfy { $0.id == $1.id }
                withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
                    liftedId = nil
                    dragActive = false
                    dragPosition = .zero
                }
                if changed { onReorder(finalCells) }
            }
    }
}
