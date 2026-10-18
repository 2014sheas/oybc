import Foundation
import GRDB

/// Which tasks' un-complete would be inert because every live completion is held by a
/// sealed window (docs/WINDOWED_COMPLETION.md Decision 9). One rule, three readers:
/// `AppDatabase.isUncompleteBlockedBySeal(db:taskId:)` (the per-task database read, kept
/// for the write paths), the in-memory form board play uses on the data a reload already
/// loaded, and the batched keyed form Task Detail uses. The rule: at least one live
/// completion event AND every one of them sealed-window immune over the sealed boards the
/// task's placement reach touches.
enum SealBlocked {

    /// The rule over precomputed inputs.
    ///
    /// - Parameters:
    ///   - candidateIds: The task ids to resolve.
    ///   - sealedBoards: Live, sealed boards (the immunity sources).
    ///   - eventsByTaskId: Events by task id (deleted / non-completion ones are ignored here).
    ///   - reachedBoardIds: The boards a task's placement reach touches (called only for a
    ///     candidate that has a live completion).
    /// - Returns: The candidates whose un-complete is blocked.
    static func blockedTaskIds(
        candidateIds: Set<String>, sealedBoards: [Board], eventsByTaskId: [String: [TaskEvent]],
        reachedBoardIds: (String) throws -> Set<String>
    ) rethrows -> Set<String> {
        guard !sealedBoards.isEmpty else { return [] }
        var blocked = Set<String>()
        for id in candidateIds.sorted() {
            let live = (eventsByTaskId[id] ?? []).filter { !$0.isDeleted && $0.kind == .completion }
            guard !live.isEmpty else { continue }
            let reached = try reachedBoardIds(id)
            let windows = buildSealImmuneWindows(
                sealedBoards: sealedBoards.filter { reached.contains($0.id) }.compactMap { b in
                    b.sealedAt.map { (startDate: b.startDate, endDate: b.endDate, sealedAt: $0) }
                }
            )
            guard !windows.isEmpty else { continue }
            if live.allSatisfy({ isEventSealImmune($0, windows: windows) }) { blocked.insert(id) }
        }
        return blocked
    }

    /// In memory, from data the caller already holds (board play's reload).
    ///
    /// - Parameters:
    ///   - candidateIds: The task ids to resolve.
    ///   - boards: The workspace's boards.
    ///   - tasks: Workspace tasks (any superset; deleted rows are filtered by the reach).
    ///   - compoundChildren: Compound links.
    ///   - boardTasks: Placements.
    ///   - eventsByTaskId: Events by task id.
    static func blockedTaskIds(
        candidateIds: Set<String>, boards: [Board], tasks: [Task], compoundChildren: [CompoundChild],
        boardTasks: [BoardTask], eventsByTaskId: [String: [TaskEvent]]
    ) -> Set<String> {
        blockedTaskIds(
            candidateIds: candidateIds, sealedBoards: boards.filter { !$0.isDeleted && $0.sealedAt != nil },
            eventsByTaskId: eventsByTaskId
        ) { id in
            DerivationPass.placementsReachedByTasks(
                ids: [id], tasks: tasks, compoundChildren: compoundChildren, boardTasks: boardTasks
            ).boardIds
        }
    }
}

extension AppDatabase {
    /// Batched, keyed form for callers with no loaded workspace (Task Detail): one read, the
    /// candidates' events in one query, and the placement reach read through
    /// `scopedPlacementReach` only for a candidate that has a live completion.
    ///
    /// - Parameters:
    ///   - db: An open connection.
    ///   - taskIds: The task ids to resolve.
    /// - Returns: The ids whose un-complete is blocked — the same answer
    ///   `isUncompleteBlockedBySeal` gives each one on its own.
    static func sealBlockedTaskIds(db: Database, taskIds: Set<String>) throws -> Set<String> {
        guard !taskIds.isEmpty else { return [] }
        let sealed = try Board.filter(Column("isDeleted") == false).fetchAll(db).filter { $0.sealedAt != nil }
        guard !sealed.isEmpty else { return [] }
        var events: [TaskEvent] = []
        let ids = taskIds.sorted()
        for start in stride(from: 0, to: ids.count, by: 400) {
            let chunk = Array(ids[start..<min(start + 400, ids.count)])
            events += try TaskEvent.filter(chunk.contains(Column("taskId")) && Column("isDeleted") == false).fetchAll(db)
        }
        return try SealBlocked.blockedTaskIds(
            candidateIds: taskIds, sealedBoards: sealed, eventsByTaskId: Dictionary(grouping: events, by: \.taskId)
        ) { id in try scopedPlacementReach(db: db, taskIds: [id]).reach.boardIds }
    }

    /// `sealBlockedTaskIds(db:taskIds:)` in its own read.
    func sealBlockedTaskIds(taskIds: Set<String>) throws -> Set<String> {
        try read { db in try Self.sealBlockedTaskIds(db: db, taskIds: taskIds) }
    }
}
