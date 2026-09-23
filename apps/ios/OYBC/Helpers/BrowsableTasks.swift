import Foundation

// MARK: - Draft-board library-visibility rule
//
// Swift twin of `packages/shared/src/algorithms/browsableTasks.ts`
// (`computeBrowsableTasks`). Any change to the visibility rule there MUST
// be mirrored here — the TS file is the source of truth. Extracted from an
// inline implementation that used to live on `TaskLibraryViewModel` (issue
// #246 part 2); `TaskLibraryViewModel.computeBrowsableTasks` now forwards
// to this helper so existing call sites and tests are unaffected.
enum BrowsableTasks {

    /// P5 — Hub-born counters. A goal-less counter (COUNTING + `isCounter` +
    /// no `maxCount`) cannot evaluate on a board; it lives in the Counters
    /// Hub, not the library. Keyed on the PAIR — never bare absent-
    /// `maxCount` — so a row whose flag was stripped by an old client
    /// degrades to a visible library row, never an unreachable task
    /// (docs/SHARED_COUNTERS.md §P5 decision 5). Also used by the PR-2
    /// compound-child write guards (`AppDatabase+Tasks.swift`).
    static func isGoalLessCounter(_ task: Task) -> Bool {
        task.type == .counting && task.isCounter == true && task.maxCount == nil
    }

    /// Filters the task library to the set that should appear in
    /// library-browse surfaces (the Tasks tab list, the wizard's Library
    /// sheet). Hides wizard-orphans, goal-less counters, and shared-counter
    /// members whose root is present — the full rule and its rationale live
    /// on the TS twin `computeBrowsableTasks` (`browsableTasks.ts`).
    ///
    /// - Parameters:
    ///   - tasks: candidate library tasks (already user-scoped + non-deleted).
    ///   - boardTasks: all `board_task` placement rows.
    ///   - boardStatusById: non-deleted `boardId → status`. Placements on
    ///     missing (deleted) boards are ignored.
    ///   - childToParents: child taskId → parent compound taskId(s). A
    ///     child's effective placements = its own ∪ its parents'. Defaults
    ///     to empty for a flat library.
    static func computeBrowsableTasks(
        tasks: [Task],
        boardTasks: [BoardTask],
        boardStatusById: [String: BoardStatus],
        childToParents: [String: [String]] = [:]
    ) -> [Task] {
        // taskId → set of non-deleted board ids it's placed on.
        var placementsByTask: [String: Set<String>] = [:]
        for bt in boardTasks {
            guard boardStatusById[bt.boardId] != nil else { continue }
            placementsByTask[bt.taskId, default: []].insert(bt.boardId)
        }
        // Live id → task, for the member rule's root lookup below. Callers
        // pass a non-deleted set already; the `isDeleted` filter is
        // belt-and-braces so this can't disagree with the hub, which filters
        // deleted rows itself.
        var liveById: [String: Task] = [:]
        for task in tasks where !task.isDeleted { liveById[task.id] = task }
        return tasks.filter { task in
            if isGoalLessCounter(task) { return false }
            // One generic family row (owner ruling 2026-09-22): a member —
            // a window-stamped derived counter or a P5 linked member — is
            // represented in the library by its ROOT, but only when that root
            // really exists, so a dangling link stays visible here rather than
            // being reachable from nowhere.
            if let srcId = task.sharedCounterId,
               let root = liveById[srcId],
               root.type == .counting {
                return false
            }
            guard task.createdInWizard else { return true }
            // Effective placements: own + inherited from parent compound(s).
            var boardIds = placementsByTask[task.id] ?? []
            for parentId in childToParents[task.id] ?? [] {
                boardIds.formUnion(placementsByTask[parentId] ?? [])
            }
            // No live placement (direct or inherited) → orphan → hidden.
            if boardIds.isEmpty { return false }
            return boardIds.contains { boardStatusById[$0] != .draft }
        }
    }
}
