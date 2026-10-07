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
/// - **Long-press (0.35s) then drag** a movable square → lift (+ haptic) the
///   moment the hold COMPLETES, then live cascade (identical slot-rect
///   hit-testing to `RearrangeGrid`); release commits the new order via
///   `onReorder`. Attached via `.simultaneousGesture` so a quick tap still
///   resolves as `onTap` (D8); the tap that trails a hold is swallowed so
///   hold-and-release never opens the menu. A gesture the system cancels
///   (incoming call, scroll takeover…) reverts the lift instead of leaving
///   the grid stuck. `onLiftChange` lets the host lock its ScrollView while
///   a square is lifted so the scroll pan can't steal the drag.
///
/// ### Hit-testing invariants (the "hold-to-move does nothing" bug)
/// 1. Cells are placed by `.offset`, which moves rendering but NOT the
///    layout frame. Every interaction and accessibility modifier
///    (`contentShape`, gestures, `accessibility*`) must sit BEFORE the
///    `.offset` so it travels with the rendered square. Attached after it,
///    all nine hit regions and VoiceOver frames collapse onto slot 0, where
///    the topmost (last) cell swallows every touch.
/// 2. The square face (`RisoBoardPlayCell`) is display-only here
///    (`.allowsHitTesting(false)`). It carries its own `.onTapGesture` for
///    play mode; as a CHILD gesture it outranks this grid's `.onTapGesture`,
///    so any touch on the face was eaten by its no-op tap.
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
    var onKeyboardMove: (String, SquaresEditDirection) -> SquaresEditMoveResult
    /// Fires `true` when a square lifts and `false` when it drops / reverts.
    /// The host uses it to disable its ScrollView mid-drag.
    var onLiftChange: (Bool) -> Void = { _ in }

    /// Windowed-Completion-aware completion read (docs/WINDOWED_COMPLETION.md
    /// §Task caches) — see the equivalent doc on the retired `RearrangeGrid`.
    var windowedIsCompleted: (Task) -> Bool = { $0.isCompleted }
    /// Windowed count for a counting square — the board's in-window progress,
    /// never the lifetime cache (owner report 2026-10-04: Board Edit showed
    /// lifetime progress). `BoardEditPanel` injects `BoardPlayView.windowedCount`.
    var windowedCount: (Task) -> CountValue = { $0.currentCount ?? 0 }

    // MARK: - Internal state

    @State private var displayCells: [SquareEditCellData] = []
    @State private var liftedId: String? = nil
    @State private var dragActive: Bool = false
    @State private var dragPosition: CGPoint = .zero
    /// When the last lift ended — a tap landing within `tapAfterLiftGrace`
    /// is the release of that hold, not a real tap.
    @State private var lastLiftEndedAt: Date = .distantPast
    /// True while a hold-drag gesture is live. Auto-resets when the gesture
    /// ends OR is cancelled — `onEnded` never runs on a cancel, so this is
    /// the only reliable cleanup signal.
    @GestureState private var isHoldGestureLive: Bool = false

    private let tapAfterLiftGrace: TimeInterval = 0.3

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
                // Interaction + accessibility BEFORE `.offset` — see the
                // layout/hit-testing invariant in the type doc.
                .contentShape(Rectangle())
                .onTapGesture { handleTap(cell.id) }
                .simultaneousGesture(
                    isMovable ? longPressDragGesture(for: cell, stride: stride) : nil
                )
                .accessibilityElement(children: .combine)
                // Slot-positional id for OYBCUITests (no VoiceOver effect).
                .accessibilityIdentifier("squaresEditCell.\(slotIdx)")
                .accessibilityActions {
                    if isMovable {
                        Button("Move up") { accessibilityMove(cell, .up) }
                        Button("Move down") { accessibilityMove(cell, .down) }
                        Button("Move left") { accessibilityMove(cell, .left) }
                        Button("Move right") { accessibilityMove(cell, .right) }
                    }
                }
                .offset(x: xOff, y: yOff)
                .animation(.spring(response: 0.22, dampingFraction: 0.82), value: slotIdx)
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
        .onChange(of: dragActive) { _, active in onLiftChange(active) }
        .onChange(of: isHoldGestureLive) { _, live in
            guard !live else { return }
            // The gesture is over. A successful release already committed
            // and cleared the lift in `onEnded`; defer one tick so that runs
            // first, then revert anything still lifted (a cancelled gesture).
            DispatchQueue.main.async { revertStrandedLift() }
        }
        .onDisappear { if dragActive { onLiftChange(false) } }
    }

    // MARK: - Tap routing

    /// Routes a tap, swallowing the trailing tap of a hold-and-release.
    /// Defensive: a SwiftUI tap can still recognize on the release of a
    /// ~0.6s press when a simultaneous long-press sits beside it (observed
    /// while diagnosing in OYBCUITests), which would open the menu for a
    /// square the user only meant to lift.
    private func handleTap(_ cellId: String) {
        guard liftedId == nil,
              Date().timeIntervalSince(lastLiftEndedAt) > tapAfterLiftGrace else { return }
        onTap(cellId)
    }

    // MARK: - Lift lifecycle

    /// Lifts `cell` (haptic + hole + ghost). Idempotent per lift. The ghost
    /// starts over the square's own slot — the hold completes before any
    /// drag location exists, so `dragPosition` would otherwise be `.zero`
    /// and the ghost would flash in the grid's top-left corner.
    private func lift(_ cell: SquareEditCellData, stride: CGFloat) {
        guard liftedId == nil else { return }
        let slot = displayCells.firstIndex(where: { $0.id == cell.id }) ?? 0
        let half = (stride - Riso.cellGap) / 2
        dragPosition = CGPoint(
            x: CGFloat(slot % gridSize) * stride + half,
            y: CGFloat(slot / gridSize) * stride + half
        )
        liftedId = cell.id
        dragActive = true
        UIImpactFeedbackGenerator(style: .medium).impactOccurred()
    }

    /// Clears the lift state (animated) and stamps the tap-grace window.
    private func clearLift() {
        lastLiftEndedAt = Date()
        withAnimation(.spring(response: 0.22, dampingFraction: 0.88)) {
            liftedId = nil
            dragActive = false
            dragPosition = .zero
        }
    }

    /// Cancel path: the gesture died without `onEnded` — drop the lift and
    /// snap the live cascade back to the committed order.
    private func revertStrandedLift() {
        guard liftedId != nil else { return }
        clearLift()
        withAnimation(.spring(response: 0.2, dampingFraction: 0.85)) {
            displayCells = cells
        }
    }

    // MARK: - VoiceOver move (D9)

    /// Runs a one-step move and speaks the result (web `aria-live` parity).
    private func accessibilityMove(_ cell: SquareEditCellData, _ direction: SquaresEditDirection) {
        let result = onKeyboardMove(cell.id, direction)
        let title = cell.pending?.task.title ?? cell.taskId.flatMap { taskMap[$0]?.title } ?? ""
        if let message = result.announcement(title: title) {
            UIAccessibility.post(notification: .announcement, argument: message)
        }
    }

    // MARK: - Cell rendering

    /// Display-only square visual — hit-testing is disabled (invariant 2 in
    /// the type doc); the grid cell's `contentShape` owns every touch.
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
        .allowsHitTesting(false)
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
            currentCount: task.map(windowedCount) ?? 0,
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
            .updating($isHoldGestureLive) { value, live, _ in
                if case .second(true, _) = value { live = true }
            }
            .onChanged { value in
                // `.first(true)` is finger-DOWN, not hold-complete — the lift
                // waits for `.second(true, _)`, which fires once the 0.35s
                // hold succeeds (then again for every drag update).
                guard case .second(true, let dragValue) = value else { return }
                if liftedId == nil { lift(cell, stride: stride) }
                guard liftedId == cell.id, let dragValue else { return }
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
            }
            .onEnded { _ in
                // Only the lifted square commits (a second finger's gesture
                // on another cell must not clear or commit this lift).
                guard liftedId == cell.id else { return }
                let finalCells = displayCells
                let changed = !zip(finalCells, cells).allSatisfy { $0.id == $1.id }
                clearLift()
                if changed { onReorder(finalCells) }
            }
    }
}
