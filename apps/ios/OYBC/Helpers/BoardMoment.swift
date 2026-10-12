import Foundation

// MARK: - Board moment replay kernel
//
// Swift twin of `packages/shared/src/algorithms/boardMoment.ts`, pinned by
// the shared vectors (`boardMomentVectors.json`, consumed by
// `BoardMomentVectorTests`). The Bingo / Greenlog moment replays a board:
// squares land in completion order, one per BEAT; completed lines flip green
// one beat after their last square (bingo) or a diagonal sweep turns the
// whole board green after the last square (greenlog). One clock drives a
// single `beat`; every cell's visual is DERIVED from `(idx, beat, replay,
// kind)` by `momentCellVisual`, so a re-render never restarts a pop.

/// One completed non-FREE cell in the replay's landing order.
struct MomentOrderEntry: Equatable {
    let boardTaskId: String
    let idx: Int
    /// The instant the cell's task completed within the board's window
    /// (`resolveContributionState`), or nil when it resolves none.
    let completedAt: String?
}

/// Everything the overlay needs to replay one board.
struct BoardMomentReplay: Equatable {
    /// Completed NON-FREE cells in completion order: `completedAt` ascending
    /// (parsed-instant compare), nil / unparseable instants after every dated
    /// one, ties by `idx`.
    let order: [MomentOrderEntry]
    /// The FREE centre's index when the centre is FREE and unoccupied, else nil.
    /// Never in `order`.
    let freeIdx: Int?
    /// Lines complete in the END state (ids as `detectBingos` emits them) →
    /// the beat they flip green (`max(land beat of the line's non-FREE cells) + 1`).
    let lineClosureBeat: [String: Int]
    /// The rail's numbers, verbatim: `board.completedTasks` / `board.totalTasks`.
    let completedTasks: Int
    let totalTasks: Int
    let size: Int
}

/// A cell's derived visual at one beat.
struct MomentCellVisual: Equatable {
    /// The cell has landed (drawn in its done colour).
    let landed: Bool
    /// The cell is green (its line closed, or the greenlog sweep reached it).
    let green: Bool
    /// The beat of the cell's most recent transition (landed / green) at or
    /// before `beat`; nil before any. A change in the token plays the pop.
    let popToken: Int?
}

// MARK: - computeBoardMomentReplay

/// Builds the replay for a board from the same inputs the play grid resolves.
///
/// Membership + end state come from `DerivationPass.computeBoardGrid`; on a
/// SEALED board the completion set is `board.sealedCompletedCells` and the
/// lines are `board.completedLineIds` — the replay's end state always equals
/// what the play grid shows. Each completed cell's instant is
/// `CountsToward.resolveContributionState(...).completedAt` over the board's
/// window, with events bounded at `sealedAt` on a sealed board.
func computeBoardMomentReplay(
    board: Board,
    boardTasks: [BoardTask],
    childrenByCompound: [String: [CompoundChild]],
    taskById: [String: Task],
    eventsByTaskId: [String: [TaskEvent]],
    allBoards: [Board] = []
) -> BoardMomentReplay {
    let size = board.boardSize
    let placements = PlacementIntegrity.resolvePlacements(boardTasks, boardSize: size)

    // Events bounded at the seal on a sealed board, the live union otherwise.
    var events = eventsByTaskId
    if let sealedAt = board.sealedAt, let sealed = DateFormatting.parseISO(sealedAt) {
        events = boundWindowContextAtSeal(
            eventsByTaskId: eventsByTaskId, sealedAtMs: sealed.timeIntervalSince1970 * 1000
        ).eventsByTaskId
    }

    let built = DerivationPass.computeBoardGrid(
        board: board, boardTasksOnBoard: placements, childrenByCompound: childrenByCompound,
        taskById: taskById, allBoards: allBoards, windowContext: WindowEvaluationContext(eventsByTaskId: events)
    )

    // The FREE centre: odd board, FREE centre type, nothing placed on it.
    var freeIdx: Int? = nil
    if size % 2 == 1, board.centerSquareType == .free {
        let c = (size / 2) * size + size / 2
        if !placements.contains(where: { $0.row * size + $0.col == c }) { freeIdx = c }
    }

    // End-state completion set (sealed snapshot wins over live events).
    let sealedSet: Set<Int>? = board.sealedAt != nil ? Set(board.sealedCompletedCells ?? []) : nil
    let window = CountsToward.Window(windowStart: board.startDate, windowEnd: boardWindowEnd(board))

    var entries: [MomentOrderEntry] = []
    var seenIdx = Set<Int>()
    for bt in placements.sorted(by: { ($0.row, $0.col) < ($1.row, $1.col) }) {
        let idx = bt.row * size + bt.col
        guard idx != freeIdx, !seenIdx.contains(idx) else { continue }
        let done = sealedSet.map { $0.contains(idx) } ?? built.cells.contains { $0.boardTaskId == bt.id && $0.isCompleted }
        // A completed cell whose task is missing is skipped (TS `continue`).
        guard done, let task = taskById[bt.taskId] else { continue }
        seenIdx.insert(idx)
        // The instant counts ONLY when an event completed the cell; the resolver's
        // `completedAt` / `createdAt` fallback (latched achievement, empty
        // compound) would sort those cells first, so they get nil → sort last.
        let state = CountsToward.resolveContributionState(
            task, childrenByCompound: childrenByCompound, taskById: taskById,
            eventsByTaskId: events, window: window
        )
        let instant: String? = state.isCompleted && state.completingEventId != nil ? state.completedAt : nil
        entries.append(MomentOrderEntry(boardTaskId: bt.id, idx: idx, completedAt: instant))
    }
    let order = sortMomentOrder(entries)

    // Lines complete in the end state → the beat each flips green.
    let endLines: [String]
    if board.sealedAt != nil {
        endLines = board.completedLineIds ?? []
    } else {
        endLines = BingoDetection.detectBingos(completionGrid: built.grid, gridSize: size).completedLines
    }
    var landBeat: [Int: Int] = [:]
    for (i, e) in order.enumerated() { landBeat[e.idx] = i + 1 }
    var closure: [String: Int] = [:]
    for line in endLines {
        let cells = BingoDetection.getHighlightedSquares(completedLines: [line], gridSize: size)
        closure[line] = (cells.compactMap { landBeat[$0] }.max() ?? 0) + 1
    }

    return BoardMomentReplay(
        order: order, freeIdx: freeIdx, lineClosureBeat: closure,
        completedTasks: board.completedTasks, totalTasks: board.totalTasks, size: size
    )
}

/// Completion order: dated cells by parsed instant, then undated / unparseable
/// ones, ties (and the undated tail) by `idx`.
func sortMomentOrder(_ entries: [MomentOrderEntry]) -> [MomentOrderEntry] {
    func ms(_ e: MomentOrderEntry) -> Double? {
        e.completedAt.flatMap(DateFormatting.parseISO).map { ($0.timeIntervalSince1970 * 1000).rounded() }
    }
    return entries.sorted { a, b in
        switch (ms(a), ms(b)) {
        case let (x?, y?): return x != y ? x < y : a.idx < b.idx
        case (_?, nil): return true
        case (nil, _?): return false
        case (nil, nil): return a.idx < b.idx
        }
    }
}

// MARK: - Beat helpers

/// The last beat with anything left to show: bingo — the later of the last
/// landing and the last line closure; greenlog — the last sweep band
/// (`order.count + 1 + 2·(size − 1)`).
func momentFinalBeat(_ replay: BoardMomentReplay, kind: MomentTrigger.Kind) -> Int {
    switch kind {
    case .bingo: return Swift.max(replay.order.count, replay.lineClosureBeat.values.max() ?? 0)
    case .greenlog: return replay.order.count + 1 + 2 * (replay.size - 1)
    }
}

/// The squares counter at `beat`: whatever the rail counts beyond the ordered
/// cells (e.g. FREE) is present from beat 0; it ends exactly at `completedTasks`.
func momentCounterAt(_ beat: Int, replay: BoardMomentReplay) -> Int {
    Swift.max(0, replay.completedTasks - replay.order.count + Swift.min(Swift.max(beat, 0), replay.order.count))
}

// MARK: - momentCellVisual

/// One cell's visual at `beat`, derived purely from the replay. Beat 0 is the
/// empty board; `order[i]` lands at beat `i + 1`. Bingo: a cell turns green at
/// the earliest closure beat of a line containing it (FREE included).
/// Greenlog: cell (r, c) turns green at `order.count + 1 + r + c`; lines
/// never flip during a greenlog.
func momentCellVisual(idx: Int, beat: Int, replay: BoardMomentReplay, kind: MomentTrigger.Kind) -> MomentCellVisual {
    let landAt = replay.order.firstIndex(where: { $0.idx == idx }).map { $0 + 1 }
    var greenAt: Int? = nil
    switch kind {
    case .greenlog:
        greenAt = replay.order.count + 1 + idx / replay.size + idx % replay.size
    case .bingo:
        for (line, closeAt) in replay.lineClosureBeat
        where BingoDetection.getHighlightedSquares(completedLines: [line], gridSize: replay.size).contains(idx) {
            greenAt = greenAt.map { Swift.min($0, closeAt) } ?? closeAt
        }
    }
    let landed = landAt.map { beat >= $0 } ?? false
    let green = greenAt.map { beat >= $0 } ?? false
    let token: Int? = green ? greenAt : (landed ? landAt : nil)
    return MomentCellVisual(landed: landed, green: green, popToken: token)
}
