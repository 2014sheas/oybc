import Foundation
import GRDB

extension AppDatabase {
    /// Task Detail's placement read (docs/TASK_DETAIL_REDESIGN.md PR 5). Twin of
    /// the web `loadTaskDetailPlacements`.
    struct TaskDetailPlacements {
        /// The task's OWN live placements — the "Placed on" Activity rows.
        let ownPlacements: [BoardTask]
        /// The squares the hero may anchor on, best rank first (see `HeroAnchorCandidate`).
        let anchorCandidates: [HeroAnchorCandidate]
        /// Every live board the task reaches (own, a linked row's, a parent compound's).
        let boards: [Board]
        /// One row per reached board, read through the board grid's resolvers.
        let rows: [TaskPlacementRows.Row]
        /// Workspace tasks by id (members and their counter roots, for formatting).
        let taskById: [String: Task]
    }

    /// A square the Task Detail hero may anchor on (docs/TASK_DETAIL_REDESIGN.md
    /// binding decision 3, amended 2026-10-18): the task's own placement (rank 0),
    /// a counter root's linked row's (rank 1), or a compound a Normal / Counting
    /// task (or its linked row) is a DIRECT child of (rank 2; the hero is that
    /// child's control). Twin of the web `HeroAnchorCandidate`.
    struct HeroAnchorCandidate {
        let placement: BoardTask
        /// The compound child the hero drives, or nil when the square IS the task.
        let childTaskId: String?
        let rank: Int
    }

    /// The placement reach of a task set read with KEYED queries (twin of the web
    /// `loadTaskDetailPlacements`): the live link graph whole (ancestors are walked through
    /// it), the ids' live linked rows by `sharedCounterId`, then only the tasks of their
    /// ancestor / descendant compounds and the placements of the ancestors — not every
    /// task, placement and event in the workspace. The result equals the unscoped
    /// `placementReach` for the same ids.
    struct ScopedReach {
        let reach: PlacementReach
        /// Members, their ancestors and sub-trees (counter roots are added by the caller's `loadTasks`).
        var taskById: [String: Task]
        /// Every live compound link.
        let links: [CompoundChild]
        /// Live placements of the members and their ancestor compounds.
        let boardTasks: [BoardTask]
        let childIdsByCompound: [String: [String]]
    }

    /// Fetches the tasks in `ids` that `taskById` doesn't hold yet (chunked under SQLite's variable limit).
    static func loadMissingTasks(db: Database, ids: some Collection<String>, into taskById: inout [String: Task]) throws {
        let missing = Set(ids).filter { taskById[$0] == nil }.sorted()
        for start in stride(from: 0, to: missing.count, by: 400) {
            for t in try Task.fetchAll(db, keys: Array(missing[start..<min(start + 400, missing.count)])) { taskById[t.id] = t }
        }
    }

    /// Every id reachable from `seeds` through `edges` (the seeds included).
    fileprivate static func closure(_ seeds: some Sequence<String>, _ edges: [String: [String]]) -> Set<String> {
        var out = Set(seeds)
        var queue = Array(out)
        var head = 0
        while head < queue.count {
            let id = queue[head]; head += 1
            for next in edges[id] ?? [] where out.insert(next).inserted { queue.append(next) }
        }
        return out
    }

    static func scopedPlacementReach(db: Database, taskIds: Set<String>) throws -> ScopedReach {
        let links = try CompoundChild.filter(Column("isDeleted") == false).fetchAll(db)
        var parentsByChild: [String: [String]] = [:]
        var childIdsByCompound: [String: [String]] = [:]
        for l in links {
            parentsByChild[l.childTaskId, default: []].append(l.compoundTaskId)
            childIdsByCompound[l.compoundTaskId, default: []].append(l.childTaskId)
        }
        // Members: the ids and their live linked rows (a counter root is never placed itself).
        var members = taskIds
        let ids = taskIds.sorted()
        for start in stride(from: 0, to: ids.count, by: 400) {
            let chunk = Array(ids[start..<min(start + 400, ids.count)])
            let linked = try Task.filter(chunk.contains(Column("sharedCounterId")) && Column("isDeleted") == false).fetchAll(db)
            members.formUnion(linked.map(\.id))
        }
        let ancestors = closure(members, parentsByChild)
        let subtree = closure(members, childIdsByCompound)
        var taskById: [String: Task] = [:]
        try loadMissingTasks(db: db, ids: ancestors.union(subtree), into: &taskById)

        var boardTasks: [BoardTask] = []
        let ancestorIds = ancestors.sorted()
        for start in stride(from: 0, to: ancestorIds.count, by: 400) {
            let chunk = Array(ancestorIds[start..<min(start + 400, ancestorIds.count)])
            boardTasks += try BoardTask.filter(chunk.contains(Column("taskId")) && Column("isDeleted") == false).fetchAll(db)
        }
        let reach = DerivationPass.placementsReachedByTasks(
            ids: taskIds, tasks: Array(taskById.values), compoundChildren: links, boardTasks: boardTasks
        )
        return ScopedReach(reach: reach, taskById: taskById, links: links, boardTasks: boardTasks, childIdsByCompound: childIdsByCompound)
    }

    /// Resolve where a task lives on boards: its placement REACH (the one the
    /// cascade and the hub use — own placements, a counter root's linked rows',
    /// every containing compound's), each board's row scored by
    /// `TaskPlacementRows.rows` over that board's window. One read, so the rows,
    /// the boards and the anchor placements agree. The reads are keyed to what the
    /// reach can touch (`scopedPlacementReach`), so a write elsewhere in a large
    /// workspace costs this nothing.
    ///
    /// - Parameter taskId: The task whose detail page this is.
    /// - Returns: The placement read.
    func fetchTaskDetailPlacements(taskId: String) throws -> TaskDetailPlacements {
        try read { db in
            var scoped = try Self.scopedPlacementReach(db: db, taskIds: [taskId])
            let reach = scoped.reach
            let links = scoped.links
            let reachedBoards = reach.boardIds.isEmpty
                ? []
                : try Board.filter(reach.boardIds.contains(Column("id"))).fetchAll(db)
            let live = reachedBoards.filter { !$0.isDeleted }

            // An achievement's value is its cell in its board's grid: that board's cells (and
            // their sub-trees) and every board it may watch.
            var boardTasksByBoard: [String: [BoardTask]] = [:]
            var allBoards: [Board] = live
            let watcherBoardIds = Set(
                reach.placements.filter { scoped.taskById[$0.memberTaskId]?.type == .achievement }.map { $0.boardTask.boardId }
            )
            if !watcherBoardIds.isEmpty {
                let cells = try BoardTask
                    .filter(watcherBoardIds.contains(Column("boardId")) && Column("isDeleted") == false)
                    .fetchAll(db)
                boardTasksByBoard = Dictionary(grouping: cells, by: \.boardId)
                let cellClosure = Self.closure(cells.map(\.taskId), scoped.childIdsByCompound)
                try Self.loadMissingTasks(db: db, ids: cellClosure, into: &scoped.taskById)
                allBoards = try Board.filter(Column("isDeleted") == false).fetchAll(db)
            }
            // A linked task reads its counter root's events.
            try Self.loadMissingTasks(
                db: db, ids: scoped.taskById.values.compactMap { $0.sharedCounterId.flatMap { $0.isEmpty ? nil : $0 } },
                into: &scoped.taskById
            )
            let taskById = scoped.taskById
            var events: [TaskEvent] = []
            let eventTaskIds = taskById.keys.sorted()
            for start in stride(from: 0, to: eventTaskIds.count, by: 400) {
                let chunk = Array(eventTaskIds[start..<min(start + 400, eventTaskIds.count)])
                events += try TaskEvent.filter(chunk.contains(Column("taskId")) && Column("isDeleted") == false).fetchAll(db)
            }

            let rows = TaskPlacementRows.rows(
                taskId: taskId,
                reach: reach.placements,
                boardsById: Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
                taskById: taskById,
                childrenByCompound: Dictionary(grouping: links, by: \.compoundTaskId),
                eventsByTaskId: Dictionary(grouping: events, by: \.taskId),
                boardTasksByBoard: boardTasksByBoard,
                allBoards: allBoards
            )
            return TaskDetailPlacements(
                ownPlacements: scoped.boardTasks.filter { $0.taskId == taskId },
                anchorCandidates: Self.heroAnchorCandidates(
                    taskId: taskId, reach: reach.placements, taskById: taskById,
                    childrenByCompound: Dictionary(grouping: links, by: \.compoundTaskId)
                ),
                boards: live,
                rows: rows,
                taskById: taskById
            )
        }
    }

    /// Ranks the reach into hero anchor candidates (stable within a rank).
    static func heroAnchorCandidates(
        taskId: String, reach: [ReachedPlacement], taskById: [String: Task],
        childrenByCompound: [String: [CompoundChild]]
    ) -> [HeroAnchorCandidate] {
        let candidates: [HeroAnchorCandidate] = reach.compactMap { p in
            guard let via = p.viaCompoundId else {
                return HeroAnchorCandidate(placement: p.boardTask, childTaskId: nil, rank: p.memberTaskId == taskId ? 0 : 1)
            }
            let direct = (childrenByCompound[via] ?? []).contains { $0.childTaskId == p.memberTaskId }
            let type = taskById[p.memberTaskId]?.type
            guard direct, type == .normal || type == .counting else { return nil }
            return HeroAnchorCandidate(placement: p.boardTask, childTaskId: p.memberTaskId, rank: 2)
        }
        return candidates.enumerated().sorted { ($0.element.rank, $0.offset) < ($1.element.rank, $1.offset) }.map(\.element)
    }
}
