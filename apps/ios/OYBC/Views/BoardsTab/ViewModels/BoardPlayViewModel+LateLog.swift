import Foundation

// MARK: - BoardPlayViewModel + closed-board late log (Board Edit redesign slice 4)
//
// Thin `async throws` wrappers over `AppDatabase+LateLog.swift` (D7/D9/D10),
// mirroring the shape of `+BoardActions.swift`'s Close/Reopen wrappers: off
// the main thread via a detached `_Concurrency.Task`, then `reload()`. The
// presenting UI (`LateLogSheetView`, wired from `BoardPlayView`'s closed-board
// tap routing) awaits these directly and turns a thrown error into a toast.

extension BoardPlayViewModel {

    /// The event-owning task id a late log authors against for `task`:
    ///   - NORMAL / plain-or-source COUNTING → its own id.
    ///   - LINKED counter (stamped or not) → its ROOT id (`sharedCounterId`) —
    ///     linked rows own no events (the hub-linked no-op, OQ2, is retired —
    ///     TASK_WINDOW_REWORK slice 3a).
    ///   - COMPOUND / ACHIEVEMENT → `nil` (not a single-event target; compound
    ///     has its own commit path, achievement is a no-op on a closed board).
    func lateLogEventOwningTaskId(for task: Task) -> String? {
        switch task.type {
        case .normal:
            return task.id
        case .counting:
            guard let root = task.sharedCounterId, !root.isEmpty else { return task.id }
            return root
        case .compound, .achievement:
            return nil
        }
    }

    /// Whether `taskId` (the event-owning id — pass the ROOT for a
    /// window-stamped derived square) has an undoable late log on the
    /// CURRENT (closed) board — drives the sheet's "Undo late log" swap (D15).
    ///
    /// Seal-immune candidates (a log made on the ended-but-unsealed board
    /// before Close) are permanent and don't count: the same immune windows
    /// the undo itself applies, so the sheet never offers an undo that no-ops.
    func hasClosedBoardLateLog(taskId: String) -> Bool {
        guard let b = board, b.sealedAt != nil else { return false }
        let events = windowEventsByTaskId[taskId] ?? []
        // Cheap pure check first; the immune-window read only runs when a candidate exists.
        guard !selectClosedBoardLateLogs(events: events, board: b, taskId: taskId).isEmpty else { return false }
        guard let windows = try? database.read({ db in try AppDatabase.sealImmuneWindows(db: db, taskId: taskId) }) else {
            return false
        }
        return !selectUndoableClosedBoardLateLogs(
            events: events, board: b, taskId: taskId, immuneWindows: windows
        ).isEmpty
    }

    /// Pre-check for the compound late-log sheet: would committing
    /// `childTaskIds` meet `compoundTaskId`'s rule on this closed board? The
    /// SAME pure planner the DB commit enforces
    /// (`AppDatabase.planCompoundLateLog`), over this view model's in-memory
    /// maps — so "Mark done on board" never enables for a rejected commit.
    func wouldLateLogCompoundRuleBeMet(compoundTaskId: String, childTaskIds: Set<String>) -> Bool {
        guard let b = board, b.sealedAt != nil, let compound = taskMap[compoundTaskId] else { return false }
        let now = AppDatabase.currentTimestamp()
        let placement = boardTasks.first { $0.taskId == compoundTaskId && !$0.isDeleted }
        return AppDatabase.planCompoundLateLog(
            board: b, compound: compound, requestedChildIds: childTaskIds,
            taskById: taskMap, childrenByCompound: compoundChildrenByCompound,
            eventsByTaskId: windowEventsByTaskId,
            occurredAt: lateLogOccurredAt(board: b, nowIso: now), now: now,
            childTargets: placement?.childTargets
        ).isRuleMet
    }

    /// Marks a NORMAL square done on the closed board (D7). No-op (per
    /// `AppDatabase.lateLogCompletion`) if already complete in-window.
    func commitLateLogCompletion(taskId: String) async throws {
        let bid = boardId
        try await runLateLogWrite { db in try db.lateLogCompletion(boardId: bid, taskId: taskId) }
    }

    /// Logs `delta` (> 0) on a closed board's COUNTING square — `taskId` is
    /// the PLACED square's id (the DB resolves a window-stamped derived row
    /// to its ROOT itself). Prefer `commitLateLogIncrement(for:delta:)`.
    func commitLateLogIncrement(taskId: String, delta: CountValue) async throws {
        let bid = boardId
        try await runLateLogWrite { db in try db.lateLogIncrement(boardId: bid, taskId: taskId, delta: delta) }
    }

    /// Commits the staged parts for `childTaskIds` under `compoundTaskId`
    /// (NORMAL → completion, plain COUNTING → +1) — rejected (no write)
    /// unless the operator rule is met once staged (D7).
    ///
    /// - Throws: `LateLogError.ruleNotMet` if the staged set doesn't satisfy
    ///   the compound's rule yet.
    func commitLateLogCompoundParts(compoundTaskId: String, childTaskIds: [String]) async throws {
        let bid = boardId
        try await runLateLogWrite { db in
            try db.lateLogCompoundParts(boardId: bid, compoundTaskId: compoundTaskId, childTaskIds: childTaskIds)
        }
    }

    /// Reverses the newest undoable late log on `taskId` (D10/R2).
    ///
    /// - Returns: `true` when a log was reversed; `false` when there was
    ///   nothing undoable (re-frozen by a seal, or none made) — nothing was
    ///   written, so the caller must not report success. `nil` when another
    ///   late-log write was already in flight (the call was dropped).
    func undoLateLog(taskId: String) async throws -> Bool? {
        let bid = boardId
        return try await runLateLogWrite { db in try db.undoLateLog(boardId: bid, taskId: taskId) }
    }

    /// The single choke point every late-log write above runs through: an
    /// in-flight guard (sweep finding 2) — a call made while another late-log
    /// write is still running is a silent no-op, so a rapid double-tap can
    /// never author two late logs, pop two undos, or double-increment a
    /// compound's counting children. The flag is checked + set synchronously
    /// on the main actor BEFORE the first suspension point, so two calls can't
    /// both pass it, and cleared in `defer` (success or throw). Then the write
    /// runs off the main thread and the view model reloads.
    @discardableResult
    private func runLateLogWrite<T: Sendable>(_ write: @escaping @Sendable (AppDatabase) throws -> T) async throws -> T? {
        guard !isLateLogInFlight else { return nil }
        isLateLogInFlight = true
        defer { isLateLogInFlight = false }
        let db = database
        let result = try await _Concurrency.Task.detached(priority: .userInitiated) { try write(db) }.value
        reload()
        return result
    }

    // MARK: - Task-based entry points (what the late-log sheet calls)
    //
    // The sheet hands over the TAPPED square's task; these own the id
    // mapping so it can't drift again (F1): a write goes through the DB with
    // the PLACED id — `lateLogIncrement` checks placement and resolves a
    // window-stamped derived row to its ROOT itself (web contract:
    // `LateLogSheet` → `commitIncrement(task.id, …)`) — while the event READS
    // (`hasClosedBoardLateLog`, `undoLateLog`) query the event-owning ROOT
    // directly, since derived rows own no events.

    /// Whether the tapped `task`'s square has an undoable late log on this
    /// closed board (queries the event-owning id — the root for a derived row).
    func hasClosedBoardLateLog(for task: Task) -> Bool {
        guard let id = lateLogEventOwningTaskId(for: task) else { return false }
        return hasClosedBoardLateLog(taskId: id)
    }

    /// Logs `delta` on the tapped COUNTING square. Passes the PLACED id —
    /// never the pre-resolved root, which is not placed and would throw
    /// `LateLogError.taskNotPlaced`. No-op for a non-routable square.
    func commitLateLogIncrement(for task: Task, delta: CountValue) async throws {
        guard lateLogEventOwningTaskId(for: task) != nil else { return }
        try await commitLateLogIncrement(taskId: task.id, delta: delta)
    }

    /// Reverses the newest late log for the tapped square — against the
    /// event-owning id (the ROOT for a window-stamped derived row).
    func undoLateLog(for task: Task) async throws -> Bool? {
        guard let id = lateLogEventOwningTaskId(for: task) else { return false }
        return try await undoLateLog(taskId: id)
    }
}
