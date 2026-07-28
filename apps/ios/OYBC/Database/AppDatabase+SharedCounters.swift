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
        let effectiveDelta: Int
    }

    // MARK: Private helper — shared-counter board cascade

    /// Runs the board derivation cascade for `allChangedTaskIds` inside an
    /// existing write transaction, then returns the distinct ACTIVE boards
    /// that contain any member task of the group. Extracted so increment and
    /// decrement share identical cascade + credit logic without duplication.
    ///
    /// - Parameters:
    ///   - db: The open GRDB `Database` handle (must be inside a write transaction).
    ///   - allChangedTaskIds: All task ids that were written in this transaction
    ///     (`[sourceTaskId] + linkedTasks.map { $0.id }`).
    ///   - now: The current ISO8601 timestamp (passed through for consistency).
    /// - Returns: ACTIVE `AffectedBoard` entries for the credit toast.
    private func runSharedCounterCascade(
        db: Database,
        allChangedTaskIds: [String],
        now: String
    ) throws -> [AffectedBoard] {
        let allTasksWS: [Task] = try Task.fetchAll(db)
        let allChildren: [CompoundChild] = try CompoundChild
            .filter(Column("isDeleted") == false)
            .fetchAll(db)
        let allBoardTasks: [BoardTask] = try BoardTask
            .filter(Column("isDeleted") == false)
            .fetchAll(db)
        let allBoards: [Board] = try Board.fetchAll(db)
        // Windowed Completion — the source counting square is event-owning, so
        // its board reads are windowed; the cascade must evaluate with the event
        // context (docs §Sync). Derived (linked) squares stay on their
        // propagation-stamped cache via the carve-out inside the kernel.
        let windowContext = try Self.buildWindowContext(db: db)

        var taskById: [String: Task] = [:]
        for t in allTasksWS { taskById[t.id] = t }
        var childrenByCompound: [String: [CompoundChild]] = [:]
        for c in allChildren {
            childrenByCompound[c.compoundTaskId, default: []].append(c)
        }

        // Collect all cascade-affected board ids.
        var allAffectedBoardIds = Set<String>()
        for taskId in allChangedTaskIds {
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
            let boardTasksOnBoard = allBoardTasks.filter { $0.boardId == boardId }
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

        // Build the credit-toast result: ACTIVE boards that hold any member task.
        let memberTaskIdSet = Set(allChangedTaskIds)
        var seenBoardIds = Set<String>()
        var creditBoards: [AffectedBoard] = []
        for bt in allBoardTasks {
            guard memberTaskIdSet.contains(bt.taskId),
                  let board = allBoards.first(where: { $0.id == bt.boardId }),
                  !board.isDeleted,
                  board.status == .active,
                  !seenBoardIds.contains(board.id)
            else { continue }
            seenBoardIds.insert(board.id)
            creditBoards.append(AffectedBoard(boardId: board.id, boardName: board.name))
        }
        // Stable order by board id.
        creditBoards.sort { $0.boardId < $1.boardId }
        return creditBoards
    }

    /// Increment the shared-counter source task's `currentCount` by `by` (default 1),
    /// then re-derive every linked task (tasks where `sharedCounterId == sourceTaskId`
    /// and `!isDeleted`) and run the board derivation cascade for the source AND
    /// every linked task — all inside a single GRDB write transaction.
    ///
    /// Invariants enforced:
    ///   - NO HIGH-END CLAMP on the source `currentCount`. Overshoot is intentional.
    ///   - ONE-WAY LATCH on each linked task's `isCompleted`: once `true`, stays `true`.
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
    ///   - by: Amount to increment. Must be >= 1.
    /// - Returns: `SharedCounterCreditResult` with the ACTIVE boards holding
    ///   any member task, for use in the P2 "credited" toast.
    func incrementSharedCounter(sourceTaskId: String, by: Int = 1) throws -> SharedCounterCreditResult {
        guard by >= 1 else {
            throw NSError(
                domain: "AppDatabase.incrementSharedCounter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "incrementSharedCounter: `by` must be >= 1"]
            )
        }

        return try write { db in
            let now = Self.currentTimestamp()

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

            // 2. Compute new source count — NO high-end clamp.
            // P5: `maxCount` may be nil for a goal-less (hub-born) source —
            // a running tally with no threshold. Such a source must never
            // auto-complete (there is nothing to reach).
            let sourceMaxCount = source.maxCount
            let prevSourceCount = source.currentCount ?? 0
            let newSourceCount = prevSourceCount + by

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
            // only (derived tasks are carved out; their state mirrors the source
            // via propagation). RAW: no cache restamp — the engine already wrote
            // `source.currentCount` authoritatively above (provably == lifetime
            // event sum), so a restamp would double-bump the version. The event
            // is what makes windowed board reads of the source square correct.
            // Mirrors `insertIncrementEventRaw(sourceTaskId, by, undefined, now)`.
            try Self.insertIncrementEventRaw(db: db, taskId: sourceTaskId, delta: by, boardId: nil, now: now)

            // 3. Fetch all linked (derived) tasks for this source.
            let linkedTasks = try Task
                .filter(Column("sharedCounterId") == sourceTaskId)
                .filter(Column("isDeleted") == false)
                .fetchAll(db)

            // 4. Re-derive each linked task via the shared propagation helper
            //    (mirrors `propagateIncrement` in sharedCounter.ts). The helper
            //    owns the derivation math + one-way latch; the DB layer owns the
            //    writes (completedAt, updatedAt, version, sync-queue).
            let propagation = propagateIncrement(
                sourceAfterCurrentCount: newSourceCount,
                linkedTasks: linkedTasks.map {
                    PropagateIncrementLinkedTask(
                        id: $0.id,
                        baseline: $0.baseline,
                        maxCount: $0.maxCount,
                        isCompleted: $0.isCompleted
                    )
                }
            )
            for (result, var linked) in zip(propagation, linkedTasks) {
                let linkedWasCompleted = linked.isCompleted

                linked.currentCount = result.newCurrentCount  // mirror source count for easy reads
                linked.isCompleted = result.newIsCompleted
                if !linkedWasCompleted && result.newIsCompleted {
                    linked.completedAt = now
                }
                linked.updatedAt = now
                linked.version += 1
                try linked.save(db)
                try SyncQueueBuilder.makeItem(
                    entityType: "tasks",
                    entityId: linked.id,
                    operationType: .update,
                    payload: linked,
                    now: now
                ).enqueue(db)
            }

            // 5. Board cascade + credit result.
            let allChangedTaskIds = [sourceTaskId] + linkedTasks.map { $0.id }
            let creditBoards = try runSharedCounterCascade(
                db: db,
                allChangedTaskIds: allChangedTaskIds,
                now: now
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
    ///   - by: Amount to decrement. Must be >= 1.
    /// - Returns: `SharedCounterDecrementResult` with affected boards and the
    ///   actual delta applied (0 on no-op).
    func decrementSharedCounter(sourceTaskId: String, by: Int = 1) throws -> SharedCounterDecrementResult {
        guard by >= 1 else {
            throw NSError(
                domain: "AppDatabase.decrementSharedCounter",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "decrementSharedCounter: `by` must be >= 1"]
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

            // 2. Clamp: eff = min(by, source.currentCount). No-op if 0.
            let sourceCurrentCount = source.currentCount ?? 0
            let eff = min(by, sourceCurrentCount)
            guard eff > 0 else {
                return SharedCounterDecrementResult(affectedBoards: [], effectiveDelta: 0)
            }
            let newSourceCount = sourceCurrentCount - eff

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
            // the `eff = min(by, currentCount)` clamp above so the lifetime sum
            // can't go negative). RAW: no cache restamp — the engine wrote
            // `source.currentCount` authoritatively. Mirrors
            // `insertIncrementEventRaw(sourceTaskId, -eff, undefined, now)`.
            try Self.insertIncrementEventRaw(db: db, taskId: sourceTaskId, delta: -eff, boardId: nil, now: now)

            // 3. Fetch all linked (derived) tasks for this source.
            let linkedTasks = try Task
                .filter(Column("sharedCounterId") == sourceTaskId)
                .filter(Column("isDeleted") == false)
                .fetchAll(db)

            // 4. Re-derive each linked task via the shared propagation helper
            //    (same fan-out as increment; mirrors `propagateIncrement` in
            //    sharedCounter.ts). The one-way latch is ORed in, so decrement
            //    never un-completes a task. DB layer owns the writes.
            let propagation = propagateIncrement(
                sourceAfterCurrentCount: newSourceCount,
                linkedTasks: linkedTasks.map {
                    PropagateIncrementLinkedTask(
                        id: $0.id,
                        baseline: $0.baseline,
                        maxCount: $0.maxCount,
                        isCompleted: $0.isCompleted
                    )
                }
            )
            for (result, var linked) in zip(propagation, linkedTasks) {
                let linkedWasCompleted = linked.isCompleted

                linked.currentCount = result.newCurrentCount  // mirror source count
                linked.isCompleted = result.newIsCompleted
                // completedAt: only set if newly completing (unusual on decrement,
                // but consistent with latch semantics). Preserves the invariant
                // isCompleted set ⟹ completedAt set.
                if !linkedWasCompleted && result.newIsCompleted {
                    linked.completedAt = now
                }
                linked.updatedAt = now
                linked.version += 1
                try linked.save(db)
                try SyncQueueBuilder.makeItem(
                    entityType: "tasks",
                    entityId: linked.id,
                    operationType: .update,
                    payload: linked,
                    now: now
                ).enqueue(db)
            }

            // 5. Board cascade + credit result.
            let allChangedTaskIds = [sourceTaskId] + linkedTasks.map { $0.id }
            let creditBoards = try runSharedCounterCascade(
                db: db,
                allChangedTaskIds: allChangedTaskIds,
                now: now
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
        let undoneAmount: Int
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
    ///   5. Propagate to linked tasks via `propagateIncrement` and re-run
    ///      the board derivation cascade for the source + every linked task,
    ///      exactly like increment/decrement.
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
            let newSourceCount = max(0, currentCount - entryDelta)

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

            // 6. Find all linked (derived) tasks and propagate, exactly like
            //    increment/decrement.
            let linkedTasks = try Task
                .filter(Column("sharedCounterId") == sourceTaskId)
                .filter(Column("isDeleted") == false)
                .fetchAll(db)

            let propagation = propagateIncrement(
                sourceAfterCurrentCount: newSourceCount,
                linkedTasks: linkedTasks.map {
                    PropagateIncrementLinkedTask(
                        id: $0.id,
                        baseline: $0.baseline,
                        maxCount: $0.maxCount,
                        isCompleted: $0.isCompleted
                    )
                }
            )
            for (result, var linked) in zip(propagation, linkedTasks) {
                let linkedWasCompleted = linked.isCompleted

                linked.currentCount = result.newCurrentCount
                linked.isCompleted = result.newIsCompleted
                if !linkedWasCompleted && result.newIsCompleted {
                    linked.completedAt = now
                }
                linked.updatedAt = now
                linked.version += 1
                try linked.save(db)
                try SyncQueueBuilder.makeItem(
                    entityType: "tasks",
                    entityId: linked.id,
                    operationType: .update,
                    payload: linked,
                    now: now
                ).enqueue(db)
            }

            // 7. Board cascade + credit result.
            let allChangedTaskIds = [sourceTaskId] + linkedTasks.map { $0.id }
            let creditBoards = try runSharedCounterCascade(
                db: db,
                allChangedTaskIds: allChangedTaskIds,
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
    ///   - amount: A positive integer.
    func setCounterDefaultLogAmount(sourceTaskId: String, amount: Int) throws {
        guard amount >= 1 else {
            throw NSError(
                domain: "AppDatabase.setCounterDefaultLogAmount",
                code: 1,
                userInfo: [NSLocalizedDescriptionKey:
                    "setCounterDefaultLogAmount: amount must be a positive integer"]
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
