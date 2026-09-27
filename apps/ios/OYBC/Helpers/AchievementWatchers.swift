import Foundation

// MARK: - Achievement-watcher lookup (Board Edit redesign slice 4, D8)
//
// Swift port of `packages/shared/src/algorithms/achievementWatchers.ts`. Which
// ACHIEVEMENT tasks watch a set of boards whose persisted stats just changed
// (owner ruling R3). Pure: the DB-layer `refreshWatchersForBoards` calls this,
// then re-derives the boards placing the returned watchers, iterating to a
// fixpoint over newly changed boards (this function is one hop only). An
// achievement watches one specific board (`referencedBoardId`) or every spawn
// of a recurring template (`referencedTemplateId`, matched through the changed
// boards' `spawnedFromTemplateId`). The TS file is the source of truth.

/// The Task fields `findWatcherTaskIds` reads. Mirrors the TS
/// `WatcherTaskFields`.
struct WatcherCandidate: Equatable {
    let id: String
    let type: TaskType
    let isDeleted: Bool
    let referencedBoardId: String?
    let referencedTemplateId: String?
}

extension WatcherCandidate {
    /// Project a `Task` row onto the fields the watcher lookup reads.
    init(task: Task) {
        self.init(
            id: task.id,
            type: task.type,
            isDeleted: task.isDeleted,
            referencedBoardId: task.referencedBoardId,
            referencedTemplateId: task.referencedTemplateId
        )
    }
}

/// The ids of the non-deleted ACHIEVEMENT tasks that watch any of the changed
/// boards — `referencedBoardId` is one of `changedBoardIds`, or
/// `referencedTemplateId` is one of `changedTemplateIds`. Mirrors the TS
/// `findWatcherTaskIds`.
///
/// - Parameters:
///   - candidates: Candidate tasks (may be unfiltered).
///   - changedBoardIds: Ids of the boards whose persisted stats changed.
///   - changedTemplateIds: Those boards' non-nil `spawnedFromTemplateId`s.
/// - Returns: Watcher task ids in `tasks` order, de-duplicated.
func findWatcherTaskIds(
    candidates: [WatcherCandidate],
    changedBoardIds: Set<String>,
    changedTemplateIds: Set<String>
) -> [String] {
    guard !changedBoardIds.isEmpty || !changedTemplateIds.isEmpty else { return [] }
    var seen = Set<String>()
    var out: [String] = []
    for task in candidates {
        guard task.type == .achievement, !task.isDeleted else { continue }
        let watchesBoard = task.referencedBoardId.map(changedBoardIds.contains) ?? false
        let watchesTemplate = task.referencedTemplateId.map(changedTemplateIds.contains) ?? false
        guard watchesBoard || watchesTemplate else { continue }
        guard seen.insert(task.id).inserted else { continue }
        out.append(task.id)
    }
    return out
}

/// Convenience overload of `findWatcherTaskIds` over changed `Board` rows.
func findWatcherTaskIds(tasks: [Task], changedBoards: [Board]) -> [String] {
    findWatcherTaskIds(
        candidates: tasks.map(WatcherCandidate.init(task:)),
        changedBoardIds: Set(changedBoards.map(\.id)),
        changedTemplateIds: Set(changedBoards.compactMap(\.spawnedFromTemplateId))
    )
}
