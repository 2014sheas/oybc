import Foundation
import GRDB

// MARK: - Placement parameter writes (TASK_WINDOW_REWORK slice 3a)
//
// Writers emit PARAMETERS, not rows: a per-board goal, per-child goals, or a
// per-board title are written onto the `BoardTask` (`targetOverride` +
// `targetKind` / `childTargets` / `titleOverride`) instead of minting a derived
// task. Every write bumps `version`, enqueues one `boardTasks` UPDATE and
// re-derives the board. Reads live in `Helpers/PlacementParams.swift`.

/// One placement parameter's change: leave it, set it, or clear it.
enum PlacementParamChange<Value: Equatable>: Equatable {
    case keep
    case set(Value)
    case clear

    /// The value after applying this change to `current`.
    func resolved(_ current: Value?) -> Value? {
        switch self {
        case .keep: return current
        case .set(let v): return v
        case .clear: return nil
        }
    }
}

/// A partial update of a `BoardTask`'s four placement parameters. `.keep`
/// leaves a field alone, `.set(x)` writes it, `.clear` writes an explicit SQL
/// NULL (the `BoardTask` encoder key-skips nil, so `save()` can never clear).
struct PlacementParamsPatch: Equatable {
    var targetOverride: PlacementParamChange<CountValue> = .keep
    var targetKind: PlacementParamChange<CountKind> = .keep
    var childTargets: PlacementParamChange<[PlacementChildTarget]> = .keep
    var titleOverride: PlacementParamChange<String> = .keep

    /// True when the patch changes nothing.
    var isEmpty: Bool {
        targetOverride == .keep && targetKind == .keep && childTargets == .keep && titleOverride == .keep
    }
}

extension BoardTask {
    /// This placement with `patch` merged on, normalised through the one
    /// canonical rule (`normalizedPlacementFields`: an invalid override drops,
    /// a kind lives only beside an override, `childTargets` sorted / deduped).
    func applyingPlacementParams(_ patch: PlacementParamsPatch) -> BoardTask {
        var out = self
        let norm = BoardTask.normalizedPlacementFields(
            targetOverride: patch.targetOverride.resolved(targetOverride),
            targetKind: patch.targetKind.resolved(targetKind),
            childTargets: patch.childTargets.resolved(childTargets),
            titleOverride: patch.titleOverride.resolved(titleOverride)
        )
        out.targetOverride = norm.targetOverride
        out.targetKind = norm.targetKind
        out.childTargets = norm.childTargets
        out.titleOverride = norm.titleOverride
        return out
    }

    /// The four parameters as one comparable value.
    var placementFields: PlacementFields {
        PlacementFields(
            targetOverride: targetOverride, targetKind: targetKind,
            childTargets: childTargets, titleOverride: titleOverride
        )
    }
}

extension AppDatabase {

    /// Writes the four placement-parameter columns of `boardTask` EXPLICITLY —
    /// nil becomes SQL NULL. `BoardTask.save()` key-skips nil parameters (an
    /// absent key is what the clearable-field delete keys on), so it can set a
    /// column but never clear one; every writer that may clear goes through here.
    ///
    /// - Parameters:
    ///   - db: The open write transaction.
    ///   - boardTask: The in-memory placement whose parameters to persist.
    static func writePlacementParamColumns(db: Database, boardTask: BoardTask) throws {
        try db.execute(
            sql: "UPDATE board_tasks SET targetOverride = ?, targetKind = ?, childTargets = ?, titleOverride = ? WHERE id = ?",
            arguments: [
                boardTask.targetOverride,
                boardTask.targetKind?.rawValue,
                BoardTask.childTargetsJSON(boardTask.childTargets),
                boardTask.titleOverride,
                boardTask.id,
            ]
        )
    }

    /// Merges placement parameters onto one `BoardTask`: `version += 1`, one
    /// `boardTasks` UPDATE enqueue, then the board is re-derived (a goal
    /// override changes what counts as complete). A patch that leaves the
    /// normalised parameters unchanged writes nothing (no version bump, no
    /// enqueue). A tombstoned placement, or one on a sealed / deleted board,
    /// is left alone.
    ///
    /// Clears write an explicit SQL NULL (``writePlacementParamColumns(db:boardTask:)``).
    /// The patch struct (`.keep` / `.set` / `.clear` per field) stands in for
    /// double-optionals, which read ambiguously at call sites.
    ///
    /// - Parameters:
    ///   - db: The open write transaction.
    ///   - boardTaskId: The placement to patch.
    ///   - patch: The per-field changes.
    ///   - now: ISO8601 write stamp.
    /// - Returns: True when the placement was written.
    @discardableResult
    static func setPlacementParams(
        db: Database, boardTaskId: String, patch: PlacementParamsPatch, now: String
    ) throws -> Bool {
        guard !patch.isEmpty,
              let current = try BoardTask.fetchOne(db, key: boardTaskId), !current.isDeleted,
              let board = try Board.fetchOne(db, key: current.boardId), !board.isDeleted, board.sealedAt == nil
        else { return false }
        var next = current.applyingPlacementParams(patch)
        guard next.placementFields != current.placementFields else { return false }
        next.updatedAt = now
        next.version += 1
        try next.save(db)
        try writePlacementParamColumns(db: db, boardTask: next)
        try SyncQueueBuilder.makeItem(
            entityType: "boardTasks", entityId: next.id, operationType: .update, payload: next, now: now
        ).enqueue(db)
        try reDeriveLiveBoardTx(db: db, boardId: next.boardId, now: now)
        return true
    }

    /// Instance wrapper over ``setPlacementParams(db:boardTaskId:patch:now:)``.
    @discardableResult
    func setPlacementParams(boardTaskId: String, patch: PlacementParamsPatch) throws -> Bool {
        try write { db in
            try Self.setPlacementParams(db: db, boardTaskId: boardTaskId, patch: patch, now: Self.currentTimestamp())
        }
    }
}

extension AppDatabase {

    /// The placement parameters a freshly placed task gets by default: a
    /// counter ROOT (counting, not linked) carrying a timeframe default for
    /// `board` that differs from its own goal is placed with that default as
    /// `targetOverride` in its own kind. Every other task, and a linked row, is
    /// placed with no parameters (slice 3a: writers never mint a copy).
    ///
    /// - Parameters:
    ///   - task: The task being placed.
    ///   - board: The board receiving it.
    /// - Returns: The default parameters, or an empty patch.
    static func defaultPlacementParams(task: Task, board: Board) -> PlacementParamsPatch {
        var patch = PlacementParamsPatch()
        guard task.type == .counting, (task.sharedCounterId ?? "").isEmpty else { return patch }
        let fields = CounterSettings.Fields(task: task)
        guard CounterPlacement.placementNeedsOverride(
            fields, timeframe: board.timeframe, startDate: board.startDate, endDate: board.endDate
        ), let goal = CounterPlacement.placementGoalForCounter(
            fields, timeframe: board.timeframe, startDate: board.startDate, endDate: board.endDate
        ) else { return patch }
        patch.targetOverride = .set(goal)
        patch.targetKind = .set(resolveCountKind(task.countKind))
        return patch
    }
}
