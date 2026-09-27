import Foundation
import GRDB

// MARK: - Closed-board late log (Board Edit redesign slice 4, D7/D9/D10)
//
// Swift twin of `apps/web/src/db/operations/lateLog.ts`. The ONE choke point
// through which a CLOSED board authors an event (owner ruling R1/R3):
//
//   - `lateLogCompletion` — a NORMAL square's "Mark done on board".
//   - `lateLogIncrement` — a plain/source COUNTING square's "+N", OR a
//     window-stamped derived counter's "+N" (the increment lands on its
//     ROOT); a hub-linked derived counter is a no-op (OQ2).
//   - `lateLogCompoundParts` — a COMPOUND square's staged child completions;
//     commits only once the rule is met.
//   - `undoLateLog` — reverses exactly the newest late log on `taskId`
//     (`selectClosedBoardLateLogs`), never any other sealed-window event.
//
// Every entry point: guards the board is CLOSED and the task is placed on it
// (directly or via a placed compound), stamps `occurredAt` at the board's
// `endDate` (`lateLogOccurredAt` — R1), authors via the raw append/tombstone
// choke points (bypassing only THEIR sealed early-returns — every other
// caller's guard is untouched), then re-derives (D9): the live cascade for
// any still-open containing board (a weekly/monthly whose window also holds
// the stamp), the sealed re-derivation for every sealed board placing the
// task (the closed daily itself, plus a sealed parent), and the
// achievement-watcher refresh (D8) — all in ONE write transaction.

/// Typed failures for the closed-board late-log entry points.
enum LateLogError: Error, Equatable {
    /// The board is missing, deleted, or not currently sealed (late log only
    /// applies to a CLOSED board — an ended-but-unsealed board's own play
    /// surface logs through the normal path, already stamped at `endDate`).
    case boardNotClosed
    /// The task is not placed on this board (directly or via a placed
    /// compound).
    case taskNotPlaced
    /// The task's type doesn't match the entry point called (e.g.
    /// `lateLogCompletion` on a COUNTING task), or a hub-linked derived
    /// counter / achievement task (not tappable — OQ2).
    case wrongTaskType
    /// `lateLogCompoundParts`: the staged child completions don't satisfy the
    /// compound's operator rule yet — nothing was written.
    case ruleNotMet
    /// `lateLogIncrement`: `delta` must be a positive integer.
    case invalidDelta
}

extension AppDatabase {

    // MARK: - Placement reachability

    /// Whether `taskId` is placed on `boardId` — directly, or as a
    /// transitive descendant of a compound that IS placed on it. Reuses the
    /// same reachability `findAffectedBoardIds`/`findTransitiveParentCompounds`
    /// give the pull-path re-derivation and sealed-window immunity.
    static func isTaskPlacedOnBoard(db: Database, boardId: String, taskId: String) throws -> Bool {
        let allChildren = try CompoundChild.filter(Column("isDeleted") == false).fetchAll(db)
        let allBoardTasks = try BoardTask.filter(Column("isDeleted") == false).fetchAll(db)
        let parents = DerivationPass.findTransitiveParentCompounds(changedTaskId: taskId, children: allChildren)
        let boardIds = DerivationPass.findAffectedBoardIds(
            changedTaskId: taskId, parentCompounds: parents, boardTasks: allBoardTasks
        )
        return boardIds.contains(boardId)
    }

    /// Fetches + validates the CLOSED board a late log targets. Throws
    /// `LateLogError.boardNotClosed` for a missing / deleted / unsealed board.
    private static func fetchClosedBoard(db: Database, boardId: String) throws -> Board {
        guard let board = try Board.fetchOne(db, key: boardId), !board.isDeleted, board.sealedAt != nil else {
            throw LateLogError.boardNotClosed
        }
        return board
    }

    // MARK: - Shared re-derivation (D9)

    /// The re-derivation D9 requires after every closed-board late-log write:
    /// live-cascade any still-open board placing a changed task (a weekly /
    /// monthly whose window also holds the stamp), sealed-re-derive every
    /// sealed board placing one (the closed daily itself, plus a sealed
    /// parent whose window already closed too), then refresh achievement
    /// watchers over every board whose stats just changed.
    ///
    /// `changedTaskIds` may include ids reached only for CASCADE purposes
    /// (e.g. a frozen window-stamped row whose window holds the event) —
    /// board-reachability doesn't distinguish authored from cascade-only,
    /// which is exactly the desired effect (their boards re-derive; the rows
    /// themselves are never written here).
    ///
    /// MUST run inside the caller's write transaction, after the event
    /// append/tombstone + any task-cache/propagation writes.
    private static func reDeriveAfterLateLogWrite(db: Database, changedTaskIds: Set<String>, now: String) throws {
        guard !changedTaskIds.isEmpty else { return }

        let allChildren = try CompoundChild.filter(Column("isDeleted") == false).fetchAll(db)
        let allBoardTasks = try BoardTask.filter(Column("isDeleted") == false).fetchAll(db)
        let reachable = try Self.withWindowStampedDerived(db: db, taskIds: changedTaskIds)

        var affectedBoardIds = Set<String>()
        for taskId in reachable {
            let parents = DerivationPass.findTransitiveParentCompounds(changedTaskId: taskId, children: allChildren)
            let ids = DerivationPass.findAffectedBoardIds(changedTaskId: taskId, parentCompounds: parents, boardTasks: allBoardTasks)
            affectedBoardIds.formUnion(ids)
        }

        var changedBoardIds = Set<String>()
        for id in affectedBoardIds {
            guard let b = try Board.fetchOne(db, key: id), !b.isDeleted else { continue }
            if b.sealedAt == nil {
                try reDeriveLiveBoardTx(db: db, boardId: id, now: now)
            }
            changedBoardIds.insert(id)
        }

        // Sealed re-derivation already does its own reachability expansion
        // (incl. window-stamped derived roots) — covers the closed board
        // itself plus any sealed parent.
        try Self.reDeriveSealedBoards(db: db, changedTaskIds: changedTaskIds)

        try Self.refreshWatchersForBoards(db: db, changedBoardIds: changedBoardIds, now: now)
    }

    // MARK: - lateLogCompletion (NORMAL)

    /// Marks a NORMAL square done on a closed board, stamped at the board's
    /// `endDate`. No-op (no write) if the task is already complete within the
    /// sealed window `[startDate, min(endDate, sealedAt)]`.
    ///
    /// - Throws: `LateLogError.boardNotClosed` / `.taskNotPlaced` /
    ///   `.wrongTaskType`.
    func lateLogCompletion(boardId: String, taskId: String, now: String = AppDatabase.currentTimestamp()) throws {
        try write { db in
            let board = try Self.fetchClosedBoard(db: db, boardId: boardId)
            guard try Self.isTaskPlacedOnBoard(db: db, boardId: boardId, taskId: taskId) else {
                throw LateLogError.taskNotPlaced
            }
            guard let task = try Task.fetchOne(db, key: taskId), task.type == .normal else {
                throw LateLogError.wrongTaskType
            }

            let sealedAtMs = (DateFormatting.parseISO(board.sealedAt!)?.timeIntervalSince1970 ?? 0) * 1000
            let rawEvents = try TaskEvent.filter(Column("taskId") == taskId && Column("isDeleted") == false).fetchAll(db)
            let boundedEvents = rawEvents.filter {
                guard let occurred = DateFormatting.parseISO($0.occurredAt) else { return false }
                return occurred.timeIntervalSince1970 * 1000 <= sealedAtMs
            }
            let state = resolveTaskWindowState(
                task: task, events: boundedEvents, windowStart: board.startDate, windowEnd: boardWindowEnd(board)
            )
            if state.isCompleted { return } // already complete in this sealed window

            let occurredAt = lateLogOccurredAt(board: board, nowIso: now)
            try Self.appendCompletionEvent(db: db, taskId: taskId, boardId: boardId, now: now, occurredAt: occurredAt)
            try Self.reDeriveAfterLateLogWrite(db: db, changedTaskIds: [taskId], now: now)
        }
    }

    // MARK: - lateLogIncrement (COUNTING — plain, source, or window-stamped derived)

    /// Logs `delta` (> 0) on a closed board's COUNTING square, stamped at the
    /// board's `endDate`.
    ///
    ///   - Plain / source counting (`sharedCounterId == nil`): appends the
    ///     increment directly (event-owning).
    ///   - Window-stamped derived counter: the increment is appended on the
    ///     ROOT (derived rows own no events — carve-out), then propagated to
    ///     every OTHER live linked row exactly like `incrementSharedCounter`
    ///     (frozen rows are skipped for writes, still reached for cascade).
    ///   - Hub-linked derived counter (no `startDate`): no-op — its square
    ///     isn't tappable on a closed board (OQ2 default).
    ///
    /// - Throws: `LateLogError.boardNotClosed` / `.taskNotPlaced` /
    ///   `.wrongTaskType` / `.invalidDelta`.
    func lateLogIncrement(boardId: String, taskId: String, delta: Int, now: String = AppDatabase.currentTimestamp()) throws {
        guard delta > 0 else { throw LateLogError.invalidDelta }
        try write { db in
            let board = try Self.fetchClosedBoard(db: db, boardId: boardId)
            guard try Self.isTaskPlacedOnBoard(db: db, boardId: boardId, taskId: taskId) else {
                throw LateLogError.taskNotPlaced
            }
            guard let task = try Task.fetchOne(db, key: taskId), task.type == .counting else {
                throw LateLogError.wrongTaskType
            }
            let occurredAt = lateLogOccurredAt(board: board, nowIso: now)

            if task.sharedCounterId == nil {
                // Plain / source counting — event-owning; overshoot allowed.
                try Self.appendIncrementEvent(db: db, taskId: taskId, delta: delta, boardId: boardId, now: now, occurredAt: occurredAt)
                try Self.refreshDerivedBaselines(db: db, rootTaskId: taskId)
                try Self.reDeriveAfterLateLogWrite(db: db, changedTaskIds: [taskId], now: now)
                return
            }

            guard BoardSources.isWindowStampedDerived(task) else {
                return // hub-linked derived counter — not tappable (OQ2)
            }

            let rootId = task.sharedCounterId!
            try Self.appendIncrementEvent(db: db, taskId: rootId, delta: delta, boardId: nil, now: now, occurredAt: occurredAt)
            try Self.refreshDerivedBaselines(db: db, rootTaskId: rootId)

            guard let rootAfter = try Task.fetchOne(db, key: rootId) else { return }
            let (linkedTasks, reachedFrozenIds) = try Self.fetchLinkedTasksForLog(
                db: db, sourceTaskId: rootId, reachOccurredAt: occurredAt, now: now
            )
            let propagation = propagateIncrement(
                sourceAfterCurrentCount: rootAfter.currentCount ?? 0,
                linkedTasks: linkedTasks.map {
                    PropagateIncrementLinkedTask(id: $0.id, baseline: $0.baseline, maxCount: $0.maxCount, isCompleted: $0.isCompleted)
                }
            )
            for (result, var linked) in zip(propagation, linkedTasks) {
                let wasCompleted = linked.isCompleted
                linked.currentCount = result.newCurrentCount
                linked.isCompleted = result.newIsCompleted
                if !wasCompleted && result.newIsCompleted { linked.completedAt = now }
                linked.updatedAt = now
                linked.version += 1
                try linked.save(db)
                try SyncQueueBuilder.makeItem(
                    entityType: "tasks", entityId: linked.id, operationType: .update, payload: linked, now: now
                ).enqueue(db)
            }

            let changedIds = Set([rootId] + linkedTasks.map(\.id)).union(reachedFrozenIds)
            try Self.reDeriveAfterLateLogWrite(db: db, changedTaskIds: changedIds, now: now)
        }
    }

    // MARK: - lateLogCompoundParts (COMPOUND)

    /// Stages completions for `childTaskIds` (event-owning — NORMAL —
    /// children only; a plain-counting child's "+N" goes through
    /// `lateLogIncrement` on the child directly) and commits ONLY if doing so
    /// satisfies `compoundTaskId`'s operator rule. Rejected (no write) when
    /// the rule isn't met.
    ///
    /// - Throws: `LateLogError.boardNotClosed` / `.taskNotPlaced` /
    ///   `.wrongTaskType` / `.ruleNotMet`.
    func lateLogCompoundParts(
        boardId: String,
        compoundTaskId: String,
        childTaskIds: [String],
        now: String = AppDatabase.currentTimestamp()
    ) throws {
        try write { db in
            let board = try Self.fetchClosedBoard(db: db, boardId: boardId)
            guard try Self.isTaskPlacedOnBoard(db: db, boardId: boardId, taskId: compoundTaskId) else {
                throw LateLogError.taskNotPlaced
            }
            guard let compound = try Task.fetchOne(db, key: compoundTaskId), compound.type == .compound else {
                throw LateLogError.wrongTaskType
            }

            let allChildren = try CompoundChild.filter(Column("isDeleted") == false).fetchAll(db)
            let ownChildren = allChildren.filter { $0.compoundTaskId == compoundTaskId }
            let allTasks = try Task.fetchAll(db)
            var taskById: [String: Task] = [:]
            for t in allTasks { taskById[t.id] = t }

            // Only stage event-owning (NORMAL) direct children that actually
            // belong to this compound; anything else in the request is
            // silently dropped rather than failing the whole call.
            let stagedIds = Set(childTaskIds).filter { id in
                guard let child = taskById[id], child.type == .normal else { return false }
                return ownChildren.contains { $0.childTaskId == id }
            }

            let occurredAt = lateLogOccurredAt(board: board, nowIso: now)
            let sealedAtMs = (DateFormatting.parseISO(board.sealedAt!)?.timeIntervalSince1970 ?? 0) * 1000
            let allEvents = try TaskEvent.filter(Column("isDeleted") == false).fetchAll(db)
            var eventsByTaskId: [String: [TaskEvent]] = [:]
            for e in allEvents {
                guard let occurred = DateFormatting.parseISO(e.occurredAt),
                      occurred.timeIntervalSince1970 * 1000 <= sealedAtMs else { continue }
                eventsByTaskId[e.taskId, default: []].append(e)
            }
            // Virtual staged completions, so the windowed evaluator sees the
            // proposed state WITHOUT writing anything yet.
            for id in stagedIds {
                let synthetic = TaskEvent(
                    id: "staged-\(id)", userId: compound.userId, taskId: id, kind: .completion, delta: nil,
                    occurredAt: occurredAt, boardId: boardId, createdAt: now, updatedAt: now,
                    lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
                )
                eventsByTaskId[id, default: []].append(synthetic)
            }

            var childrenByCompound: [String: [CompoundChild]] = [:]
            for c in allChildren { childrenByCompound[c.compoundTaskId, default: []].append(c) }
            let windowContext = CompoundWindowContext(
                windowStart: board.startDate, windowEnd: boardWindowEnd(board), eventsByTaskId: eventsByTaskId
            )
            let met = CompoundEvaluation.evaluate(
                compound: compound, childrenByCompound: childrenByCompound, taskById: taskById, windowContext: windowContext
            )
            guard met else { throw LateLogError.ruleNotMet }

            for id in stagedIds {
                try Self.appendCompletionEvent(db: db, taskId: id, boardId: boardId, now: now, occurredAt: occurredAt)
            }
            try Self.reDeriveAfterLateLogWrite(db: db, changedTaskIds: stagedIds.union([compoundTaskId]), now: now)
        }
    }

    // MARK: - undoLateLog (D10, R2)

    /// Reverses exactly the newest late log a user made on `boardId` for
    /// `taskId` (`selectClosedBoardLateLogs` — newest `createdAt` first). For
    /// a window-stamped derived square, pass the ROOT id (derived rows own no
    /// events). Silent no-op if there is nothing to undo.
    ///
    /// - Throws: `LateLogError.boardNotClosed`.
    func undoLateLog(boardId: String, taskId: String, now: String = AppDatabase.currentTimestamp()) throws {
        try write { db in
            let board = try Self.fetchClosedBoard(db: db, boardId: boardId)

            let allEvents = try TaskEvent.filter(Column("taskId") == taskId).fetchAll(db)
            let lateLogs = selectClosedBoardLateLogs(events: allEvents, board: board, taskId: taskId)
            guard var latest = lateLogs.first else { return } // nothing to undo

            // D10: a late log re-freezes once ANY containing board (not just
            // `boardId`) seals AFTER it was created — `selectClosedBoardLateLogs`
            // only knows about `boardId`'s own seal instant, so check the FULL
            // cross-board immunity predicate before touching anything.
            let immuneWindows = try Self.sealImmuneWindows(db: db, taskId: taskId)
            guard !isEventSealImmune(latest, windows: immuneWindows) else { return } // re-frozen by a later seal

            latest.isDeleted = true
            latest.deletedAt = now
            latest.updatedAt = now
            latest.version += 1
            try latest.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "taskEvents", entityId: latest.id, operationType: .delete, payload: latest, now: now
            ).enqueue(db)

            try Self.stampTaskCachesAuthored(db: db, taskId: taskId, now: now)

            var changedIds: Set<String> = [taskId]
            if let refreshed = try Task.fetchOne(db, key: taskId), refreshed.type == .counting, refreshed.sharedCounterId == nil {
                try Self.refreshDerivedBaselines(db: db, rootTaskId: taskId)
                let (linkedTasks, reachedFrozenIds) = try Self.fetchLinkedTasksForLog(
                    db: db, sourceTaskId: taskId, reachOccurredAt: latest.occurredAt, now: now
                )
                let propagation = propagateIncrement(
                    sourceAfterCurrentCount: refreshed.currentCount ?? 0,
                    linkedTasks: linkedTasks.map {
                        PropagateIncrementLinkedTask(id: $0.id, baseline: $0.baseline, maxCount: $0.maxCount, isCompleted: $0.isCompleted)
                    }
                )
                for (result, var linked) in zip(propagation, linkedTasks) {
                    let wasCompleted = linked.isCompleted
                    linked.currentCount = result.newCurrentCount
                    linked.isCompleted = result.newIsCompleted
                    if !wasCompleted && result.newIsCompleted { linked.completedAt = now }
                    linked.updatedAt = now
                    linked.version += 1
                    try linked.save(db)
                    try SyncQueueBuilder.makeItem(
                        entityType: "tasks", entityId: linked.id, operationType: .update, payload: linked, now: now
                    ).enqueue(db)
                }
                changedIds.formUnion(linkedTasks.map(\.id))
                changedIds.formUnion(reachedFrozenIds)
            }

            try Self.reDeriveAfterLateLogWrite(db: db, changedTaskIds: changedIds, now: now)
        }
    }
}
