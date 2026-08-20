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
    /// `PoolMix.resolveMix` callers (spawn path, wizard template-mix
    /// hydration) that already have a set of referenced task ids and need
    /// a `tasksById` lookup. Mirrors `fetchBoards(ids:)`.
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

    /// The completion intent a board-context tap expresses (Windowed Completion,
    /// docs §Write paths). Mirrors web `handleTaskCompletion`'s
    /// `{ isCompleted?, currentCount? }` shape: the tap describes the DESIRED
    /// windowed state, and `completeTaskOrchestrated` turns it into a TaskEvent
    /// append (never a direct cache mutation).
    enum CompletionIntent {
        /// Normal square toggle — desired windowed completed state.
        case setCompleted(Bool)
        /// Counting square — desired NEW windowed count (the grid derives the
        /// current windowed count from `resolveTaskWindowState`, so the DB layer
        /// appends `desired − currentWindowedCount` as the event delta).
        case setWindowedCount(Int)
    }

    /// Runs the full task-completion orchestration in a single DB write
    /// transaction: draft auto-activate + TaskEvent append + cache stamp +
    /// BoardTask placement bump + windowed cross-board cascade — all sync-enqueued.
    ///
    /// Windowed Completion (docs §Write paths): a board-context tap writes a
    /// TaskEvent (not the lifetime cache). The event choke points append the
    /// row, restamp the lifetime caches (authored — bump `Task.version`, enqueue
    /// the Task sync entry), all inside THIS transaction. The event's window is
    /// `board.startDate`, so completing/incrementing counts only for boards
    /// whose window contains `now`.
    ///
    /// - Parameters:
    ///   - board: The current board (its `.draft` → `.active` flip happens here).
    ///   - taskId: The event-owning Task the user tapped (normal or plain/source
    ///     counting).
    ///   - intent: The desired windowed state (see `CompletionIntent`).
    ///   - boardTask: The `BoardTask` placement record on the current board
    ///     (its `updatedAt`/`version` are bumped + sync-queued).
    ///   - now: ISO8601 timestamp stamped on every row written here.
    /// - Returns: A `[boardId: CascadeBoardResult]` map for flash derivation.
    func completeTaskOrchestrated(
        board: Board,
        taskId: String,
        intent: CompletionIntent,
        boardTask: BoardTask,
        now: String
    ) throws -> [String: CascadeBoardResult] {
        try write { db in
            // 1. Auto-activate DRAFT boards on first interaction.
            if board.status == .draft {
                var activated = board
                activated.status = .active
                // Windowed Completion — stamp the activation instant (only if
                // not already set) so the auto-seal backstop keys off
                // max(endDate, activatedAt): a draft activated after its window
                // expired gets a full prompt cycle (docs §Sealing → backstop).
                if activated.activatedAt == nil { activated.activatedAt = now }
                activated.updatedAt = now
                activated.version += 1
                try activated.save(db)
            }

            // 2a. Apply the intent via the event choke points. They append the
            //     TaskEvent, restamp lifetime caches (bump Task.version, enqueue
            //     the Task UPDATE), all in THIS transaction.
            let windowStart = board.startDate
            switch intent {
            case .setCompleted(let desired):
                if desired {
                    try Self.appendCompletionEvent(db: db, taskId: taskId, boardId: board.id, now: now)
                } else {
                    try Self.tombstoneWindowCompletions(db: db, taskId: taskId, windowStart: windowStart, now: now)
                }
            case .setWindowedCount(let desired):
                let windowedCount = try Self.windowedState(db: db, taskId: taskId, windowStart: windowStart).count
                var delta = desired - windowedCount
                // Gate a decrement so the window sum stays ≥ 0 (belt against a
                // local gesture poisoning the window with a dangling negative).
                if delta < 0 { delta = max(delta, -windowedCount) }
                if delta != 0 {
                    try Self.appendIncrementEvent(db: db, taskId: taskId, delta: delta, boardId: board.id, now: now)
                }
            }

            // 2b. Bump the BoardTask placement record's updatedAt/version.
            var updatedBoardTask = boardTask
            updatedBoardTask.updatedAt = now
            updatedBoardTask.version += 1
            try updatedBoardTask.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "boardTasks",
                entityId: updatedBoardTask.id,
                operationType: .update,
                payload: updatedBoardTask,
                now: now
            ).enqueue(db)

            // 3. Windowed cross-board cascade: rebuilds bingo state, applies
            //    GREENLOG transitions, persists every affected board, and returns
            //    the per-board results for the caller's flash message.
            return try Self.runBoardCascadeForTaskWithResults(
                db: db,
                changedTaskId: taskId,
                now: now
            )
        }
    }

    /// Fallback compound-child toggle write: the child isn't placed on the
    /// current board, but a parent compound (or the child via another board)
    /// may be — so we append the child's TaskEvent (window-scoped to the host
    /// board), then run the windowed cross-board cascade.
    ///
    /// Windowed Completion (docs §Write paths): the child's completion is scoped
    /// to the host board's window (`windowStart`). Complete → append a completion
    /// event; un-complete → window-scoped tombstone of the host window's
    /// completions.
    ///
    /// - Parameters:
    ///   - childTaskId: The event-owning child Task being toggled.
    ///   - desiredCompleted: The desired windowed completed state.
    ///   - windowStart: The host board's `startDate` (window lower bound).
    ///   - boardId: The host board id (event provenance).
    ///   - now: ISO8601 timestamp stamped on every row written here.
    /// - Returns: A `[boardId: CascadeBoardResult]` map for flash derivation.
    func toggleCompoundChildFallback(
        childTaskId: String,
        desiredCompleted: Bool,
        windowStart: String,
        boardId: String?,
        now: String
    ) throws -> [String: CascadeBoardResult] {
        try write { db in
            if desiredCompleted {
                try Self.appendCompletionEvent(db: db, taskId: childTaskId, boardId: boardId, now: now)
            } else {
                try Self.tombstoneWindowCompletions(db: db, taskId: childTaskId, windowStart: windowStart, now: now)
            }

            return try Self.runBoardCascadeForTaskWithResults(
                db: db,
                changedTaskId: childTaskId,
                now: now
            )
        }
    }

    /// Create a single Task + enqueue its `.create` sync op atomically.
    /// Used by the standalone quick-add / derive-counter paths (Tasks tab
    /// create form, Riso library sheet, From-a-board grid) that previously
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

    // MARK: - Copy-from-source helpers
    //
    // The wizard's `From a board…` filter long-press menu exposes
    // `⎘ Add a copy of this task…`. The Copy modal collects per-type
    // editable fields, pre-filled from the source. These helpers
    // construct the new Task value, persist it + its compound children
    // (when applicable), and enqueue the sync write — all atomically.
    // iOS twin of web's `copyTask` / `copyCompound` in
    // `apps/web/src/db/operations/tasks.ts`. See
    // docs/ARCHITECTURE.md § "Wizard 'From a board' picker" for the
    // shallow-compound-copy invariant. Achievement copies are NOT
    // cycle-checked here — the gate runs at wizard-commit time when
    // the Task is placed on the new board (Phase 6.3 behavior).

    /// Editable fields the Copy sheet may override when copying a
    /// primitive (normal / counting / achievement) task. Any property
    /// left `nil` inherits from the source.
    ///
    /// For achievement copies: if EITHER `referencedBoardId` or
    /// `referencedTemplateId` is provided, both override values are
    /// used as-is (treating the other's `nil` as "clear"). This is
    /// how the sheet switches between specific-board and
    /// recurring-template modes. If neither is provided, both
    /// inherit from the source.
    struct CopyTaskOverrides {
        var title: String?
        var description: String?
        // Counting
        var action: String?
        var unit: String?
        var maxCount: Int?
        // Achievement
        var achievementTrigger: AchievementTrigger?
        var referencedBoardId: String?
        var referencedTemplateId: String?
        var requiredCount: Int?

        init(
            title: String? = nil,
            description: String? = nil,
            action: String? = nil,
            unit: String? = nil,
            maxCount: Int? = nil,
            achievementTrigger: AchievementTrigger? = nil,
            referencedBoardId: String? = nil,
            referencedTemplateId: String? = nil,
            requiredCount: Int? = nil,
            overrodeReference: Bool = false
        ) {
            self.title = title
            self.description = description
            self.action = action
            self.unit = unit
            self.maxCount = maxCount
            self.achievementTrigger = achievementTrigger
            self.referencedBoardId = referencedBoardId
            self.referencedTemplateId = referencedTemplateId
            self.requiredCount = requiredCount
            self.overrodeReference = overrodeReference
        }

        /// True when the sheet touched the reference fields. Distinguishes
        /// "inherit from source" (false → use source's pair) from
        /// "user picked board mode but left template blank" (true → use
        /// overrides as-is, blanks become clears). Swift can't infer this
        /// from `nil` alone the way TS infers from `=== undefined`.
        var overrodeReference: Bool = false
    }

    /// Copy a primitive task (normal / counting / achievement). Throws
    /// if the source is a compound — call `copyCompound` instead.
    @discardableResult
    func copyTask(
        userId: String,
        source: Task,
        overrides: CopyTaskOverrides = CopyTaskOverrides()
    ) throws -> Task {
        if source.type == .compound {
            throw NSError(
                domain: "AppDatabase.copyTask",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "copyTask cannot copy a compound source — use copyCompound instead"]
            )
        }

        let now = Self.currentTimestamp()
        let newId = Self.generateUUID()

        // Resolve reference fields: if the sheet touched either field,
        // both come from overrides (nil-as-clear so a switch from
        // board → template doesn't leave both set and trip the XOR
        // refinement). Otherwise inherit from the source.
        let refBoard: String? = overrides.overrodeReference
            ? overrides.referencedBoardId
            : source.referencedBoardId
        let refTemplate: String? = overrides.overrodeReference
            ? overrides.referencedTemplateId
            : source.referencedTemplateId

        let newTask = Task(
            id: newId,
            userId: userId,
            title: overrides.title ?? source.title,
            description: overrides.description ?? source.description,
            type: source.type,
            action: source.type == .counting
                ? (overrides.action ?? source.action) : nil,
            unit: source.type == .counting
                ? (overrides.unit ?? source.unit) : nil,
            maxCount: source.type == .counting
                ? (overrides.maxCount ?? source.maxCount) : nil,
            referencedBoardId: source.type == .achievement ? refBoard : nil,
            referencedTemplateId: source.type == .achievement ? refTemplate : nil,
            achievementTrigger: source.type == .achievement
                ? (overrides.achievementTrigger ?? source.achievementTrigger) : nil,
            requiredCount: source.type == .achievement
                ? (overrides.requiredCount ?? source.requiredCount) : nil,
            totalCompletions: 0,
            totalInstances: 0,
            isCompleted: false,
            currentCount: source.type == .counting ? 0 : nil,
            createdAt: now,
            updatedAt: now,
            version: 1,
            isDeleted: false,
            timeframe: source.timeframe,
            startDate: source.startDate,
            endDate: source.endDate
        )

        try write { db in
            try newTask.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "tasks",
                entityId: newId,
                operationType: .create,
                payload: newTask,
                now: now
            ).enqueue(db)
        }
        return newTask
    }

    /// Copy a compound task. Shallow: the new compound parent has a
    /// fresh id but its `compound_children` rows reference the SAME
    /// primitive child Tasks the source had. Deep-clone is intentionally
    /// not provided (see ARCHITECTURE.md doc).
    @discardableResult
    func copyCompound(
        userId: String,
        source: Task,
        title: String? = nil,
        description: String? = nil
    ) throws -> Task {
        guard source.type == .compound else {
            throw NSError(
                domain: "AppDatabase.copyCompound",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "copyCompound requires a compound source task"]
            )
        }
        guard let op = source.operatorType else {
            throw NSError(
                domain: "AppDatabase.copyCompound",
                code: 2,
                userInfo: [NSLocalizedDescriptionKey:
                    "compound source missing operatorType field"]
            )
        }
        let now = Self.currentTimestamp()
        let newParentId = Self.generateUUID()

        let newParent = Task(
            id: newParentId,
            userId: userId,
            title: title ?? source.title,
            description: description ?? source.description,
            type: .compound,
            operatorType: op,
            threshold: source.threshold,
            totalCompletions: 0,
            totalInstances: 0,
            isCompleted: false,
            createdAt: now,
            updatedAt: now,
            version: 1,
            isDeleted: false,
            timeframe: source.timeframe,
            startDate: source.startDate,
            endDate: source.endDate
        )

        // Read children OUTSIDE the write transaction so we don't hold a
        // writer lock open across the read. `fetchCompoundChildren`
        // already filters !isDeleted and orders by childIndex.
        let sourceChildren = try fetchCompoundChildren(compoundTaskId: source.id)

        try write { db in
            try newParent.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "tasks",
                entityId: newParentId,
                operationType: .create,
                payload: newParent,
                now: now
            ).enqueue(db)

            for (index, child) in sourceChildren.enumerated() {
                let linkId = Self.generateUUID()
                let link = CompoundChild(
                    id: linkId,
                    compoundTaskId: newParentId,
                    childTaskId: child.childTaskId,
                    childIndex: index,
                    createdAt: now,
                    updatedAt: now,
                    lastSyncedAt: nil,
                    version: 1,
                    isDeleted: false,
                    deletedAt: nil
                )
                try link.save(db)
                try SyncQueueBuilder.makeItem(
                    entityType: "compoundChildren",
                    entityId: linkId,
                    operationType: .create,
                    payload: link,
                    now: now
                ).enqueue(db)
            }
        }

        return newParent
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
        /// P5 decision 8 — live (non-deleted) tasks whose `sharedCounterId`
        /// points at this task, i.e. this task is a counter SOURCE with
        /// derived members. Deleting a source unlinks these (see
        /// `deleteCounterWithUnlink` in `AppDatabase+Counters.swift`) rather
        /// than orphaning them, so the confirm dialog surfaces this count
        /// separately from the ordinary board/compound impact above.
        let counterMemberCount: Int
        /// The counter-member Task rows themselves (same set counted by
        /// `counterMemberCount`), so the confirm sheet can list them without
        /// a second fetch.
        let counterMembers: [Task]
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
            let counterMembers = try Task
                .filter(Column("sharedCounterId") == taskId && Column("isDeleted") == false)
                .fetchAll(db)
            return TaskDeletionImpact(
                boardTaskCount: visiblePlacements.count,
                affectedBoardIds: Array(liveBoardIds),
                affectedBoards: liveBoards,
                childLinkCount: childLinks,
                parentLinkCount: parentLinks,
                counterMemberCount: counterMembers.count,
                counterMembers: counterMembers,
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
    static func deleteTaskWithCascadeInDb(db: Database, taskId: String, now: String) throws {
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
        let affectedBoardIdsForDeletion = DerivationPass.findAffectedBoardIds(
            changedTaskId: taskId,
            parentCompounds: parentCompoundsForDeletion,
            boardTasks: allBoardTasksPreDelete
        )

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
