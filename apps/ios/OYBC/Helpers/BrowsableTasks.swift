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
    /// library-browse surfaces (the Tasks tab list, the wizard "add from
    /// library" picker).
    ///
    /// Two independent classes of task are hidden:
    ///
    /// 1. Wizard-orphans — a task is HIDDEN iff it is wizard-born
    /// (`createdInWizard == true`) AND it has no placement on a live, non-draft board.
    /// Concretely, a wizard-born task is hidden when it lives ONLY on draft
    /// boards, or has no live placement at all (removed from the wizard
    /// pool — its Task row lingers after persist drops the `board_task` —
    /// or its only board was deleted). Everything else is visible:
    /// standalone/copied tasks (`createdInWizard` falsy) are never hidden,
    /// and a wizard-born task with at least one active/completed placement
    /// is visible.
    ///
    /// 2. Goal-less counters (P5) — a COUNTING task with `isCounter == true`
    /// and no `maxCount` cannot evaluate on a board; it lives in the
    /// Counters Hub, not the library. See `isGoalLessCounter` for the exact
    /// predicate and why it keys on the pair rather than bare absent-`maxCount`.
    ///
    /// Pure and fully derived at read time — no clearing logic: a hidden
    /// wizard-orphan reappears automatically the moment it lands on a
    /// non-draft board.
    ///
    /// Compound children inherit their parent compound's placements — a
    /// wizard-born inline subtask is never *directly* placed (it lives
    /// under its parent), so without inheritance it would look like a
    /// placement-less orphan and hide forever. With inheritance it's
    /// visible exactly when its parent compound is (keeping wizard-created
    /// subtasks pool-addable once the board goes active).
    ///
    /// - Parameters:
    ///   - tasks: candidate library tasks (already user-scoped + non-deleted).
    ///   - boardTasks: all `board_task` placement rows.
    ///   - boardStatusById: non-deleted `boardId → status`. Placements on
    ///     missing (deleted) boards are ignored — a board absent from this
    ///     map is treated as no live placement.
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
        return tasks.filter { task in
            if isGoalLessCounter(task) { return false }
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
