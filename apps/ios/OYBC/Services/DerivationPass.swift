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
    /// the centre AND centerSquareType == .free, the center
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

    // MARK: - Board-integrity PR-3: per-cell resolution (the unified kernel)

    /// Board-integrity PR-3 (issue #360) — per-cell achievement-badge inputs
    /// attached to a `CellState` when the cell's Task is ACHIEVEMENT-typed
    /// and carries a reference (`referencedBoardId` XOR `referencedTemplateId`).
    ///
    /// Deliberately carries only the RAW ids/counts the kernel already
    /// computed while resolving `isCompleted` — NOT display names. Both
    /// platforms' render layers already maintain their own board/template
    /// lookup maps (for other reasons); adding a `RecurringBoardTemplate`
    /// list just to resolve a label string here would widen this beyond a
    /// cosmetic lookup the caller can do in one line from data it already
    /// has. See `BoardPlayView.achievementBadge(for:)` for the thin
    /// name-resolution step built on top of these ids. Mirrors the TS
    /// `AchievementCellBadge`.
    struct AchievementCellBadge: Equatable {
        enum Mode: String, Equatable {
            case specificBoard
            case recurringTemplate
        }

        let mode: Mode
        /// Specific-board mode only.
        let referencedBoardId: String?
        /// Specific-board mode only — whether the referenced board (if it
        /// still exists and isn't soft-deleted) currently meets the Task's
        /// trigger.
        let referencedBoardCompleted: Bool?
        /// Recurring-template mode only.
        let referencedTemplateId: String?
        /// Recurring-template mode only — count of in-window spawns meeting
        /// the trigger (0 when the in-window spawn set is empty).
        let templateInWindowMet: Int?
        /// Recurring-template mode only — the Task's `requiredCount` (0 if unset).
        let templateRequiredCount: Int?
    }

    /// Board-integrity PR-3 (issue #360) — one per-cell resolution result
    /// from `computeBoardGrid`, one entry per surviving `BoardTask`
    /// placement (i.e. NOT the odd-board FREE center auto-fill,
    /// which is not a placement and has no BoardTask/Task id to key on).
    ///
    /// This is the single per-cell "is this done, and if it's an
    /// achievement square what is it watching" resolution both platforms'
    /// render surfaces (play grid, board-preview mini-grid, achievement
    /// badge) now read instead of hand-mirroring the branch order
    /// themselves. Mirrors the TS `CellState`.
    struct CellState: Equatable {
        let boardTaskId: String
        let taskId: String
        let row: Int
        let col: Int
        /// Flat index (`row * boardSize + col`) — matches `grid`'s indexing
        /// and `Board.sealedCompletedCells`'s encoding.
        let idx: Int
        /// Exactly the boolean this placement contributed to `grid[idx]` —
        /// for a cell a later duplicate placement lost to (the `grid[idx]`
        /// dup-guard), no CellState is emitted at all.
        let isCompleted: Bool
        /// Present only when the Task is ACHIEVEMENT-typed and carries a
        /// reference. Absent for every other cell, and for a reference-less
        /// ACHIEVEMENT Task (degrades to incomplete, no badge — write-time
        /// validation should already reject that shape).
        let achievement: AchievementCellBadge?

        init(
            boardTaskId: String,
            taskId: String,
            row: Int,
            col: Int,
            idx: Int,
            isCompleted: Bool,
            achievement: AchievementCellBadge? = nil
        ) {
            self.boardTaskId = boardTaskId
            self.taskId = taskId
            self.row = row
            self.col = col
            self.idx = idx
            self.isCompleted = isCompleted
            self.achievement = achievement
        }
    }

    /// Shared grid builder for `computeBoardStatsUpdate` +
    /// `computeSealedCompletedCells` — and, as of Board-integrity PR-3
    /// (issue #360), the ONE per-cell resolver both platforms' render
    /// surfaces (play grid, board-preview mini-grid, achievement badge)
    /// call into directly instead of hand-mirroring this branch order
    /// themselves. Not `private`: `BoardPlayView` / `BoardPreviewCells` call
    /// it directly so the ACHIEVEMENT branch has exactly one implementation.
    ///
    /// Returns the completion grid plus the `completedTasks` tally computed
    /// with the exact same increment logic both callers historically used,
    /// PLUS `cells` — a `CellState` per surviving BoardTask placement (see
    /// that type's docs). `grid`/`completedTasks` are computed by the EXACT
    /// same code path as before PR-3 (only additionally recorded into a
    /// `cells` entry) — this widening is additive and byte-identical for
    /// those two fields. When `windowContext` is `nil` the resolution is
    /// byte-identical to the pre-Windowed-Completion behavior (lifetime
    /// `isCompleted` cache); when present, primitive squares resolve against
    /// the board's window via events and derived-counting squares stay on
    /// their cache (the carve-out). Mirrors the TS `computeBoardGrid`.
    static func computeBoardGrid(
        board: Board,
        boardTasksOnBoard: [BoardTask],
        childrenByCompound: [String: [CompoundChild]],
        taskById: [String: Task],
        allBoards: [Board],
        windowContext: WindowEvaluationContext?
    ) -> (grid: [Bool], completedTasks: Int, cells: [CellState]) {
        let size = board.boardSize
        let totalSquares = size * size
        var grid = Array(repeating: false, count: totalSquares)
        var completedTasks = 0
        var cells: [CellState] = []
        cells.reserveCapacity(boardTasksOnBoard.count)

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

            // Bounds guard: `BoardTaskSchema` only enforces `min(0)` on row/col,
            // so a malformed placement (e.g. `row=0, col=7` on a 5×5) would
            // otherwise alias into a WRONG cell via `row * size + col`. Skip
            // out-of-range placements entirely; the flat-index guard below stays
            // as defense-in-depth. Mirrors the TS `computeBoardGrid`.
            if bt.row >= size || bt.col >= size { continue }

            let idx = bt.row * size + bt.col
            if idx < 0 || idx >= totalSquares { continue }

            // Duplicate-placement guard: `completedTasks` counts per CELL, not
            // per placement row. Two placements on one cell (possible via
            // offline sync union — there is no (board,row,col) uniqueness
            // constraint) must not double-count toward the greenlog predicate
            // (`completedTasks >= size²`). Skipping an already-true cell is
            // also order-independent: the cell is green iff ANY of its
            // placements resolves complete, counted once. Mirrors the TS
            // `computeBoardGrid`.
            if grid[idx] { continue }

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
                    let ref = boardById?[refBoardId]
                    let refCompleted = ref.map(meets) ?? false
                    if refCompleted {
                        grid[idx] = true
                        completedTasks += 1
                    }
                    cells.append(CellState(
                        boardTaskId: bt.id,
                        taskId: task.id,
                        row: bt.row,
                        col: bt.col,
                        idx: idx,
                        isCompleted: refCompleted,
                        achievement: AchievementCellBadge(
                            mode: .specificBoard,
                            referencedBoardId: refBoardId,
                            referencedBoardCompleted: refCompleted,
                            referencedTemplateId: nil,
                            templateInWindowMet: nil,
                            templateRequiredCount: nil
                        )
                    ))
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
                    // `metCount` is computed regardless of whether inWindow
                    // is empty (naturally 0 in that case) so the badge
                    // always carries an honest "M/N" pair.
                    let metCount = inWindow.filter(meets).count
                    let required = task.requiredCount ?? 0
                    let templateDone = !inWindow.isEmpty && required > 0 && metCount >= required
                    if templateDone {
                        grid[idx] = true
                        completedTasks += 1
                    }
                    cells.append(CellState(
                        boardTaskId: bt.id,
                        taskId: task.id,
                        row: bt.row,
                        col: bt.col,
                        idx: idx,
                        isCompleted: templateDone,
                        achievement: AchievementCellBadge(
                            mode: .recurringTemplate,
                            referencedBoardId: nil,
                            referencedBoardCompleted: nil,
                            referencedTemplateId: refTemplateId,
                            templateInWindowMet: metCount,
                            templateRequiredCount: required
                        )
                    ))
                    continue
                }

                // No reference set → incomplete (achievement Task lacking
                // the XOR value should have been rejected at write time;
                // degrade safely). No badge data either — matches the
                // "cell renders as regular task" fallback render surfaces
                // already relied on.
                cells.append(CellState(
                    boardTaskId: bt.id,
                    taskId: task.id,
                    row: bt.row,
                    col: bt.col,
                    idx: idx,
                    isCompleted: false
                ))
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
            cells.append(CellState(
                boardTaskId: bt.id,
                taskId: task.id,
                row: bt.row,
                col: bt.col,
                idx: idx,
                isCompleted: isDone,
                achievement: nil
            ))
            if isDone {
                grid[idx] = true
                completedTasks += 1
            }
        }

        // Center auto-fill for odd-sized boards with a FREE center.
        if size % 2 == 1 {
            let centerRow = size / 2
            let centerCol = size / 2
            let centerIdx = centerRow * size + centerCol
            let hasCenterTask = boardTasksOnBoard.contains { bt in
                bt.row == centerRow && bt.col == centerCol
            }
            if !hasCenterTask
                && board.centerSquareType == .free
                && !grid[centerIdx] {
                grid[centerIdx] = true
                completedTasks += 1
                // No CellState emitted — the FREE center auto-fill is not a
                // BoardTask placement (no boardTaskId/taskId to key on).
                // Mirrors the TS `computeBoardGrid`, which also does not
                // push into `cells` here.
            }
        }

        return (grid, completedTasks, cells)
    }
}
