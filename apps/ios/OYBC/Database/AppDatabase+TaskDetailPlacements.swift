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

    /// Resolve where a task lives on boards: its placement REACH (the one the
    /// cascade and the hub use — own placements, a counter root's linked rows',
    /// every containing compound's), each board's row scored by
    /// `TaskPlacementRows.rows` over that board's window. One read, so the rows,
    /// the boards and the anchor placements agree.
    ///
    /// - Parameter taskId: The task whose detail page this is.
    /// - Returns: The placement read.
    func fetchTaskDetailPlacements(taskId: String) throws -> TaskDetailPlacements {
        try read { db in
            let tasks = try Task.fetchAll(db)
            let links = try CompoundChild.filter(Column("isDeleted") == false).fetchAll(db)
            let boardTasks = try BoardTask.filter(Column("isDeleted") == false).fetchAll(db)
            let reach = DerivationPass.placementsReachedByTasks(
                ids: [taskId], tasks: tasks, compoundChildren: links, boardTasks: boardTasks
            )
            let reachedBoards = reach.boardIds.isEmpty
                ? []
                : try Board.filter(reach.boardIds.contains(Column("id"))).fetchAll(db)
            let taskById = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
            let watches = reach.placements.contains { taskById[$0.memberTaskId]?.type == .achievement }
            let allBoards = watches ? try Board.fetchAll(db) : reachedBoards
            let events = try TaskEvent.filter(Column("isDeleted") == false).fetchAll(db)

            let live = reachedBoards.filter { !$0.isDeleted }
            let rows = TaskPlacementRows.rows(
                taskId: taskId,
                reach: reach.placements,
                boardsById: Dictionary(live.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a }),
                taskById: taskById,
                childrenByCompound: Dictionary(grouping: links, by: \.compoundTaskId),
                eventsByTaskId: Dictionary(grouping: events, by: \.taskId),
                boardTasksByBoard: Dictionary(grouping: boardTasks.filter { reach.boardIds.contains($0.boardId) }, by: \.boardId),
                allBoards: allBoards.filter { !$0.isDeleted }
            )
            return TaskDetailPlacements(
                ownPlacements: boardTasks.filter { $0.taskId == taskId },
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
