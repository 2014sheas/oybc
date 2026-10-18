import Foundation

/// Task Detail's Boards rows — the pure half of placement resolution
/// (docs/TASK_DETAIL_REDESIGN.md PR 5). Twin of the TS `taskPlacementRows`
/// (`packages/shared/src/algorithms/taskPlacementRows.ts`), pinned by
/// `Fixtures/taskPlacementRowsVectors.json`.
///
/// A task's boards are its placement REACH (`DerivationPass.placementsReachedByTasks`,
/// the one reach the cascade and the hub use): its own placements, those of its
/// live linked rows (a counter root), and those of every compound that contains
/// it. Each board's value is read through the same resolvers the board grid
/// uses, over that board's window (bounded at `sealedAt` on a closed board).
enum TaskPlacementRows {
    /// One board's row: what the task (or the member reached through it) shows there.
    struct Row: Equatable {
        let boardId: String
        /// The placement the row reads (the task's own, a linked row's, or a parent compound's).
        let boardTaskId: String
        /// The task whose state the row shows.
        let memberTaskId: String
        /// The compound placement this member is reached through, or `nil` for a direct one.
        let viaCompoundId: String?
        let done: Bool
        /// Counting member: the windowed count and the goal it is scored against.
        let count: CountValue?
        let goal: CountValue?
        /// Compound member: its direct sub-tasks done in this window / in total.
        let childrenDone: Int?
        let childrenTotal: Int?
    }

    /// Whether `childId` is a live direct child of `compoundId`.
    static func isDirectChild(_ childId: String, of compoundId: String, childrenByCompound: [String: [CompoundChild]]) -> Bool {
        (childrenByCompound[compoundId] ?? []).contains { !$0.isDeleted && $0.childTaskId == childId }
    }

    /// The reached placement a board's row reads: the task's own direct placement
    /// first, then any other direct one (a linked row), then one reached through a
    /// compound it is a DIRECT child of (so that placement's child target
    /// applies), then a deeper one; ties break on member id, then placement id —
    /// independent of the reach's iteration order.
    static func pickPerBoard(
        taskId: String, reach: [ReachedPlacement], childrenByCompound: [String: [CompoundChild]]
    ) -> [String: ReachedPlacement] {
        func rank(_ p: ReachedPlacement) -> Int {
            guard let via = p.viaCompoundId else { return p.memberTaskId == taskId ? 0 : 1 }
            return isDirectChild(p.memberTaskId, of: via, childrenByCompound: childrenByCompound) ? 2 : 3
        }
        func before(_ a: ReachedPlacement, _ b: ReachedPlacement) -> Bool {
            if rank(a) != rank(b) { return rank(a) < rank(b) }
            if a.memberTaskId != b.memberTaskId { return a.memberTaskId < b.memberTaskId }
            return a.boardTask.id < b.boardTask.id
        }
        var best: [String: ReachedPlacement] = [:]
        for p in reach {
            if let prev = best[p.boardTask.boardId], !before(p, prev) { continue }
            best[p.boardTask.boardId] = p
        }
        return best
    }

    /// One row per board the task reaches, ordered by board id (callers sort for display).
    ///
    /// - Parameters:
    ///   - taskId: The task whose detail page this is.
    ///   - reach: `placementsReachedByTasks(ids: [taskId], …).placements`.
    ///   - boardsById: Every board the reach names (deleted ones are skipped).
    ///   - taskById: Workspace tasks (members, compounds and their sub-tasks, counter roots).
    ///   - childrenByCompound: Live compound links by compound id (nested compounds included).
    ///   - eventsByTaskId: Live events by task id.
    ///   - boardTasksByBoard: Live placements by board id (only an achievement row reads them).
    ///   - allBoards: Every board (an achievement resolves against the board it watches).
    /// - Returns: The rows; missing / deleted boards and missing members are skipped.
    static func rows(
        taskId: String,
        reach: [ReachedPlacement],
        boardsById: [String: Board],
        taskById: [String: Task],
        childrenByCompound: [String: [CompoundChild]],
        eventsByTaskId: [String: [TaskEvent]],
        boardTasksByBoard: [String: [BoardTask]],
        allBoards: [Board]
    ) -> [Row] {
        let picked = pickPerBoard(taskId: taskId, reach: reach, childrenByCompound: childrenByCompound)
        var out: [Row] = []
        for boardId in picked.keys.sorted() {
            guard let reached = picked[boardId], let board = boardsById[boardId], !board.isDeleted,
                  let member = taskById[reached.memberTaskId] else { continue }
            let bt = reached.boardTask

            var events = eventsByTaskId
            if let sealed = board.sealedAt, let sealedDate = DateFormatting.parseISO(sealed) {
                events = boundWindowContextAtSeal(
                    eventsByTaskId: eventsByTaskId, sealedAtMs: sealedDate.timeIntervalSince1970 * 1000
                ).eventsByTaskId
            }
            let ctx = CompoundWindowContext(windowStart: board.startDate, windowEnd: boardWindowEnd(board), eventsByTaskId: events)

            // Direct: the placement's own parameters. Via a compound: the parent
            // placement's child target applies only to its DIRECT children.
            let direct = reached.viaCompoundId == nil
            let isDirectChild = !direct
                && Self.isDirectChild(member.id, of: reached.viaCompoundId ?? "", childrenByCompound: childrenByCompound)
            let subject = direct
                ? PlacementParams.apply(member, placement: bt)
                : PlacementParams.withChildTarget(member, childTargets: isDirectChild ? bt.childTargets : nil)

            var done: Bool
            var count: CountValue?
            var goal: CountValue?
            var childrenDone: Int?
            var childrenTotal: Int?

            switch subject.type {
            case .compound:
                let ownTargets = direct ? bt.childTargets : nil
                done = CompoundEvaluation.evaluate(
                    compound: subject, childrenByCompound: childrenByCompound, taskById: taskById,
                    windowContext: ctx, childTargets: ownTargets
                )
                // Every live link counts — a link to a missing / deleted task is a
                // sub-task not done, exactly as `CompoundEvaluation.evaluate` scores it.
                let links = (childrenByCompound[subject.id] ?? []).filter { !$0.isDeleted }
                childrenTotal = links.count
                childrenDone = links.filter { link in
                    guard let t = taskById[link.childTaskId], !t.isDeleted else { return false }
                    let k = PlacementParams.withChildTarget(t, childTargets: ownTargets)
                    return k.type == .compound
                        ? CompoundEvaluation.evaluate(compound: k, childrenByCompound: childrenByCompound, taskById: taskById, windowContext: ctx)
                        : PlacementParams.resolveSquareState(k, placement: nil, ctx: ctx).isCompleted
                }.count
            case .achievement:
                // An achievement's state is its cell in the board's own grid.
                let onBoard = PlacementIntegrity.resolvePlacements(boardTasksByBoard[boardId] ?? [], boardSize: board.boardSize)
                let grid = DerivationPass.computeBoardGrid(
                    board: board, boardTasksOnBoard: onBoard, childrenByCompound: childrenByCompound,
                    taskById: taskById, allBoards: allBoards, windowContext: WindowEvaluationContext(eventsByTaskId: events)
                )
                done = grid.cells.first { $0.boardTaskId == bt.id }?.isCompleted ?? false
            case .normal, .counting:
                let state = PlacementParams.resolveSquareState(subject, placement: nil, ctx: ctx)
                done = state.isCompleted
                if subject.type == .counting {
                    count = state.count
                    goal = subject.maxCount
                }
            }

            // A closed board's own cell is its frozen record.
            if direct, board.sealedAt != nil {
                done = (board.sealedCompletedCells ?? []).contains(bt.row * board.boardSize + bt.col)
            }

            out.append(Row(
                boardId: boardId, boardTaskId: bt.id, memberTaskId: member.id, viaCompoundId: reached.viaCompoundId,
                done: done, count: count, goal: goal, childrenDone: childrenDone, childrenTotal: childrenTotal
            ))
        }
        return out
    }
}
