import Foundation
import GRDB

extension AppDatabase {
    // MARK: - Phase 3 / P2: Shared-counter engine

    /// Identifies a live ACTIVE board that holds a member task (source or linked)
    /// of the shared-counter group. Returned by `incrementSharedCounter` and
    /// `decrementSharedCounter` so callers can show a credited toast.
    struct AffectedBoard: Equatable {
        let boardId: String
        let boardName: String
    }

    /// Result returned by `incrementSharedCounter` (P2).
    /// Contains the distinct ACTIVE boards that hold any member task of the group
    /// (source + linked). Callers filter out their current board to derive
    /// "also counts on …" copy for the credited toast.
    struct SharedCounterCreditResult {
        /// ACTIVE boards (not deleted, status == .active) that contain any member
        /// task of this counter group. Ordered stably by board id.
        let affectedBoards: [AffectedBoard]
    }

    /// Result returned by `decrementSharedCounter` (P2). Extends with the
    /// effective delta actually applied (0 = no-op because source was already 0).
    struct SharedCounterDecrementResult {
        let affectedBoards: [AffectedBoard]
        /// Actual amount decremented. 0 when `source.currentCount` was already 0
        /// before the call (silent no-op per the spec's clamp rule).
        let effectiveDelta: CountValue
    }

    // MARK: Private helper — shared-counter board cascade

    /// The tail of increment / decrement / undo: the root's event log just
    /// moved. Every live linked row resolves from those events on its board
    /// (TASK_WINDOW_REWORK slice 5 — nothing is written to a linked row), so
    /// this runs ONE board derivation cascade over the root's placement reach
    /// (`placementReach`: the root plus its live linked rows) inside an
    /// existing write transaction, and returns the distinct ACTIVE boards that
    /// place the root or a linked row DIRECTLY. Twin of web
    /// `runCounterRootCascade`.
    ///
    /// - Parameters:
    ///   - db: The open GRDB `Database` handle (must be inside a write transaction).
    ///   - sourceTaskId: The shared-counter root whose events just moved.
    ///   - now: The current ISO8601 timestamp.
    ///   - lateLogStamp: The `occurredAt` of the event written, when known; a
    ///     stamp other than `now` re-derives the sealed boards that may hold it.
    /// - Returns: ACTIVE `AffectedBoard` entries for the credit toast.
    private func runSharedCounterCascade(
        db: Database,
        sourceTaskId: String,
        now: String,
        lateLogStamp: String? = nil
    ) throws -> [AffectedBoard] {
        // ONE fetch of the structure (tasks, live links, live placements) feeds both the reach and
        // the derivation below — the reach used to refetch all three through `placementReach`.
        // Links and placements are not touched by the counts-toward pass, so they stay valid.
        var allTasksWS: [Task] = try Task.fetchAll(db)
        let allChildren: [CompoundChild] = try CompoundChild
            .filter(Column("isDeleted") == false)
            .fetchAll(db)
        let allBoardTasks: [BoardTask] = try BoardTask
            .filter(Column("isDeleted") == false)
            .fetchAll(db)
        let reach = DerivationPass.placementsReachedByTasks(
            ids: [sourceTaskId], tasks: allTasksWS, compoundChildren: allChildren, boardTasks: allBoardTasks
        )
        let allChangedTaskIds = reach.taskIds.sorted()
        // "Counts toward" (docs/SHARED_COUNTER_SETTINGS.md §3b): a compound that
        // contains one of these copies may have just completed.
        let countsToward = try Self.writeCountsToward(db: db, changedTaskIds: allChangedTaskIds, now: now)
        // The pass restamps counter-root caches (task rows) — refetch only when it wrote something.
        if !countsToward.rootIds.isEmpty { allTasksWS = try Task.fetchAll(db) }
        let allBoards: [Board] = try Board.fetchAll(db)
        var boardById: [String: Board] = [:]
        for b in allBoards { boardById[b.id] = b }
        // Windowed Completion — the source counting square is event-owning, so
        // its board reads are windowed; the cascade must evaluate with the event
        // context (docs §Sync). Linked squares resolve from the root's events.
        let windowContext = try Self.buildWindowContext(db: db)

        var taskById: [String: Task] = [:]
        for t in allTasksWS { taskById[t.id] = t }
        var childrenByCompound: [String: [CompoundChild]] = [:]
        for c in allChildren {
            childrenByCompound[c.compoundTaskId, default: []].append(c)
        }

        // Collect all cascade-affected board ids.
        var allAffectedBoardIds = Set<String>()
        for taskId in allChangedTaskIds + countsToward.cascadeIds.sorted() {
            let parentCompounds = DerivationPass.findTransitiveParentCompounds(
                changedTaskId: taskId,
                children: allChildren
            )
            let boardIds = DerivationPass.findAffectedBoardIds(
                changedTaskId: taskId,
                parentCompounds: parentCompounds,
                boardTasks: allBoardTasks
            )
            allAffectedBoardIds.formUnion(boardIds)
        }

        for boardId in allAffectedBoardIds {
            guard var board = try Board.fetchOne(db, key: boardId), !board.isDeleted, board.sealedAt == nil else {
                continue
            }
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

            // Compare-before-write (sync-churn fix): a no-op derivation never bumps or re-pushes.
            let storedBoard = board
            board.applyDerivedStats(update, now: now)
            guard board.derivedStateDiffers(from: storedBoard) else { continue }
            board.updatedAt = now
            board.version += 1
            try board.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "boards",
                entityId: boardId,
                operationType: .update,
                payload: board,
                now: now
            ).enqueue(db)
        }

        try Self.finishCountsTowardRoots(db: db, rootIds: countsToward.rootIds, now: now)

        // One late-log tail (TASK_WINDOW_REWORK slice 0): an event stamped at an
        // ended board's `endDate` (`lateLogStamp != now`) can land inside a
        // SEALED containing board's window (a closed weekly around an ended
        // daily). The live loop above skips sealed boards and only the pull
        // path on the OTHER device re-derived them — so the sealed record
        // diverged across devices. Re-derive them here and refresh watchers,
        // exactly as `reDeriveAfterLateLogWrite` does for undo.
        if let lateLogStamp, lateLogStamp != now {
            let reached = Set(allChangedTaskIds).union(countsToward.cascadeIds)
            try Self.reDeriveSealedBoards(db: db, changedTaskIds: reached)
            try Self.refreshWatchersForBoards(db: db, changedBoardIds: allAffectedBoardIds, now: now)
        }

        // Build the credit-toast result: boards that can still count a log
        // (live, active, not closed, not ended) holding any member task.
        let memberTaskIdSet = Set(allChangedTaskIds)
        var seenBoardIds = Set<String>()
        var creditBoards: [AffectedBoard] = []
        for bt in allBoardTasks {
            guard memberTaskIdSet.contains(bt.taskId),
                  let board = boardById[bt.boardId],
                  Self.boardCanStillCountLogs(board, now: now),
                  !seenBoardIds.contains(board.id)
            else { continue }
            seenBoardIds.insert(board.id)
            creditBoards.append(AffectedBoard(boardId: board.id, boardName: board.displayName))
        }
        // Stable order by board id.
        creditBoards.sort { $0.boardId < $1.boardId }
        return creditBoards
    }

    /// Increment the shared-counter source task's `currentCount` by `by` (default 1),
    /// append the increment event, and run ONE board derivation cascade over the
    /// source's placement reach (the source and its live linked rows, which resolve
    /// from the source's events) — all inside a single GRDB write transaction. An
    /// increment writes the root alone: no linked-row write, no sync item for a copy.
    ///
    /// Invariants enforced:
    ///   - NO HIGH-END CLAMP on the source `currentCount`. Overshoot is intentional.
    ///   - All writes (task rows + board cascade + sync entries) are atomic.
    ///
    /// The caller (BoardPlayView) calls this instead of the legacy
    /// `handleCountingTap` when the task being tapped has `sharedCounterId != nil`
    /// (linked task → increment source) OR when the task is a known source
    /// (has linked tasks pointing at it → increment source + fan-out).
    ///
    /// IMPORTANT: Uses `_Concurrency.Task` explicitly to avoid shadowing by the
    /// GRDB `Task` model. This function itself is synchronous (throws); callers
    /// wrap it in `_Concurrency.Task.detached` for off-main-thread execution.
    ///
    /// - Parameters:
    ///   - sourceTaskId: The id of the source (template) counting task.
    ///   - by: Amount to increment. Must be a positive 2dp number.
    ///   - boardId: The board whose OWN play surface made the log, if any.
    ///     When given, the event is stamped with that board's late-log stamp
    ///     (`lateLogStampForBoard` — its `endDate` once its window has ended,
    ///     2026-09-24 amendment); omitted (hub / counter detail) → `now`. Only
    ///     `BoardPlayViewModel` passes it. Event provenance `boardId` stays
    ///     `nil`, as before — only `occurredAt` is clamped. A SEALED board is
    ///     a full no-op (no event, no write) — a sealed board authors no event.
    ///   - now: The operation's ISO8601 clock (injectable for tests).
    /// - Returns: `SharedCounterCreditResult` with the boards that can still
    ///   count the log (live, active, not closed, not ended), for use in the P2 "credited" toast.
    func incrementSharedCounter(
        sourceTaskId: String,
        by: CountValue = 1,
        boardId: String? = nil,
        now: String = AppDatabase.currentTimestamp()
    ) throws -> SharedCounterCreditResult {
        guard isQuantizedCount(by) && by > 0 else {
            throw NSError(
                domain: "AppDatabase.incrementSharedCounter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "incrementSharedCounter: `by` must be a positive 2dp number"]
            )
        }

        return try write { db in
            // 1. Fetch and validate the source task.
            guard var source = try Task.fetchOne(db, key: sourceTaskId) else {
                return SharedCounterCreditResult(affectedBoards: [])
            }
            // Soft-delete guard: a deleted source must not be incremented or synced.
            guard !source.isDeleted else { return SharedCounterCreditResult(affectedBoards: []) }
            guard source.type == .counting else {
                throw NSError(
                    domain: "AppDatabase.incrementSharedCounter",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey:
                        "incrementSharedCounter: source task \(sourceTaskId) is not a COUNTING task"]
                )
            }
            guard source.sharedCounterId == nil else {
                throw NSError(
                    domain: "AppDatabase.incrementSharedCounter",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey:
                        "incrementSharedCounter: task \(sourceTaskId) is a linked derived counter; pass the source (template) task id instead"]
                )
            }

            // Final-review F5: a SEALED board authors no event (play is
            // locked; its record is permanent). Mirrors the sealed no-op in
            // `completeTaskOrchestrated`. Web twin: `incrementSharedCounter`.
            let logBoard = try boardId.flatMap { try Board.fetchOne(db, key: $0) }
            if logBoard?.sealedAt != nil { return SharedCounterCreditResult(affectedBoards: []) }

            // 2. Compute new source count — NO high-end clamp.
            // P5: `maxCount` may be nil for a goal-less (hub-born) source —
            // a running tally with no threshold. Such a source must never
            // auto-complete (there is nothing to reach).
            let sourceMaxCount = source.maxCount
            let prevSourceCount = source.currentCount ?? 0
            let newSourceCount = quantizeCount(prevSourceCount + by)

            // ONE-WAY LATCH on source completion. Goal-less sources
            // (sourceMaxCount == nil) never latch complete.
            let sourceWasCompleted = source.isCompleted
            let sourceNowCompleted = sourceWasCompleted || (sourceMaxCount.map { newSourceCount >= $0 } ?? false)

            source.currentCount = newSourceCount
            source.isCompleted = sourceNowCompleted
            if !sourceWasCompleted && sourceNowCompleted {
                source.completedAt = now
            }
            source.updatedAt = now
            source.version += 1
            try source.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "tasks",
                entityId: sourceTaskId,
                operationType: .update,
                payload: source,
                now: now
            ).enqueue(db)

            // Windowed Completion — append a +by increment event on the SOURCE
            // only (linked rows never own events; they resolve from the
            // source's). RAW: no cache restamp — the engine already wrote
            // `source.currentCount` authoritatively above (provably == lifetime
            // event sum), so a restamp would double-bump the version. The event
            // is what makes windowed board reads of the source square correct.
            // Stamped `lateLogStampForBoard(boardId, now)` (2026-09-24 amendment).
            // Mirrors `insertIncrementEventRaw(sourceTaskId, by, undefined, now, occurredAt)`.
            let occurredAt = try Self.lateLogStampForBoard(db: db, boardId: boardId, now: now)
            try Self.insertIncrementEventRaw(
                db: db, taskId: sourceTaskId, delta: by, boardId: nil, now: now, occurredAt: occurredAt
            )

            // 3. Collect credited boards and run ONE batched board cascade.
            let creditBoards = try runSharedCounterCascade(
                db: db, sourceTaskId: sourceTaskId, now: now, lateLogStamp: occurredAt
            )
            return SharedCounterCreditResult(affectedBoards: creditBoards)
        }
    }

    /// Decrement the shared-counter source task's `currentCount` by `by` (default 1),
    /// then re-derive every linked task and run the board cascade — all atomic.
    ///
    /// Invariants:
    ///   - CLAMP: `eff = min(by, source.currentCount)`. If `eff == 0`, no-op.
    ///   - ONE-WAY COMPLETION LATCH: decrement NEVER un-completes any task.
    ///     Once `isCompleted = true`, it stays `true`.
    ///   - The source must be a COUNTING task with `sharedCounterId == nil`
    ///     (i.e. the source, not a linked task). Throw otherwise.
    ///   - All writes are atomic in a single GRDB write transaction.
    ///
    /// - Parameters:
    ///   - sourceTaskId: The id of the source (template) counting task.
    ///   - by: Amount to decrement. Must be a positive 2dp number.
    ///   - boardId: The board whose OWN play surface made the log, if any —
    ///     the event is stamped with its late-log stamp (see
    ///     `incrementSharedCounter`); omitted → `now`. A SEALED board is a
    ///     full no-op; otherwise `eff` is clamped to that board's WINDOW count
    ///     (`[startDate, endDate]`), not just the lifetime count.
    /// - Returns: `SharedCounterDecrementResult` with affected boards and the
    ///   actual delta applied (0 on no-op).
    func decrementSharedCounter(
        sourceTaskId: String,
        by: CountValue = 1,
        boardId: String? = nil
    ) throws -> SharedCounterDecrementResult {
        guard isQuantizedCount(by) && by > 0 else {
            throw NSError(
                domain: "AppDatabase.decrementSharedCounter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "decrementSharedCounter: `by` must be a positive 2dp number"]
            )
        }

        return try write { db in
            let now = Self.currentTimestamp()

            // 1. Fetch and validate the source task.
            guard var source = try Task.fetchOne(db, key: sourceTaskId) else {
                return SharedCounterDecrementResult(affectedBoards: [], effectiveDelta: 0)
            }
            guard !source.isDeleted else {
                return SharedCounterDecrementResult(affectedBoards: [], effectiveDelta: 0)
            }
            guard source.type == .counting else {
                throw NSError(
                    domain: "AppDatabase.decrementSharedCounter",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey:
                        "decrementSharedCounter: source task \(sourceTaskId) is not a COUNTING task"]
                )
            }
            guard source.sharedCounterId == nil else {
                throw NSError(
                    domain: "AppDatabase.decrementSharedCounter",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey:
                        "decrementSharedCounter: task \(sourceTaskId) is a linked derived counter; pass the source (template) task id instead"]
                )
            }

            // Final-review F5: a SEALED board authors no event (play is
            // locked; its record is permanent). Web twin: `decrementSharedCounter`.
            let logBoard = try boardId.flatMap { try Board.fetchOne(db, key: $0) }
            if logBoard?.sealedAt != nil {
                return SharedCounterDecrementResult(affectedBoards: [], effectiveDelta: 0)
            }

            // 2. Clamp: eff = min(by, available). No-op if 0.
            // Final-review F6: from a board, `available` is that board's
            // WINDOW count (`[startDate, endDate]`, what its cell shows) — the
            // negative event is stamped inside that window, so taking more
            // than the window holds would bleed into overlapping windows (e.g.
            // the monthly containing that day). Still capped by the lifetime
            // count so the lifetime sum stays >= 0.
            let sourceCurrentCount = source.currentCount ?? 0
            var available = sourceCurrentCount
            if let logBoard {
                let events = try TaskEvent
                    .filter(Column("taskId") == sourceTaskId)
                    .fetchAll(db)
                    .filter { !$0.isDeleted }
                let windowCount = resolveTaskWindowState(
                    task: source,
                    events: events,
                    windowStart: logBoard.startDate,
                    windowEnd: boardWindowEnd(logBoard)
                ).count
                available = min(sourceCurrentCount, max(0, windowCount))
            }
            let eff = min(by, available)
            guard eff > 0 else {
                return SharedCounterDecrementResult(affectedBoards: [], effectiveDelta: 0)
            }
            let newSourceCount = quantizeCount(sourceCurrentCount - eff)

            // ONE-WAY LATCH: decrement NEVER un-completes the source.
            source.currentCount = newSourceCount
            // isCompleted and completedAt unchanged — latch preserved.
            source.updatedAt = now
            source.version += 1
            try source.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "tasks",
                entityId: sourceTaskId,
                operationType: .update,
                payload: source,
                now: now
            ).enqueue(db)

            // Windowed Completion — append a -eff increment event on the SOURCE
            // only (board-context decrement: a signed negative delta, gated by
            // the window/lifetime clamp above so neither sum can go negative). RAW: no cache restamp — the engine wrote
            // `source.currentCount` authoritatively. Mirrors
            // `insertIncrementEventRaw(sourceTaskId, -eff, undefined, now)`.
            let occurredAt = try Self.lateLogStampForBoard(db: db, boardId: boardId, now: now)
            try Self.insertIncrementEventRaw(
                db: db, taskId: sourceTaskId, delta: -eff, boardId: nil, now: now, occurredAt: occurredAt
            )

            // 4. Collect credited boards and run ONE batched board cascade.
            let creditBoards = try runSharedCounterCascade(
                db: db, sourceTaskId: sourceTaskId, now: now, lateLogStamp: occurredAt
            )
            return SharedCounterDecrementResult(affectedBoards: creditBoards, effectiveDelta: eff)
        }
    }

    // MARK: - R2 Counters UX refresh: Undo + default log amount

    /// Result returned by `undoLastCounterLog`.
    struct UndoCounterLogResult {
        /// Distinct live ACTIVE boards containing any changed member task.
        let affectedBoards: [AffectedBoard]
        /// Absolute amount reversed (the tombstoned event's `|delta|`), or
        /// `0` when there was nothing to undo (no live increment event on
        /// the source).
        let undoneAmount: CountValue
    }

    /// Reverses the most recent counter log on a source task (R2 Counters UX
    /// refresh — the "Logged +N · Undo" toast).
    ///
    /// `incrementSharedCounter`/`decrementSharedCounter` append their event
    /// via `insertIncrementEventRaw`, which deliberately SKIPS the cache
    /// restamp (`stampTaskCachesAuthored`) — the source's `currentCount` is
    /// already written authoritatively by their own arithmetic, and a
    /// restamp would double-bump `version`. That means reversing a logged
    /// entry is NOT a bare tombstone: this function must also correct
    /// `currentCount` itself and re-run the cross-board cascade, mirroring
    /// `decrementSharedCounter`'s write shape but keyed to the specific
    /// event being undone (whose `delta` may itself be negative, if the
    /// entry being undone was a decrement) rather than a fresh negative event.
    ///
    /// Sequence:
    ///   1. `selectLastIncrementEntry` (pure) picks the most recent
    ///      non-deleted, non-seed increment event on the source.
    ///   2. Tombstone that event (`isDeleted`, bump version, enqueue DELETE).
    ///   3. `newCurrentCount = max(0, currentCount - entry.delta)` —
    ///      subtracting a positive delta reverses a log; subtracting a
    ///      negative delta (an undone decrement) adds the amount back. The
    ///      floor is defensive only: undoing the most-recent entry against
    ///      the count it produced never goes negative in practice.
    ///   4. ONE-WAY COMPLETION LATCH preserved, matching increment/decrement:
    ///      undo does not un-complete an already-completed source.
    ///   5. Re-run the board derivation cascade for the source + its live
    ///      linked rows, exactly like increment/decrement (linked rows are
    ///      never written).
    ///
    /// No-op (returns `undoneAmount == 0`) when the source is
    /// missing/deleted or has no undoable entry — callers should treat that
    /// as "Undo is no longer available" (e.g. the toast already dismissed
    /// after a second log elsewhere).
    ///
    /// - Parameter sourceTaskId: The id of the source (template) task whose
    ///   last log entry to reverse. Must NOT be a linked/derived task.
    func undoLastCounterLog(sourceTaskId: String) throws -> UndoCounterLogResult {
        try write { db in
            let now = Self.currentTimestamp()

            // 1. Fetch and validate the source task.
            guard var source = try Task.fetchOne(db, key: sourceTaskId) else {
                return UndoCounterLogResult(affectedBoards: [], undoneAmount: 0)
            }
            guard !source.isDeleted else {
                return UndoCounterLogResult(affectedBoards: [], undoneAmount: 0)
            }
            guard source.type == .counting else {
                throw NSError(
                    domain: "AppDatabase.undoLastCounterLog",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey:
                        "undoLastCounterLog: source task \(sourceTaskId) is not a COUNTING task"]
                )
            }
            guard source.sharedCounterId == nil else {
                throw NSError(
                    domain: "AppDatabase.undoLastCounterLog",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey:
                        "undoLastCounterLog: task \(sourceTaskId) is a linked derived counter; pass the source (template) task id instead"]
                )
            }

            // 2. Find the entry to reverse.
            let events = try TaskEvent.filter(Column("taskId") == sourceTaskId).fetchAll(db)
            guard var entry = selectLastIncrementEntry(events: events, sourceTaskId: sourceTaskId) else {
                return UndoCounterLogResult(affectedBoards: [], undoneAmount: 0)
            }

            // Board Edit redesign slice 4 (D9/D10) — refuse to tombstone a
            // seal-immune entry (frozen history; a closed-board late log is
            // excluded by `isEventSealImmune` itself). Web twin:
            // `undoLastCounterLog` in tasks.sharedCounter.ts.
            let immuneWindows = try Self.sealImmuneWindows(db: db, taskId: sourceTaskId)
            if isEventSealImmune(entry, windows: immuneWindows) {
                return UndoCounterLogResult(affectedBoards: [], undoneAmount: 0)
            }

            // 3. Tombstone it.
            entry.isDeleted = true
            entry.deletedAt = now
            entry.updatedAt = now
            entry.version += 1
            try entry.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "taskEvents",
                entityId: entry.id,
                operationType: .delete,
                payload: entry,
                now: now
            ).enqueue(db)

            // 4. Correct the source's currentCount by subtracting the
            //    reversed entry's delta (raw-append bypassed the cache
            //    restamp — see docstring above).
            let entryDelta = entry.delta ?? 0
            let currentCount = source.currentCount ?? 0
            let newSourceCount = max(0, quantizeCount(currentCount - entryDelta))

            // 5. ONE-WAY LATCH: undo does not un-complete (mirrors increment/decrement).
            let sourceWasCompleted = source.isCompleted
            let sourceNowCompleted = sourceWasCompleted || (source.maxCount.map { newSourceCount >= $0 } ?? false)

            source.currentCount = newSourceCount
            source.isCompleted = sourceNowCompleted
            if !sourceWasCompleted && sourceNowCompleted {
                source.completedAt = now
            }
            source.updatedAt = now
            source.version += 1
            try source.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "tasks",
                entityId: sourceTaskId,
                operationType: .update,
                payload: source,
                now: now
            ).enqueue(db)

            // 6. Collect credited boards and run ONE batched board cascade.
            let creditBoards = try runSharedCounterCascade(
                db: db, sourceTaskId: sourceTaskId, now: now
            )

            // Board Edit redesign slice 4 (D9) — the undone entry may sit
            // inside a SEALED containing board's window (e.g. a late log on a
            // closed board): re-derive every sealed board placing the source
            // or a derived row (local-only), then refresh achievement
            // watchers of every board it reaches.
            try Self.reDeriveSealedBoards(db: db, changedTaskIds: [sourceTaskId])
            try Self.refreshWatchersForBoards(
                db: db,
                changedBoardIds: try Self.boardIdsReachedByTasks(db: db, taskIds: [sourceTaskId]),
                now: now
            )
            return UndoCounterLogResult(affectedBoards: creditBoards, undoneAmount: abs(entryDelta))
        }
    }

    /// Persists the amount a user just logged with as the counter's new
    /// default (R2 Counters UX refresh — "Default amount = last-used per
    /// counter, persisted"). A plain task-field update: version bump + sync
    /// enqueue, no event/cascade side effects (this never changes
    /// `currentCount`).
    ///
    /// No-op when the amount already matches the stored default (avoids a
    /// needless version bump / sync entry on every repeat log with the same
    /// amount).
    ///
    /// - Parameters:
    ///   - sourceTaskId: The counter's source task id. Must NOT be a
    ///     linked/derived task — `defaultLogAmount` is only meaningful on
    ///     the accumulator.
    ///   - amount: A positive 2dp number.
    func setCounterDefaultLogAmount(sourceTaskId: String, amount: CountValue) throws {
        guard isQuantizedCount(amount) && amount > 0 else {
            throw NSError(
                domain: "AppDatabase.setCounterDefaultLogAmount",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "setCounterDefaultLogAmount: amount must be a positive 2dp number"]
            )
        }

        try write { db in
            guard var source = try Task.fetchOne(db, key: sourceTaskId), !source.isDeleted else { return }
            guard source.type == .counting else {
                throw NSError(
                    domain: "AppDatabase.setCounterDefaultLogAmount",
                    code: 2,
                    userInfo: [NSLocalizedDescriptionKey:
                        "setCounterDefaultLogAmount: task \(sourceTaskId) is not a COUNTING task"]
                )
            }
            guard source.sharedCounterId == nil else {
                throw NSError(
                    domain: "AppDatabase.setCounterDefaultLogAmount",
                    code: 3,
                    userInfo: [NSLocalizedDescriptionKey:
                        "setCounterDefaultLogAmount: task \(sourceTaskId) is a linked derived counter; pass the source (template) task id instead"]
                )
            }
            guard source.defaultLogAmount != amount else { return }

            let now = Self.currentTimestamp()
            source.defaultLogAmount = amount
            source.updatedAt = now
            source.version += 1
            try source.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "tasks",
                entityId: sourceTaskId,
                operationType: .update,
                payload: source,
                now: now
            ).enqueue(db)
        }
    }

    /// Reads a counter's trailing daily totals (7-day sparkline + "Today"
    /// stat, R2 Counters UX refresh) — the source task's non-deleted
    /// `TaskEvent`s reduced via `deriveCounterDailyTotals`. Read-only.
    ///
    /// - Parameters:
    ///   - sourceTaskId: The counter's source task id.
    ///   - days: Trailing window size (inclusive of today).
    ///   - now: ISO8601 "now" — every day boundary is computed relative to this.
    func fetchCounterDailyTotals(sourceTaskId: String, days: Int, now: String) throws -> CounterDailyTotalsResult {
        try read { db in
            let events = try TaskEvent
                .filter(Column("taskId") == sourceTaskId && Column("isDeleted") == false)
                .fetchAll(db)
            return try deriveCounterDailyTotals(
                events: events,
                sourceTaskId: sourceTaskId,
                now: now,
                days: days,
                seedSentinel: TaskEvents.seedEventOccurredAt
            )
        }
    }
}
