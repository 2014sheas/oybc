import Foundation
import GRDB

// MARK: - "Counts toward" — Counter Detail section (read half)
//
// docs/SHARED_COUNTER_SETTINGS.md §3d, PR 4. Web twin: `useCountsTowardSection`
// (`hooks/`) over the same `countsTowardRows` kernel. The pure ordering / status
// / credit-count rules live in `Helpers/CountsTowardCredits.swift`; this file
// only gathers their inputs.

/// What the Counter Detail "Counts toward" section renders.
struct CountsTowardSectionData {
    /// The counter's display name (`CounterSettings.counterDisplayName`).
    let counterName: String
    /// One row per fork lineage, in the handoff order.
    let rows: [CountsToward.ContributorRow]
    /// The rows' representative tasks (title / type), by id.
    let taskById: [String: Task]
    /// The rows' primary boards, by id.
    let boardById: [String: Board]

    static let empty = CountsTowardSectionData(counterName: "", rows: [], taskById: [:], boardById: [:])
}

extension CountsTowardSectionData: Equatable {
    static func == (lhs: CountsTowardSectionData, rhs: CountsTowardSectionData) -> Bool {
        lhs.counterName == rhs.counterName && lhs.rows == rhs.rows
            && lhs.taskById.mapValues(\.version) == rhs.taskById.mapValues(\.version)
            && lhs.boardById.mapValues(\.version) == rhs.boardById.mapValues(\.version)
    }
}

extension AppDatabase {

    /// The Counter Detail "Counts toward" section for `counterId`, or nil when
    /// the counter is missing / deleted / not Discrete (the section is hidden
    /// for Continuous and Duration counters — only a Discrete counter can be a
    /// counts-toward target).
    ///
    /// - Parameter counterId: The counter's root task id.
    /// - Returns: The section data (possibly with no rows), or nil to hide it.
    /// - Throws: A database read error.
    func fetchCountsTowardSection(counterId: String) throws -> CountsTowardSectionData? {
        try read { db in try Self.fetchCountsTowardSection(db: db, counterId: counterId) }
    }

    /// `db`-scoped twin of `fetchCountsTowardSection(counterId:)`.
    static func fetchCountsTowardSection(db: Database, counterId: String) throws -> CountsTowardSectionData? {
        guard let root = try Task.fetchOne(db, key: counterId), CountsToward.isTarget(root) else { return nil }
        let tasks = try Task.fetchAll(db)
        var taskById: [String: Task] = [:]
        for t in tasks { taskById[t.id] = t }
        let contributors = tasks.filter {
            !$0.isDeleted && $0.countsTowardCounterId == counterId && CountsToward.canContribute($0)
        }
        let name = CounterSettings.counterDisplayName(root)
        guard !contributors.isEmpty else {
            return CountsTowardSectionData(counterName: name, rows: [], taskById: [:], boardById: [:])
        }

        // Scope the event / placement reads: contributors, their fork lineages,
        // their compound subtrees (links in any state), the roots their linked
        // children read, and the counter root (the credits).
        var allChildrenByCompound: [String: [CompoundChild]] = [:]
        var childrenByCompound: [String: [CompoundChild]] = [:]
        for c in try CompoundChild.fetchAll(db) {
            allChildrenByCompound[c.compoundTaskId, default: []].append(c)
            if !c.isDeleted { childrenByCompound[c.compoundTaskId, default: []].append(c) }
        }
        let forkChildren = CountsToward.buildForkChildrenIndex(tasks)
        var ids: Set<String> = [counterId]
        var frontier: [String] = []
        for c in contributors {
            frontier.append(c.id)
            frontier.append(contentsOf: CountsToward.forkLineageIds(c.id, taskById: taskById, forkChildren: forkChildren))
        }
        while let id = frontier.popLast() {
            guard ids.insert(id).inserted else { continue }
            if let rootId = taskById[id]?.sharedCounterId, !ids.contains(rootId) { frontier.append(rootId) }
            for link in allChildrenByCompound[id] ?? [] where !ids.contains(link.childTaskId) { frontier.append(link.childTaskId) }
        }
        var eventsByTaskId: [String: [TaskEvent]] = [:]
        var allEventsByTaskId: [String: [TaskEvent]] = [:]
        for e in try TaskEvent.filter(ids.contains(Column("taskId"))).fetchAll(db) {
            allEventsByTaskId[e.taskId, default: []].append(e)
            if !e.isDeleted { eventsByTaskId[e.taskId, default: []].append(e) }
        }
        let placements = try BoardTask.filter(ids.contains(Column("taskId"))).fetchAll(db)
        var boardById: [String: Board] = [:]
        for b in try Board.fetchAll(db, keys: Set(placements.map(\.boardId))) { boardById[b.id] = b }

        let inputs = CountsToward.Inputs(
            taskById: taskById, childrenByCompound: childrenByCompound, allChildrenByCompound: allChildrenByCompound,
            eventsByTaskId: eventsByTaskId, allEventsByTaskId: allEventsByTaskId,
            placements: placements, boardById: boardById
        )
        let rows = CountsToward.countsTowardRows(rootId: counterId, tasks: tasks, inputs: inputs)
        let rowBoardIds = Set(rows.compactMap(\.boardId))
        return CountsTowardSectionData(
            counterName: name,
            rows: rows,
            taskById: taskById.filter { id, _ in rows.contains { $0.taskId == id } },
            boardById: boardById.filter { rowBoardIds.contains($0.key) }
        )
    }
}

// MARK: - "Counts toward" — credited boards (the completion moment)

extension AppDatabase {

    /// The boards OTHER than `excludingBoardId` a counts-toward completion also
    /// counts on (docs/SHARED_COUNTER_SETTINGS.md §3d): live, active, not closed
    /// or ended boards (`boardCanStillCountLogs`, the increment path's own
    /// creditable test) placing the counter ROOT or any live linked copy of it.
    ///
    /// - Parameters:
    ///   - rootId: The counter root a completed task counts toward.
    ///   - excludingBoardId: The board the person completed the task on.
    ///   - now: The ISO8601 clock (defaults to the current instant).
    /// - Returns: The credited boards, ordered by board id.
    /// - Throws: A database read error.
    func creditedBoards(
        forCounterRoot rootId: String, excludingBoardId: String?, now: String = AppDatabase.currentTimestamp()
    ) throws -> [AffectedBoard] {
        try read { db in
            let copyIds = try Task
                .filter(Column("sharedCounterId") == rootId && Column("isDeleted") == false)
                .fetchAll(db).map(\.id)
            let memberIds = [rootId] + copyIds
            let placements = try BoardTask
                .filter(memberIds.contains(Column("taskId")) && Column("isDeleted") == false)
                .fetchAll(db)
            var seen = Set<String>()
            var out: [AffectedBoard] = []
            for bt in placements where bt.boardId != excludingBoardId && !seen.contains(bt.boardId) {
                guard let board = try Board.fetchOne(db, key: bt.boardId),
                      Self.boardCanStillCountLogs(board, now: now) else { continue }
                seen.insert(board.id)
                out.append(AffectedBoard(boardId: board.id, boardName: board.displayName))
            }
            return out.sorted { $0.boardId < $1.boardId }
        }
    }
}
