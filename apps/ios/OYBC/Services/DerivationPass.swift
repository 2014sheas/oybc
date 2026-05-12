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
        allBoards: [Board] = []
    ) -> BoardStatsUpdate {
        let size = board.boardSize
        let totalSquares = size * size
        var grid = Array(repeating: false, count: totalSquares)
        var completedTasks = 0

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
                    let inWindow = spawns.filter {
                        $0.startDate >= board.startDate && $0.startDate <= board.endDate
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
                    taskById: taskById
                )
            } else {
                isDone = task.isCompleted
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

        let detection = BingoDetection.detectBingos(completionGrid: grid, gridSize: size)
        let previous = Set(board.completedLineIds ?? [])
        let current = Set(detection.completedLines)
        let newBingos = detection.completedLines.filter { !previous.contains($0) }
        let lostBingos = (board.completedLineIds ?? []).filter { !current.contains($0) }

        return BoardStatsUpdate(
            boardId: board.id,
            completedTasks: completedTasks,
            linesCompleted: detection.completedLines.count,
            completedLineIds: detection.completedLines,
            newBingos: newBingos,
            lostBingos: lostBingos
        )
    }
}
