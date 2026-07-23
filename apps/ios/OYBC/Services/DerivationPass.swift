import Foundation

/// DerivationPass — pure helpers for the cross-board cascade after a Task
/// state change (local or pulled).
///
/// Swift twin of @oybc/shared's derivationPass.ts. Compose these inside a
/// GRDB write-transaction on the caller side; this file performs no I/O.
enum DerivationPass {

    /// Walk `compoundChildren` upward from `changedTaskId` and return the set
    /// of compound Task ids that transitively contain it.
    ///
    /// Bounded by compound-nesting depth (typically ≤ 2 in practice).
    /// Cycle-safe: a compound id already in the result set is not re-queued.
    ///
    /// - Parameters:
    ///   - changedTaskId: The Task whose state just changed.
    ///   - children: All CompoundChild rows in the workspace (soft-deleted rows
    ///     are filtered internally).
    /// - Returns: Set of compound Task ids that transitively contain the changed task.
    static func findTransitiveParentCompounds(
        changedTaskId: String,
        children: [CompoundChild]
    ) -> Set<String> {
        var out: Set<String> = []
        var queue: [String] = [changedTaskId]
        while !queue.isEmpty {
            let id = queue.removeFirst()
            for link in children where !link.isDeleted {
                if link.childTaskId == id && !out.contains(link.compoundTaskId) {
                    out.insert(link.compoundTaskId)
                    queue.append(link.compoundTaskId)
                }
            }
        }
        return out
    }

    /// Resolve the set of board ids that need recomputing after `changedTaskId`
    /// updates. A board is affected if it places either:
    ///   - the changed task directly, OR
    ///   - any compound that transitively contains the changed task.
    ///
    /// - Parameters:
    ///   - changedTaskId: The Task whose state just changed.
    ///   - parentCompounds: Set of compound Task ids that transitively contain
    ///     the changed task (from `findTransitiveParentCompounds`).
    ///   - boardTasks: All BoardTask rows in the workspace.
    /// - Returns: Set of board ids that need their stats recomputed.
    static func findAffectedBoardIds(
        changedTaskId: String,
        parentCompounds: Set<String>,
        boardTasks: [BoardTask]
    ) -> Set<String> {
        var taskIds: Set<String> = [changedTaskId]
        for id in parentCompounds { taskIds.insert(id) }
        var out: Set<String> = []
        for bt in boardTasks {
            if taskIds.contains(bt.taskId) {
                out.insert(bt.boardId)
            }
        }
        return out
    }

    /// The shape returned by `computeBoardStatsUpdate` — a payload the caller
    /// applies to the `boards` row, plus signals it can surface to the user.
    struct BoardStatsUpdate {
        let boardId: String
        let completedTasks: Int
        let linesCompleted: Int
        let completedLineIds: [String]
        /// Bingo lines that newly appeared since the previous boards.completedLineIds.
        let newBingos: [String]
        /// Bingo lines that disappeared since the previous boards.completedLineIds.
        let lostBingos: [String]
    }

    /// For one board: rebuild the completion grid (reading post-write Task
    /// states + recursively evaluating compounds + achievement-square special
    /// case), run bingo detection, diff against prior completedLineIds.
    ///
    /// Pure — no I/O, no input mutation.
    ///
    /// The caller is responsible for setting `board.updatedAt` (current
    /// timestamp) and incrementing `board.version` before persisting the
    /// payload. Those are deliberately omitted here because this layer has
    /// no clock access and no side-effect semantics.
    ///
    /// **Achievement Tasks (Phase 6.3)**: when `task.type == .achievement`,
    /// the cell's completion is derived from the Task's reference fields
    /// (`referencedBoardId` for specific-board mode, `referencedTemplateId`
    /// for recurring-template mode). BoardTask is a pure placement record;
    /// only the Task type drives the dispatch. The backing Task's
    /// `isCompleted` is irrelevant for achievement squares — derivation
    /// reads the referenced state.
    ///
    /// **Center auto-fill**: for odd-sized boards (3 / 5) with no BoardTask at
    /// the centre AND centerSquareType == .free or .customFree, the center
    /// cell is treated as completed.
    ///
    /// - Parameters:
    ///   - board: The board whose stats need recomputing.
    ///   - boardTasksOnBoard: All BoardTask rows for this specific board.
    ///   - childrenByCompound: Map of compoundTaskId → list of CompoundChild rows.
    ///   - taskById: Map of taskId → Task (all tasks in the workspace).
    ///   - allBoards: All non-deleted boards in the workspace. Required for
    ///                Phase 6.3 ACHIEVEMENT-typed Tasks — they read
    ///                another board's (or template-spawn set's) state
    ///                directly. Defaults to `[]`; callers that lack
    ///                cross-board context can omit, and those branches
    ///                degrade to "incomplete" (matching the missing-
    ///                reference semantic).
    /// - Returns: A `BoardStatsUpdate` payload to merge into the board row.
    static func computeBoardStatsUpdate(
        board: Board,
        boardTasksOnBoard: [BoardTask],
        childrenByCompound: [String: [CompoundChild]],
        taskById: [String: Task],
        allBoards: [Board] = [],
        windowContext: WindowEvaluationContext?
    ) -> BoardStatsUpdate {
        let built = computeBoardGrid(
            board: board,
            boardTasksOnBoard: boardTasksOnBoard,
            childrenByCompound: childrenByCompound,
            taskById: taskById,
            allBoards: allBoards,
            windowContext: windowContext
        )

        let detection = BingoDetection.detectBingos(completionGrid: built.grid, gridSize: board.boardSize)
        let previous = Set(board.completedLineIds ?? [])
        let current = Set(detection.completedLines)
        let newBingos = detection.completedLines.filter { !previous.contains($0) }
        let lostBingos = (board.completedLineIds ?? []).filter { !current.contains($0) }

        return BoardStatsUpdate(
            boardId: board.id,
            completedTasks: built.completedTasks,
            linesCompleted: detection.completedLines.count,
            completedLineIds: detection.completedLines,
            newBingos: newBingos,
            lostBingos: lostBingos
        )
    }

    /// Re-derive the set of green cell indexes (`row * size + col`) for a board
    /// from the (windowed or lifetime) task state — the pure input to a sealed
    /// board's `sealedCompletedCells` snapshot (docs §Seal snapshots re-derive
    /// from the event union). Deterministic: the same converged event union
    /// yields the same cells on any device, so sealing never LWW-races.
    ///
    /// Swift twin of `computeSealedCompletedCells` in derivationPass.ts. Sealing
    /// itself (Board schema fields, the seal transaction, the pull-path
    /// re-derivation hook) lands in PR C; this builder is the shared kernel it
    /// and the migration's expired-board sealing call.
    ///
    /// - Parameters:
    ///   - board: The board to snapshot.
    ///   - boardTasksOnBoard: All BoardTask rows for this board.
    ///   - childrenByCompound: Map of compoundTaskId → CompoundChild rows.
    ///   - taskById: Map of taskId → Task.
    ///   - allBoards: Cross-board context (achievement watchers).
    ///   - windowContext: Optional windowed-event context; omitted = lifetime.
    /// - Returns: Ascending cell indexes that are green.
    static func computeSealedCompletedCells(
        board: Board,
        boardTasksOnBoard: [BoardTask],
        childrenByCompound: [String: [CompoundChild]],
        taskById: [String: Task],
        allBoards: [Board] = [],
        windowContext: WindowEvaluationContext?
    ) -> [Int] {
        let built = computeBoardGrid(
            board: board,
            boardTasksOnBoard: boardTasksOnBoard,
            childrenByCompound: childrenByCompound,
            taskById: taskById,
            allBoards: allBoards,
            windowContext: windowContext
        )
        var cells: [Int] = []
        for i in 0..<built.grid.count where built.grid[i] { cells.append(i) }
        return cells
    }

    /// Shared grid builder for `computeBoardStatsUpdate` +
    /// `computeSealedCompletedCells`.
    ///
    /// Returns the completion grid plus the `completedTasks` tally computed with
    /// the exact same increment logic both callers historically used. When
    /// `windowContext` is `nil` the resolution is byte-identical to the
    /// pre-Windowed-Completion behavior (lifetime `isCompleted` cache); when
    /// present, primitive squares resolve against the board's window via events
    /// and derived-counting squares stay on their cache (the carve-out).
    /// Mirrors the TS `computeBoardGrid`.
    private static func computeBoardGrid(
        board: Board,
        boardTasksOnBoard: [BoardTask],
        childrenByCompound: [String: [CompoundChild]],
        taskById: [String: Task],
        allBoards: [Board],
        windowContext: WindowEvaluationContext?
    ) -> (grid: [Bool], completedTasks: Int) {
        let size = board.boardSize
        let totalSquares = size * size
        var grid = Array(repeating: false, count: totalSquares)
        var completedTasks = 0

        // Window context for compound + primitive resolution. `board.startDate`
        // is the window lower bound `[startDate, ∞)`; indefinite boards use it
        // too. Nil when no windowContext (lifetime = today's behavior).
        let compoundCtx: CompoundWindowContext? = windowContext.map {
            CompoundWindowContext(windowStart: board.startDate, eventsByTaskId: $0.eventsByTaskId)
        }

        /// Resolve a primitive (normal / counting) square, windowed or lifetime.
        func resolvePrimitive(_ t: Task) -> Bool {
            guard let windowContext else { return t.isCompleted }
            // Derived-task carve-out: shared-counter-linked counting squares
            // keep their propagation-stamped lifetime cache (docs §Derived-task
            // carve-out rule 4).
            if !isEventOwningTask(t) { return t.isCompleted }
            let events = windowContext.eventsByTaskId[t.id] ?? []
            return resolveTaskWindowState(task: t, events: events, windowStart: board.startDate).isCompleted
        }

        // Phase 6.3: index all non-deleted boards by id (specific-board
        // mode) and by spawnedFromTemplateId (recurring-template mode).
        // Built lazily — only allocated if at least one boardTask uses
        // one of the new modes — so non-recurring boards pay no cost.
        var boardById: [String: Board]? = nil
        var boardsByTemplateId: [String: [Board]]? = nil
        func buildBoardIndexes() {
            guard boardById == nil else { return }
            var byId: [String: Board] = [:]
            var byTemplate: [String: [Board]] = [:]
            for b in allBoards {
                if b.isDeleted { continue }
                byId[b.id] = b
                if let tid = b.spawnedFromTemplateId {
                    byTemplate[tid, default: []].append(b)
                }
            }
            boardById = byId
            boardsByTemplateId = byTemplate
        }

        for bt in boardTasksOnBoard {
            guard let task = taskById[bt.taskId], !task.isDeleted else { continue }
            let idx = bt.row * size + bt.col
            if idx < 0 || idx >= totalSquares { continue }

            // Phase 6.3 — ACHIEVEMENT-typed Tasks are cross-board watchers.
            // The backing Task carries the reference fields (board XOR
            // template); the BoardTask is a pure placement record.
            // Dispatching on `task.type` here is the only point where
            // derivation cares about the task type vs the simple-completion
            // branch below.
            if task.type == .achievement {
                // Trigger selects what "done" means for the watched
                // target. Default .greenlog matches the pre-trigger
                // shipped behavior so older payloads decode safely.
                let trigger = task.achievementTrigger ?? .greenlog
                let meets: (Board) -> Bool = { b in
                    switch trigger {
                    case .bingo:
                        return (b.linesCompleted ?? 0) > 0
                    case .greenlog:
                        return b.status == .completed
                    }
                }

                // Precedence: `referencedBoardId` wins when both fields
                // are set. The Zod refinement rejects rows that set
                // both, but a malicious remote payload or older client
                // could still produce one — pick the more specific
                // reference deterministically so derivation is
                // predictable.
                if let refBoardId = task.referencedBoardId {
                    // Specific-board mode: cell completes when the
                    // referenced board meets the trigger AND is
                    // non-deleted. requiredCount is ignored here (the
                    // named board is either done or not).
                    buildBoardIndexes()
                    if let ref = boardById?[refBoardId], meets(ref) {
                        grid[idx] = true
                        completedTasks += 1
                    }
                    continue
                }

                if let refTemplateId = task.referencedTemplateId {
                    // Recurring-template mode: count how many in-window
                    // spawns meet the trigger, then compare against
                    // `requiredCount`. Empty in-window set => incomplete
                    // (matches the locked rule). Window membership is
                    // inclusive on both ends.
                    buildBoardIndexes()
                    let spawns = boardsByTemplateId?[refTemplateId] ?? []
                    // Use the timestamp-based helper rather than
                    // lexicographic string compare — `Board.startDate`/
                    // `endDate` may be local-ISO or UTC-with-`Z` (sync
                    // round-trips), and the two encodings don't compare
                    // correctly as strings. Mirrors the shared TS fix.
                    let inWindow = spawns.filter {
                        DateFormatting.isWithinTimeframe(
                            $0.startDate,
                            startDate: board.startDate,
                            endDate: board.endDate
                        )
                    }
                    if inWindow.isEmpty { continue }
                    let metCount = inWindow.filter(meets).count
                    let required = task.requiredCount ?? 0
                    if required > 0 && metCount >= required {
                        grid[idx] = true
                        completedTasks += 1
                    }
                    continue
                }

                // No reference set → incomplete (achievement Task lacking
                // the XOR value should have been rejected at write time;
                // degrade safely).
                continue
            }

            let isDone: Bool
            if task.type == .compound {
                isDone = CompoundEvaluation.evaluate(
                    compound: task,
                    childrenByCompound: childrenByCompound,
                    taskById: taskById,
                    windowContext: compoundCtx
                )
            } else {
                isDone = resolvePrimitive(task)
            }
            if isDone {
                grid[idx] = true
                completedTasks += 1
            }
        }

        // Center auto-fill for odd-sized boards with FREE / CUSTOM_FREE center.
        if size % 2 == 1 {
            let centerRow = size / 2
            let centerCol = size / 2
            let centerIdx = centerRow * size + centerCol
            let hasCenterTask = boardTasksOnBoard.contains { bt in
                bt.row == centerRow && bt.col == centerCol
            }
            if !hasCenterTask
                && (board.centerSquareType == .free || board.centerSquareType == .customFree)
                && !grid[centerIdx] {
                grid[centerIdx] = true
                completedTasks += 1
            }
        }

        return (grid, completedTasks)
    }
}
