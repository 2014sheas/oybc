import Foundation
import GRDB

extension AppDatabase {
    // MARK: - Tasks

    func fetchTasks(userId: String) throws -> [Task] {
        return try read { db in
            try Task
                .filter(Column("userId") == userId && Column("isDeleted") == false)
                .order(Column("title"))
                .fetchAll(db)
        }
    }

    func fetchTask(id: String) throws -> Task? {
        return try read { db in
            try Task.fetchOne(db, key: id)
        }
    }

    /// Fetch tasks by id, regardless of `isDeleted` (callers that need to
    /// distinguish should check the returned rows' `isDeleted`). Used by
    /// the wizard's hydration + member-rule paths that already have a set
    /// of referenced task ids and need a `tasksById` lookup. Mirrors
    /// `fetchBoards(ids:)`.
    func fetchTasks(ids: [String]) throws -> [Task] {
        guard !ids.isEmpty else { return [] }
        return try read { db in
            try Task
                .filter(ids.contains(Column("id")))
                .fetchAll(db)
        }
    }

    func saveTask(_ task: Task) throws {
        try write { db in
            try task.save(db)
        }
    }

    /// Atomic save + sync-enqueue used by the Task detail view's edit
    /// flow. Replaces the prior pattern of calling `saveTask` followed
    /// by `enqueueTaskSyncUpdate` in two separate transactions — a
    /// crash between the two left the local row updated but no
    /// Firestore sync, silently dropping the edit on other devices.
    func saveTaskAndEnqueueUpdate(_ task: Task) throws {
        try write { db in
            try task.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "tasks",
                entityId: task.id,
                operationType: .update,
                payload: task,
                now: Self.currentTimestamp(),
            ).enqueue(db)
        }
    }

    // MARK: - Task cascade helpers (M1 — live-edit)

    /// Run the cross-board derivation cascade for a task that just changed.
    ///
    /// Void-returning cascade for the Tasks-tab edit path. Sibling of
    /// `runBoardCascadeForTaskWithResults` (below), which additionally returns
    /// per-board results for the board-play flash messages.
    ///
    /// - Parameters:
    ///   - db: GRDB database handle (must be inside a write transaction).
    ///   - changedTaskId: The task whose state just changed.
    ///   - now: ISO8601 timestamp for stamping updated board rows.
    ///
    /// Must be called inside an active write transaction covering
    /// `tasks`, `boardTasks`, `compoundChildren`, `boards`, and `syncQueue`.
    static func runBoardCascadeForTask(
        db: Database,
        changedTaskId: String,
        now: String
    ) throws {
        let allChildren: [CompoundChild] = try CompoundChild
            .filter(Column("isDeleted") == false)
            .fetchAll(db)
        let allBoardTasks: [BoardTask] = try BoardTask
            .filter(Column("isDeleted") == false)
            .fetchAll(db)
        let allTasks: [Task] = try Task.fetchAll(db)
        let allBoards: [Board] = try Board.fetchAll(db)
        // Windowed Completion — group events once so every board evaluates
        // windowed (docs §Sync). Mirrors orchestration.ts's `buildWindowContext`.
        let windowContext = try Self.buildWindowContext(db: db)

        var taskById: [String: Task] = [:]
        for t in allTasks { taskById[t.id] = t }
        var childrenByCompound: [String: [CompoundChild]] = [:]
        for c in allChildren {
            childrenByCompound[c.compoundTaskId, default: []].append(c)
        }

        let parentCompounds = DerivationPass.findTransitiveParentCompounds(
            changedTaskId: changedTaskId,
            children: allChildren
        )
        let affectedBoardIds = DerivationPass.findAffectedBoardIds(
            changedTaskId: changedTaskId,
            parentCompounds: parentCompounds,
            boardTasks: allBoardTasks
        )

        for boardId in affectedBoardIds {
            guard var board = try Board.fetchOne(db, key: boardId), !board.isDeleted, board.sealedAt == nil else { continue }
            // Board-integrity PR-2 (issue #375): resolve collisions/OOB before
            // deriving, so persisted stats can never disagree with the render.
            let boardTasksOnBoard = PlacementIntegrity.resolvedRows(
                boardId: boardId, in: allBoardTasks, boardSize: board.boardSize
            )
            let update = DerivationPass.computeBoardStatsUpdate(
                board: board,
                boardTasksOnBoard: boardTasksOnBoard,
                childrenByCompound: childrenByCompound,
                taskById: taskById,
                allBoards: allBoards,
                windowContext: windowContext
            )

            let totalSquares = board.boardSize * board.boardSize
            let isGreenlogNow = update.completedTasks >= totalSquares

            board.completedTasks = update.completedTasks
            board.totalTasks = totalSquares
            board.linesCompleted = update.linesCompleted
            board.completedLineIds = update.completedLineIds.isEmpty ? nil : update.completedLineIds
            board.updatedAt = now
            board.version += 1

            if isGreenlogNow, board.status == .active {
                board.status = .completed
                board.completedAt = now
            } else if !isGreenlogNow, board.status == .completed {
                board.status = .active
                board.completedAt = nil
            }

            try board.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "boards",
                entityId: boardId,
                operationType: .update,
                payload: board,
                now: now
            ).enqueue(db)
        }
    }

    /// Save a task + enqueue sync + run the board derivation cascade.
    ///
    /// UI-edit path wrapper (Tasks tab + Task detail sheet). Keeps the
    /// cascade write in the same transaction as the task save so a crash
    /// mid-write can't leave boards stale.
    ///
    /// - Parameter task: The updated task value (caller has already bumped
    ///   `updatedAt` and `version`).
    func saveTaskAndCascade(_ task: Task) throws {
        try write { db in
            try Self.saveTaskAndCascade(db: db, task: task)
        }
    }

    /// `db`-scoped core of `saveTaskAndCascade` — Board-integrity PR-4 (Item 3,
    /// docs/BOARD_INTEGRITY.md): lets `BoardPlayViewModel.handleEditSave` compose
    /// this cascade with the other Save sub-ops into ONE outer
    /// `database.write { db in }` transaction (GRDB's `write` is not reentrant, so
    /// the instance method above can't be called from inside another `write`
    /// block). Identical body to the instance method.
    ///
    /// Must be called inside an active write transaction covering `tasks`,
    /// `boardTasks`, `compoundChildren`, `boards`, and `syncQueue`.
    static func saveTaskAndCascade(db: Database, task: Task) throws {
        try task.save(db)
        let now = Self.currentTimestamp()
        try SyncQueueBuilder.makeItem(
            entityType: "tasks",
            entityId: task.id,
            operationType: .update,
            payload: task,
            now: now
        ).enqueue(db)
        try Self.runBoardCascadeForTask(db: db, changedTaskId: task.id, now: now)
    }

    // MARK: - Local board-interaction orchestration (B4)
    //
    // These OWN the complete write transactions the board-play surface used
    // to author inline (task completion + compound-child fallback toggle).
    // Moved VERBATIM from `BoardPlayViewModel`'s file-private `bpv*` free
    // functions + write blocks so the sync-enqueue lives in the data layer,
    // not the view model. The `bpvEncodeSyncPayload` / `bpvMakeSyncItem`
    // duplicates were dropped — they were byte-identical to
    // `SyncQueueBuilder.encodePayload` / `SyncQueueBuilder.makeItem`, which
    // this code now calls directly. The VM methods are thin callers that
    // consume the returned per-board results to derive their flash messages.

    /// Per-board outcome of the local-interaction cascade. The caller uses
    /// this to surface a flash message for the currently-visible board.
    /// (Renamed from `BPVCascadeBoardResult`, moved here from the view model.)
    struct CascadeBoardResult {
        let update: DerivationPass.BoardStatsUpdate
        /// True if this board transitioned COMPLETED → ACTIVE because it is no
        /// longer GREENLOG.
        let wasReactivated: Bool
        /// True if every cell on this board is now complete.
        let isGreenlogNow: Bool
        /// True if `board.status` was bumped to `.completed` by this cascade pass.
        let didAutoComplete: Bool
    }

    /// Cross-board derivation cascade that additionally returns per-board
    /// results and applies the GREENLOG status transitions local interactions
    /// own. Sibling of `runBoardCascadeForTask` (which returns Void for the
    /// Tasks-tab edit path); this variant powers the board-play flash messages
    /// by reporting reactivation / auto-complete / bingo diffs per affected
    /// board.
    ///
    /// Mirrors `SyncService.runPullCascade` but additionally applies the
    /// GREENLOG status transitions. Must be called inside a write transaction
    /// covering `boards` and `syncQueue`.
    ///
    /// - Parameters:
    ///   - db: GRDB database handle (must be inside a write transaction).
    ///   - changedTaskId: The id of the Task whose state just changed.
    ///   - now: ISO8601 timestamp to stamp on every updated board row.
    /// - Returns: A `[boardId: CascadeBoardResult]` map. Boards excluded by
    ///   `isDeleted` are omitted.
    static func runBoardCascadeForTaskWithResults(
        db: Database,
        changedTaskId: String,
        now: String
    ) throws -> [String: CascadeBoardResult] {
        let allChildren: [CompoundChild] = try CompoundChild
            .filter(Column("isDeleted") == false)
            .fetchAll(db)
        let allBoardTasks: [BoardTask] = try BoardTask
            .filter(Column("isDeleted") == false)
            .fetchAll(db)
        let allTasks: [Task] = try Task.fetchAll(db)
        // Phase 6.3 — DerivationPass.computeBoardStatsUpdate needs the
        // workspace's boards to evaluate the specific-board / recurring-
        // template achievement branches. Pre-6.3 calls omitted this and
        // the algorithm defaults to []; on this cascade path we already
        // have the data fetched, so use it.
        let allBoards: [Board] = try Board.fetchAll(db)
        // Windowed Completion — group events once so every board evaluates
        // windowed (docs §Sync). Mirrors orchestration.ts's `buildWindowContext`.
        let windowContext = try Self.buildWindowContext(db: db)

        var taskById: [String: Task] = [:]
        for t in allTasks { taskById[t.id] = t }
        var childrenByCompound: [String: [CompoundChild]] = [:]
        for c in allChildren {
            childrenByCompound[c.compoundTaskId, default: []].append(c)
        }

        let parentCompounds = DerivationPass.findTransitiveParentCompounds(
            changedTaskId: changedTaskId,
            children: allChildren
        )
        let affectedBoardIds = DerivationPass.findAffectedBoardIds(
            changedTaskId: changedTaskId,
            parentCompounds: parentCompounds,
            boardTasks: allBoardTasks
        )

        var results: [String: CascadeBoardResult] = [:]
        for boardId in affectedBoardIds {
            guard var board = try Board.fetchOne(db, key: boardId), !board.isDeleted, board.sealedAt == nil else { continue }
            // Board-integrity PR-2 (issue #375): resolve collisions/OOB before
            // deriving, so persisted stats can never disagree with the render.
            let boardTasksOnBoard = PlacementIntegrity.resolvedRows(
                boardId: boardId, in: allBoardTasks, boardSize: board.boardSize
            )
            let update = DerivationPass.computeBoardStatsUpdate(
                board: board,
                boardTasksOnBoard: boardTasksOnBoard,
                childrenByCompound: childrenByCompound,
                taskById: taskById,
                allBoards: allBoards,
                windowContext: windowContext
            )

            let totalSquares = board.boardSize * board.boardSize
            let isGreenlogNow = update.completedTasks >= totalSquares
            var wasReactivated = false
            var didAutoComplete = false

            board.completedTasks = update.completedTasks
            board.totalTasks = totalSquares
            board.linesCompleted = update.linesCompleted
            board.completedLineIds = update.completedLineIds.isEmpty ? nil : update.completedLineIds
            board.updatedAt = now
            board.version += 1

            if isGreenlogNow, board.status == .active {
                board.status = .completed
                board.completedAt = now
                didAutoComplete = true
            } else if !isGreenlogNow, board.status == .completed {
                board.status = .active
                board.completedAt = nil
                wasReactivated = true
            }

            try board.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "boards",
                entityId: boardId,
                operationType: .update,
                payload: board,
                now: now
            ).enqueue(db)

            results[boardId] = CascadeBoardResult(
                update: update,
                wasReactivated: wasReactivated,
                isGreenlogNow: isGreenlogNow,
                didAutoComplete: didAutoComplete
            )
        }
        return results
    }

    /// Create a single Task + enqueue its `.create` sync op atomically.
    /// Used by the standalone quick-add / derive-counter paths (Tasks tab
    /// create form, Riso library sheet) that previously
    /// authored the write + enqueue inline in view code.
    ///
    /// - Parameters:
    ///   - task: The new Task to insert.
    ///   - now: ISO8601 timestamp for the sync-queue row.
    func createTaskAndEnqueue(_ task: Task, now: String) throws {
        try write { db in
            try task.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "tasks",
                entityId: task.id,
                operationType: .create,
                payload: task,
                now: now
            ).enqueue(db)
        }
    }

    /// Create a Task plus a set of paired child Task + CompoundChild link
    /// rows, all `.create`-enqueued in one transaction. Preserves the
    /// `zip(childTasks, childLinks)` write shape moved verbatim from the
    /// create form's immediate-persist path.
    ///
    /// P5 guard: a `childLinks` row referencing an existing task (not one of
    /// `childTasks`) throws if that task is a goal-less counter
    /// (`BrowsableTasks.isGoalLessCounter`) — see `AppDatabaseError.invalidCompoundChild`.
    ///
    /// - Parameters:
    ///   - task: The parent Task to insert.
    ///   - childTasks: New child Task rows, paired positionally with `childLinks`.
    ///   - childLinks: The CompoundChild link rows, paired with `childTasks`.
    ///   - now: ISO8601 timestamp for the sync-queue rows.
    /// - Throws: `AppDatabaseError.invalidCompoundChild` if a link references
    ///   an existing goal-less counter task.
    func createTaskWithPairedChildrenAndEnqueue(
        task: Task,
        childTasks: [Task],
        childLinks: [CompoundChild],
        now: String
    ) throws {
        let newChildIds = Set(childTasks.map { $0.id })
        try write { db in
            // P5 guard: any link whose childTaskId is NOT one of the new
            // children created in this call references an existing task —
            // reject it if that task is a goal-less counter (mirrors web's
            // `createCompoundChild` guard).
            for link in childLinks where !newChildIds.contains(link.childTaskId) {
                if let existing = try Task.fetchOne(db, key: link.childTaskId),
                   BrowsableTasks.isGoalLessCounter(existing) {
                    throw AppDatabaseError.invalidCompoundChild(
                        "createTaskWithPairedChildrenAndEnqueue: goal-less counter tasks cannot be compound children"
                    )
                }
            }

            try task.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "tasks",
                entityId: task.id,
                operationType: .create,
                payload: task,
                now: now
            ).enqueue(db)

            for (childTask, link) in zip(childTasks, childLinks) {
                try childTask.save(db)
                try SyncQueueBuilder.makeItem(
                    entityType: "tasks",
                    entityId: childTask.id,
                    operationType: .create,
                    payload: childTask,
                    now: now
                ).enqueue(db)
                try link.save(db)
                try SyncQueueBuilder.makeItem(
                    entityType: "compoundChildren",
                    entityId: link.id,
                    operationType: .create,
                    payload: link,
                    now: now
                ).enqueue(db)
            }
        }
    }

    /// Create a compound parent Task + its CompoundChild links, inserting a
    /// child Task row only for NEW inline children (existing-library children
    /// are referenced by id and already live in GRDB). All rows are
    /// `.create`-enqueued in one transaction. Moved verbatim from the create
    /// form's `handleCreateCompoundAndAddToPool` immediate path.
    ///
    /// P5 guard: a `childLinks` row referencing an existing-library task
    /// (not one of `newChildTasks`) throws if that task is a goal-less
    /// counter (`BrowsableTasks.isGoalLessCounter`) — a hub-born counter with
    /// no `maxCount` has nothing evaluable to contribute to a compound's
    /// AND/OR/M_OF_N logic (docs/SHARED_COUNTERS.md §P5). A promoted counter
    /// (still `isCounter` but with a `maxCount`) is unaffected.
    ///
    /// - Parameters:
    ///   - parent: The compound parent Task to insert.
    ///   - newChildTasks: The NEW inline child Task rows to insert.
    ///   - childLinks: The CompoundChild link rows (both new-inline and
    ///     existing-library children).
    ///   - now: ISO8601 timestamp for the sync-queue rows.
    /// - Throws: `AppDatabaseError.invalidCompoundChild` if a link references
    ///   an existing-library goal-less counter task.
    func createCompoundAndEnqueue(
        parent: Task,
        newChildTasks: [Task],
        childLinks: [CompoundChild],
        now: String
    ) throws {
        let newChildIds = Set(newChildTasks.map { $0.id })
        try write { db in
            // P5 guard: any link whose childTaskId is NOT one of the new
            // inline children created in this call references an existing
            // task — reject it if that task is a goal-less counter (mirrors
            // web's `createCompoundChild` guard).
            for link in childLinks where !newChildIds.contains(link.childTaskId) {
                if let existing = try Task.fetchOne(db, key: link.childTaskId),
                   BrowsableTasks.isGoalLessCounter(existing) {
                    throw AppDatabaseError.invalidCompoundChild(
                        "createCompoundAndEnqueue: goal-less counter tasks cannot be compound children"
                    )
                }
            }

            // 1. Parent compound task + sync entry.
            try parent.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "tasks",
                entityId: parent.id,
                operationType: .create,
                payload: parent,
                now: now
            ).enqueue(db)

            // 2. For each link: if the child is a NEW inline task, insert the
            //    child Task row + its sync entry first. Then insert the
            //    CompoundChild link + its sync entry. Existing-sub links skip
            //    the Task insert — the Task already lives in GRDB.
            for link in childLinks {
                if newChildIds.contains(link.childTaskId),
                   let childTask = newChildTasks.first(where: { $0.id == link.childTaskId }) {
                    try childTask.save(db)
                    try SyncQueueBuilder.makeItem(
                        entityType: "tasks",
                        entityId: childTask.id,
                        operationType: .create,
                        payload: childTask,
                        now: now
                    ).enqueue(db)
                }
                try link.save(db)
                try SyncQueueBuilder.makeItem(
                    entityType: "compoundChildren",
                    entityId: link.id,
                    operationType: .create,
                    payload: link,
                    now: now
                ).enqueue(db)
            }
        }
    }

    /// Soft-delete a task. See `deleteBoard` for the version-bump rationale.
    /// Enqueues a `tasks` DELETE sync item so the tombstone reaches
    /// Firestore, mirroring `deleteBoard`'s fix — without this the deletion
    /// never propagates and the task resurrects on another device. NOTE:
    /// there is currently no production caller of this bare method — all
    /// task-delete UI routes through `deleteTaskWithCascade`, which already
    /// enqueues its own sync items — but this closes the same latent trap
    /// for any future direct caller.
    func deleteTask(id: String) throws {
        try write { db in
            guard var task = try Task.fetchOne(db, key: id) else { return }
            let now = Self.currentTimestamp()
            task.isDeleted = true
            task.deletedAt = now
            task.updatedAt = now
            task.version += 1
            try task.update(db)
            try SyncQueueBuilder.makeItem(
                entityType: "tasks",
                entityId: id,
                operationType: .delete,
                payload: task,
                now: now
            ).enqueue(db)
        }
    }

    /// Summary of what `deleteTaskWithCascade` would remove. Lets the
    /// detail view surface affected counts in the confirm dialog before
    /// the user commits. Mirrors web's `TaskDeletionImpact`.
    struct TaskDeletionImpact {
        /// Count of `BoardTask` rows that reference this task as a placement.
        let boardTaskCount: Int
        /// Distinct boards the placements span (cells on the same board count once).
        let affectedBoardIds: [String]
        /// The live (non-deleted) board records the placements live on. Same
        /// set as `affectedBoardIds` — included so the confirm sheet can
        /// surface board name + status without a second fetch.
        let affectedBoards: [Board]
        /// `CompoundChild` rows where the task is the CHILD. The parent
        /// compound loses this child; sibling children remain.
        let childLinkCount: Int
        /// `CompoundChild` rows where the task IS the parent compound.
        /// Each parent link is severed; the child Tasks remain.
        let parentLinkCount: Int
        /// P5 decision 8 — count of live tasks whose `sharedCounterId` points
        /// at this task (i.e. this task is a counter SOURCE) and that will be
        /// UNLINKED-and-kept. 0 for any non-source task. Excludes the
        /// window-stamped derived members counted by
        /// `derivedWindowCounterCount` below — those are deleted, not
        /// unlinked. Deleting a source unlinks these (see
        /// `deleteCounterWithUnlink` in `AppDatabase+Counters.swift`) rather
        /// than orphaning them, so the confirm dialog surfaces this count
        /// separately from the ordinary board/compound impact above.
        let counterMemberCount: Int
        /// The counter-member Task rows themselves (same set counted by
        /// `counterMemberCount`), so the confirm sheet can list them without
        /// a second fetch.
        let counterMembers: [Task]
        /// Board Sources §Member rules B2 (RB11) — count of this task's live
        /// window-stamped derived counters, which the cascade SOFT-DELETES
        /// (with their placements) rather than unlinking: each is a per-window
        /// artifact of a board, not library content the user authored. 0 for
        /// any non-source task, and disjoint from `counterMemberCount` above.
        let derivedWindowCounterCount: Int
    }

    /// Read-only impact calculation; safe to call before showing the
    /// confirm dialog. Filters BoardTask placements to LIVE rows on
    /// non-deleted boards — both the row's own `isDeleted` (Board-integrity
    /// PR-1: a tombstoned placement isn't a real cell) and the board's
    /// `isDeleted` (an orphan placement on a soft-deleted board would
    /// otherwise inflate the user-facing count). The actual cascade still
    /// soft-deletes every matching LIVE placement (storage cleanup); the
    /// dialog only reports cells the user can still see.
    func computeTaskDeletionImpact(taskId: String) throws -> TaskDeletionImpact {
        try read { db in
            let allPlacements = try BoardTask
                .filter(Column("taskId") == taskId && Column("isDeleted") == false)
                .fetchAll(db)
            let placementBoardIds = Array(Set(allPlacements.map { $0.boardId }))
            let liveBoards: [Board] = placementBoardIds.isEmpty
                ? []
                : try Board
                    .filter(placementBoardIds.contains(Column("id"))
                            && Column("isDeleted") == false)
                    .fetchAll(db)
            let liveBoardIds = Set(liveBoards.map { $0.id })
            let visiblePlacements = allPlacements.filter { liveBoardIds.contains($0.boardId) }
            let childLinks = try CompoundChild
                .filter(Column("childTaskId") == taskId && Column("isDeleted") == false)
                .fetchCount(db)
            let parentLinks = try CompoundChild
                .filter(Column("compoundTaskId") == taskId && Column("isDeleted") == false)
                .fetchCount(db)
            // B2 (RB11) — the members split two ways at delete time, so the
            // preview reports them separately: a window-stamped derived
            // counter is retired with its placements, an ordinary member is
            // unlinked and kept (`deleteCounterWithUnlink`).
            let allMembers = try Task
                .filter(Column("sharedCounterId") == taskId && Column("isDeleted") == false)
                .fetchAll(db)
            let counterMembers = allMembers.filter { !BoardSources.isWindowStampedDerived($0) }
            return TaskDeletionImpact(
                boardTaskCount: visiblePlacements.count,
                affectedBoardIds: Array(liveBoardIds),
                affectedBoards: liveBoards,
                childLinkCount: childLinks,
                parentLinkCount: parentLinks,
                counterMemberCount: counterMembers.count,
                counterMembers: counterMembers,
                derivedWindowCounterCount: allMembers.count - counterMembers.count,
            )
        }
    }

    /// Cascade-delete a task. Mirrors web's `deleteTaskWithCascade`:
    ///
    /// 1. **BoardTask placements** referencing this task — SOFT-deleted
    ///    (Board-integrity PR-1: version bump + isDeleted + deletedAt,
    ///    matching every other synced collection). Each removal queued
    ///    for sync DELETE so other devices drop the placement.
    /// 2. **`CompoundChild` rows where the task IS the parent compound**
    ///    — soft-deleted (version bump + isDeleted + deletedAt). The
    ///    child Tasks themselves stay alive.
    /// 3. **`CompoundChild` rows where the task IS a child** — soft-
    ///    deleted. Sibling links + the parent Task itself are untouched.
    /// 4. **The Task itself** — soft-deleted with version bump (matches
    ///    `deleteTask`'s LWW semantics).
    ///
    /// All operations run in a single GRDB write transaction so a
    /// crash mid-cascade leaves a consistent local DB.
    func deleteTaskWithCascade(taskId: String) throws {
        try write { db in
            let now = Self.currentTimestamp()
            try Self.deleteTaskWithCascadeInDb(db: db, taskId: taskId, now: now)
        }
    }

    /// Cascade-delete a task given an ALREADY-OPEN write transaction — same
    /// four steps as `deleteTaskWithCascade`, extracted so callers that need
    /// the cascade to run alongside other writes in one wider transaction
    /// (e.g. `deleteCounterWithUnlink` in `AppDatabase+Counters.swift`, P5
    /// decision 8) don't have to nest a second `write` block. Pure code-
    /// motion — `deleteTaskWithCascade` now delegates to this from inside
    /// its own `write` block; behavior is unchanged. Mirrors web's
    /// `deleteTaskWithCascadeInTxn`.
    ///
    /// - Parameters:
    ///   - db: GRDB database handle (must be inside a write transaction).
    ///   - taskId: The task to cascade-delete.
    ///   - now: ISO8601 timestamp stamped on every row written here.
    ///   - extraAffectedBoardIds: Boards the CALLER already knows must
    ///     re-derive in this transaction because of writes it made before
    ///     calling (final-review item 10: `deleteCounterWithUnlink` retires
    ///     the root's window-stamped members itself, so step 4b below can no
    ///     longer find them or their boards). Merged into the affected set;
    ///     unknown/sealed/deleted ids are skipped by step 5's own guards.
    static func deleteTaskWithCascadeInDb(
        db: Database,
        taskId: String,
        now: String,
        extraAffectedBoardIds: Set<String> = []
    ) throws {
        guard var task = try Task.fetchOne(db, key: taskId) else { return }

        // Windowed Completion (hardening item 3): capture the affected-board
        // set BEFORE any placements are removed below — reuses
        // findTransitiveParentCompounds / findAffectedBoardIds exactly like
        // `removeBoardTaskFromBoard`, so a board holding a bingo line through
        // this task (directly or via a compound parent) re-derives in THIS
        // transaction instead of relying on app-open self-heal (a persisted
        // line could otherwise keep a bingo through a now-empty cell, and
        // achievements could read it in the meantime).
        let allBoardTasksPreDelete = try BoardTask
            .filter(Column("isDeleted") == false)
            .fetchAll(db)
        let allCompoundChildrenPreDelete = try CompoundChild
            .filter(Column("isDeleted") == false)
            .fetchAll(db)
        let parentCompoundsForDeletion = DerivationPass.findTransitiveParentCompounds(
            changedTaskId: taskId,
            children: allCompoundChildrenPreDelete
        )
        var affectedBoardIdsForDeletion = DerivationPass.findAffectedBoardIds(
            changedTaskId: taskId,
            parentCompounds: parentCompoundsForDeletion,
            boardTasks: allBoardTasksPreDelete
        )
        affectedBoardIdsForDeletion.formUnion(extraAffectedBoardIds)

        // 1. Soft-delete BoardTask placements (tombstone — see BoardTask's doc comment).
        let placements = try BoardTask
            .filter(Column("taskId") == taskId && Column("isDeleted") == false)
            .fetchAll(db)
        for var bt in placements {
            bt.isDeleted = true
            bt.deletedAt = now
            bt.updatedAt = now
            bt.version += 1
            try bt.update(db)
            try SyncQueueBuilder.makeItem(
                entityType: "boardTasks",
                entityId: bt.id,
                operationType: .delete,
                payload: bt,
                now: now,
            ).enqueue(db)
        }

        // 2 + 3. Soft-delete compound-child links — both directions.
        let parentLinks = try CompoundChild
            .filter(Column("compoundTaskId") == taskId && Column("isDeleted") == false)
            .fetchAll(db)
        let childLinks = try CompoundChild
            .filter(Column("childTaskId") == taskId && Column("isDeleted") == false)
            .fetchAll(db)
        for var link in parentLinks + childLinks {
            link.isDeleted = true
            link.deletedAt = now
            link.updatedAt = now
            link.version += 1
            try link.update(db)
            try SyncQueueBuilder.makeItem(
                entityType: "compoundChildren",
                entityId: link.id,
                operationType: .delete,
                payload: link,
                now: now,
            ).enqueue(db)
        }

        // 4. Soft-delete the Task itself.
        task.isDeleted = true
        task.deletedAt = now
        task.updatedAt = now
        task.version += 1
        try task.update(db)
        try SyncQueueBuilder.makeItem(
            entityType: "tasks",
            entityId: task.id,
            operationType: .delete,
            payload: task,
            now: now,
        ).enqueue(db)

        // 4b. Board Sources §Member rules (B2) — the root's per-window derived
        //     counters go with it: each is an artifact of one board's window
        //     and means nothing once its root is gone (an ORDINARY linked
        //     member is untouched here — `deleteCounterWithUnlink` preserves
        //     those). Their boards join the affected set so a bingo line
        //     through a retired derived cell re-derives in step 5 instead of
        //     glowing until the app-open self-heal.
        let derivedIds = try Self.windowStampedDerivedIdsForRoot(db: db, rootTaskId: taskId)
        if !derivedIds.isEmpty {
            let derivedIdSet = Set(derivedIds)
            for bt in allBoardTasksPreDelete where derivedIdSet.contains(bt.taskId) {
                affectedBoardIdsForDeletion.insert(bt.boardId)
            }
            try Self.softDeleteWindowStampedDerived(db: db, taskIds: derivedIds, now: now)
        }

        // 5. Cascade — re-derive every affected board's stats + status from
        // the post-delete state. Mirrors `removeBoardTaskFromBoard`'s loop
        // verbatim: sealed/deleted boards skip, live boards get a version
        // bump + sync enqueue.
        if !affectedBoardIdsForDeletion.isEmpty {
            let allBoardTasksPost: [BoardTask] = try BoardTask
                .filter(Column("isDeleted") == false)
                .fetchAll(db)
            let allTasks: [Task] = try Task.fetchAll(db)
            let allBoards: [Board] = try Board.fetchAll(db)
            let allChildren: [CompoundChild] = try CompoundChild
                .filter(Column("isDeleted") == false)
                .fetchAll(db)

            var taskById: [String: Task] = [:]
            for t in allTasks { taskById[t.id] = t }
            var childrenByCompound: [String: [CompoundChild]] = [:]
            for c in allChildren {
                childrenByCompound[c.compoundTaskId, default: []].append(c)
            }

            // Windowed Completion: resolve against each board's own window
            // from the event log, not the lifetime cache.
            let windowContext = try Self.buildWindowContext(db: db)

            for boardId in affectedBoardIdsForDeletion {
                guard var board = try Board.fetchOne(db, key: boardId),
                      !board.isDeleted, board.sealedAt == nil else { continue }
                // Board-integrity PR-2 (issue #375): resolve before deriving.
                let boardTasksOnBoard = PlacementIntegrity.resolvedRows(
                    boardId: boardId, in: allBoardTasksPost, boardSize: board.boardSize
                )
                let update = DerivationPass.computeBoardStatsUpdate(
                    board: board,
                    boardTasksOnBoard: boardTasksOnBoard,
                    childrenByCompound: childrenByCompound,
                    taskById: taskById,
                    allBoards: allBoards,
                    windowContext: windowContext
                )

                let totalSquares = board.boardSize * board.boardSize
                let isGreenlogNow = update.completedTasks >= totalSquares

                board.completedTasks = update.completedTasks
                board.totalTasks = totalSquares
                board.linesCompleted = update.linesCompleted
                board.completedLineIds = update.completedLineIds.isEmpty ? nil : update.completedLineIds
                board.updatedAt = now
                board.version += 1

                if isGreenlogNow, board.status == .active {
                    board.status = .completed
                    board.completedAt = now
                } else if !isGreenlogNow, board.status == .completed {
                    board.status = .active
                    board.completedAt = nil
                }

                try board.save(db)
                try SyncQueueBuilder.makeItem(
                    entityType: "boards",
                    entityId: boardId,
                    operationType: .update,
                    payload: board,
                    now: now
                ).enqueue(db)
            }
        }
    }

}
