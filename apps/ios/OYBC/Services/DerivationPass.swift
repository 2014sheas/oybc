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
    /// the board's window via events, window-stamped derived counters resolve
    /// from their root's events inside their own window, and every other
    /// linked counting square resolves from its root's events inside THIS
    /// board's window (owner rule 2026-10-01 — the hub-linked latch carve-out
    /// is retired on boards). Mirrors the TS `computeBoardGrid`.
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

        // Window context for compound + primitive resolution. The board's own
        // window `[startDate, endDate]` (inclusive; indefinite boards have no
        // upper bound) — 2026-09-24 amendment. A sealed snapshot's context is
        // already pre-bounded at `sealedAt` by the caller
        // (`boundWindowContextAtSeal`), so its effective upper bound is
        // `min(endDate, sealedAt)`. Nil when no windowContext (lifetime).
        let windowEnd = boardWindowEnd(board)
        let compoundCtx: CompoundWindowContext? = windowContext.map {
            CompoundWindowContext(
                windowStart: board.startDate,
                windowEnd: windowEnd,
                eventsByTaskId: $0.eventsByTaskId
            )
        }

        /// Resolve a primitive (normal / counting) square, windowed or lifetime.
        func resolvePrimitive(_ t: Task) -> Bool {
            guard let windowContext else { return t.isCompleted }
            // Linked (derived) counter: resolved from its ROOT's increment
            // events — never the one-way latch, which a later window's
            // increments can set (docs §Derived-task carve-out rule 4, amended
            // 2026-09-23 / 2026-10-01). A window-stamped row reads its own
            // `[startDate, endDate]`; any other linked row reads THIS board's
            // window, the owner rule that retired the hub-linked latch
            // carve-out on boards. The sealed path's context is already
            // bounded at `sealedAt`. Mirrors the TS `resolvePrimitive`.
            if let derived = resolveDerivedCounterWindowState(
                task: t, eventsByTaskId: windowContext.eventsByTaskId,
                windowStart: board.startDate, windowEnd: windowEnd
            ) {
                return derived.isCompleted
            }
            // Compound / achievement rows never reach here (branched above);
            // this is the defensive non-event-owning fallthrough.
            if !isEventOwningTask(t) { return t.isCompleted }
            let events = windowContext.eventsByTaskId[t.id] ?? []
            return resolveTaskWindowState(
                task: t, events: events, windowStart: board.startDate, windowEnd: windowEnd
            ).isCompleted
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
                    windowContext: compoundCtx,
                    childTargets: bt.childTargets
                )
            } else {
                // The placement-adjusted task (slice 2a): its goal is the placement's.
                isDone = resolvePrimitive(PlacementParams.apply(task, placement: bt))
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

/// One live placement a changed task reaches: the placement row, the MEMBER
/// (the changed task or a linked row of it) read on that square, and the
/// compound the member is reached through (`nil` for a direct placement).
/// Twin of the TS `ReachedPlacement`.
struct ReachedPlacement {
    let boardTask: BoardTask
    let memberTaskId: String
    let viaCompoundId: String?
}

/// What a set of changed tasks reaches (TASK_WINDOW_REWORK slice 2c). Twin of
/// the TS `PlacementReach`.
struct PlacementReach {
    /// `ids` plus every live linked row of each id — the cascade input.
    /// Parent compounds are NOT included: the cascade walks them itself.
    var taskIds: Set<String>
    /// Every live compound that transitively contains a member.
    var compoundIds: Set<String>
    /// Every board placing a member directly or through a reached compound.
    var boardIds: Set<String>
    /// One entry per (placement, member) pair, in placement order.
    var placements: [ReachedPlacement]
}

extension DerivationPass {
    /// The ONE reach for a changed task set (slice 2c): the live cascade, the
    /// sealed re-derivation, seal-immune windows, late-log / pull paths and the
    /// Counters hub all walk placements from here.
    ///
    /// Members = each id itself (a non-root passes through, live or not) plus
    /// every LIVE task whose `sharedCounterId` is one of the ids. A member's
    /// transitive parents are reached through LIVE links to LIVE `.compound`
    /// tasks only. A placement is reached when it is live and places a member
    /// directly, or places a reached compound (one entry per member reached
    /// through it, direct children first). Mirrors the TS
    /// `placementsReachedByTasks`.
    ///
    /// - Parameters:
    ///   - ids: The task ids whose events (or derived state) changed.
    ///   - tasks: Workspace tasks (any superset; deleted rows filtered here).
    ///   - compoundChildren: Compound links (deleted filtered here).
    ///   - boardTasks: Placements (deleted filtered here).
    /// - Returns: The reach; empty when `ids` is empty.
    static func placementsReachedByTasks(
        ids: Set<String>, tasks: [Task], compoundChildren: [CompoundChild], boardTasks: [BoardTask]
    ) -> PlacementReach {
        var reach = PlacementReach(taskIds: ids, compoundIds: [], boardIds: [], placements: [])
        guard !ids.isEmpty else { return reach }

        var liveById: [String: Task] = [:]
        for t in tasks where !t.isDeleted {
            liveById[t.id] = t
            if let root = t.sharedCounterId, !root.isEmpty, ids.contains(root) { reach.taskIds.insert(t.id) }
        }
        var parentsByChild: [String: [String]] = [:]
        for c in compoundChildren where !c.isDeleted {
            parentsByChild[c.childTaskId, default: []].append(c.compoundTaskId)
        }
        // compound id -> members reached through it (direct children first).
        var membersViaCompound: [String: [String]] = [:]
        for memberId in reach.taskIds {
            var seen = Set<String>()
            var queue = parentsByChild[memberId] ?? []
            var head = 0
            while head < queue.count {
                let parentId = queue[head]; head += 1
                if !seen.insert(parentId).inserted { continue }
                guard let parent = liveById[parentId], parent.type == .compound else { continue }
                reach.compoundIds.insert(parentId)
                membersViaCompound[parentId, default: []].append(memberId)
                queue.append(contentsOf: parentsByChild[parentId] ?? [])
            }
        }
        for bt in boardTasks where !bt.isDeleted {
            if reach.taskIds.contains(bt.taskId) {
                reach.boardIds.insert(bt.boardId)
                reach.placements.append(ReachedPlacement(boardTask: bt, memberTaskId: bt.taskId, viaCompoundId: nil))
                continue
            }
            guard let via = membersViaCompound[bt.taskId] else { continue }
            reach.boardIds.insert(bt.boardId)
            for memberId in via {
                reach.placements.append(ReachedPlacement(boardTask: bt, memberTaskId: memberId, viaCompoundId: bt.taskId))
            }
        }
        return reach
    }

    /// `placementsReachedByTasks` for one shared-counter root (or any single
    /// task): the Counters hub's card source.
    static func placementsReachedByRoot(
        rootId: String, tasks: [Task], compoundChildren: [CompoundChild], boardTasks: [BoardTask]
    ) -> PlacementReach {
        placementsReachedByTasks(ids: [rootId], tasks: tasks, compoundChildren: compoundChildren, boardTasks: boardTasks)
    }
}
