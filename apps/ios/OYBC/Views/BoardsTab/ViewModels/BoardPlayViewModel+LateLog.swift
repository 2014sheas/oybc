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
    ///   - Window-stamped derived counter → its ROOT id (`sharedCounterId`) —
    ///     derived rows own no events (carve-out).
    ///   - Hub-linked derived counter / COMPOUND / ACHIEVEMENT → `nil` (not a
    ///     single-event target; compound has its own commit path, the other
    ///     two are no-ops on a closed board — OQ2).
    func lateLogEventOwningTaskId(for task: Task) -> String? {
        switch task.type {
        case .normal:
            return task.id
        case .counting:
            guard let root = task.sharedCounterId else { return task.id }
            return BoardSources.isWindowStampedDerived(task) ? root : nil
        case .compound, .achievement:
            return nil
        }
    }

    /// Whether `taskId` (the event-owning id — pass the ROOT for a
    /// window-stamped derived square) has an undoable late log on the
    /// CURRENT (closed) board — drives the sheet's "Undo late log" swap (D15).
    func hasClosedBoardLateLog(taskId: String) -> Bool {
        guard let b = board, b.sealedAt != nil else { return false }
        let events = windowEventsByTaskId[taskId] ?? []
        return !selectClosedBoardLateLogs(events: events, board: b, taskId: taskId).isEmpty
    }

    /// Marks a NORMAL square done on the closed board (D7). No-op (per
    /// `AppDatabase.lateLogCompletion`) if already complete in-window.
    func commitLateLogCompletion(taskId: String) async throws {
        let bid = boardId
        let db = database
        try await _Concurrency.Task.detached(priority: .userInitiated) {
            try db.lateLogCompletion(boardId: bid, taskId: taskId)
        }.value
        reload()
    }

    /// Logs `delta` (> 0) on a closed board's COUNTING square — `taskId` is
    /// the event-owning id from `lateLogEventOwningTaskId(for:)` (the ROOT
    /// for a window-stamped derived square).
    func commitLateLogIncrement(taskId: String, delta: Int) async throws {
        let bid = boardId
        let db = database
        try await _Concurrency.Task.detached(priority: .userInitiated) {
            try db.lateLogIncrement(boardId: bid, taskId: taskId, delta: delta)
        }.value
        reload()
    }

    /// Stages then commits completions for `childTaskIds` under
    /// `compoundTaskId` — rejected (no write) unless the operator rule is
    /// met once staged (D7).
    ///
    /// - Throws: `LateLogError.ruleNotMet` if the staged set doesn't satisfy
    ///   the compound's rule yet.
    func commitLateLogCompoundParts(compoundTaskId: String, childTaskIds: [String]) async throws {
        let bid = boardId
        let db = database
        try await _Concurrency.Task.detached(priority: .userInitiated) {
            try db.lateLogCompoundParts(boardId: bid, compoundTaskId: compoundTaskId, childTaskIds: childTaskIds)
        }.value
        reload()
    }

    /// Reverses the newest late log on `taskId` (D10/R2). Silent no-op if
    /// there's nothing undoable (already re-frozen by a later seal, or none
    /// was ever made).
    func undoLateLog(taskId: String) async throws {
        let bid = boardId
        let db = database
        try await _Concurrency.Task.detached(priority: .userInitiated) {
            try db.undoLateLog(boardId: bid, taskId: taskId)
        }.value
        reload()
    }
}
