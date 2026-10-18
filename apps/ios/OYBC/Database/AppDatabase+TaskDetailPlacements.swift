import Foundation
import GRDB

extension AppDatabase {
    /// Task Detail's placement read (docs/TASK_DETAIL_REDESIGN.md PR 5). Twin of
    /// the web `loadTaskDetailPlacements`.
    struct TaskDetailPlacements {
        /// The task's OWN live placements — the hero anchor and the "Placed on" Activity rows.
        let ownPlacements: [BoardTask]
        /// Every live board the task reaches (own, a linked row's, a parent compound's).
        let boards: [Board]
        /// One row per reached board, read through the board grid's resolvers.
        let rows: [TaskPlacementRows.Row]
        /// Workspace tasks by id (members and their counter roots, for formatting).
        let taskById: [String: Task]
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
                boards: live,
                rows: rows,
                taskById: taskById
            )
        }
    }
}
