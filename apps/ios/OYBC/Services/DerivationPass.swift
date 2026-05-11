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
    /// **Achievement squares**: if `bt.isAchievementSquare == true`, the cell
    /// completes when `bt.achievementProgress >= (bt.achievementCount ?? 0)`
    /// AND `achievementCount > 0` (guard against 0/0 false-positives). The
    /// backing Task's `isCompleted` is ignored for these rows — achievement
    /// squares track per-board progress toward a cross-board goal, not the
    /// task-global state.
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
    ///                Phase 6.3 specific-board / recurring-template
    ///                achievement squares — they read another board's
    ///                state directly. Defaults to `[]`; callers that lack
    ///                cross-board context can omit, and those branches
    ///                degrade to "incomplete" (matching the missing-
    ///                reference semantic). One-off and aggregate-mode
    ///                squares don't read this argument.
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
            // Achievement squares: completion derives from one of three
            // modes, dispatched by which fields are set on the BoardTask
            // row. Phase 6.3 added the two specific-mode branches;
            // aggregate mode is the pre-6.3 behavior (counter-driven via
            // achievementProgress).
            if bt.isAchievementSquare == true {
                let idx = bt.row * size + bt.col
                if idx < 0 || idx >= totalSquares { continue }

                // Precedence: `referencedBoardId` wins when both fields
                // are set. The Zod refinement rejects rows that set
                // both, but a malicious remote payload or older client
                // could still produce one — pick the more specific
                // reference deterministically so derivation is
                // predictable.
                if let refBoardId = bt.referencedBoardId {
                    // Specific-board mode: square completes when the
                    // referenced board's stored status is .completed
                    // (greenlog) AND the referenced board is non-deleted.
                    // Soft-deleted ⇒ incomplete (not crash; not silently
                    // ignore — UI can surface a "needs attention" badge
                    // separately).
                    buildBoardIndexes()
                    if let ref = boardById?[refBoardId], ref.status == .completed {
                        grid[idx] = true
                        completedTasks += 1
                    }
                    continue
                }

                if let refTemplateId = bt.referencedTemplateId {
                    // Recurring-template mode: square completes when the
                    // in-window non-deleted spawn set is non-empty AND
                    // every member is .completed. Empty window ⇒
                    // incomplete (NOT vacuously true — a future spawn
                    // must land for the square to ever satisfy). Window
                    // membership is inclusive on both ends.
                    buildBoardIndexes()
                    let spawns = boardsByTemplateId?[refTemplateId] ?? []
                    let inWindow = spawns.filter {
                        $0.startDate >= board.startDate && $0.startDate <= board.endDate
                    }
                    if !inWindow.isEmpty && inWindow.allSatisfy({ $0.status == .completed }) {
                        grid[idx] = true
                        completedTasks += 1
                    }
                    continue
                }

                // Aggregate mode (pre-6.3 behavior): completion derives
                // from achievementProgress reaching achievementCount on
                // THIS board. The backing Task's isCompleted state is
                // irrelevant — the square's semantic is "this cross-
                // board goal is reached", tracked by achievementProgress
                // / achievementCount on the BoardTask row. `required > 0`
                // guard prevents a 0/0 square from registering as
                // complete before it has been configured.
                let required = bt.achievementCount ?? 0
                let progress = bt.achievementProgress ?? 0
                if required > 0 && progress >= required {
                    grid[idx] = true
                    completedTasks += 1
                }
                continue // don't fall through to the Task.isCompleted branch
            }

            guard let task = taskById[bt.taskId], !task.isDeleted else { continue }
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
            let idx = bt.row * size + bt.col
            if idx < 0 || idx >= totalSquares { continue }
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
