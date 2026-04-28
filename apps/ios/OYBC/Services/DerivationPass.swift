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
    /// - Returns: A `BoardStatsUpdate` payload to merge into the board row.
    static func computeBoardStatsUpdate(
        board: Board,
        boardTasksOnBoard: [BoardTask],
        childrenByCompound: [String: [CompoundChild]],
        taskById: [String: Task]
    ) -> BoardStatsUpdate {
        let size = board.boardSize
        let totalSquares = size * size
        var grid = Array(repeating: false, count: totalSquares)
        var completedTasks = 0

        for bt in boardTasksOnBoard {
            // Achievement squares: completion derives from achievementProgress reaching
            // achievementCount on THIS board. The backing Task's isCompleted state is
            // irrelevant — the square's semantic is "this cross-board goal is reached",
            // tracked by achievementProgress / achievementCount on the BoardTask row.
            if bt.isAchievementSquare == true {
                let required = bt.achievementCount ?? 0
                let progress = bt.achievementProgress ?? 0
                let idx = bt.row * size + bt.col
                if idx < 0 || idx >= totalSquares { continue }
                // required > 0 guard: prevents a 0/0 achievement square from registering
                // as complete before it has been configured.
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
