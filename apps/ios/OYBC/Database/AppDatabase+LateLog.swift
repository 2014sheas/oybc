import Foundation
import GRDB

// MARK: - Closed-board late log (Board Edit redesign slice 4, D7/D9/D10)
//
// Swift twin of `apps/web/src/db/operations/lateLog.ts`. The ONE choke point
// through which a CLOSED board authors an event (owner ruling R1/R3):
//
//   - `lateLogCompletion` — a NORMAL square's "Mark done on board".
//   - `lateLogIncrement` — a plain/source COUNTING square's "+N", OR a
//     LINKED counter's "+N" (the increment lands on its ROOT; the old
//     hub-linked no-op, OQ2, is retired — TASK_WINDOW_REWORK slice 3a).
//   - `lateLogCompoundParts` — a COMPOUND square's staged child parts
//     (NORMAL → completion, plain COUNTING → +1); commits only once the
//     rule is met.
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
    /// `lateLogCompletion` on a COUNTING task), or an achievement task
    /// (not tappable).
    case wrongTaskType
    /// `lateLogCompoundParts`: the staged child completions don't satisfy the
    /// compound's operator rule yet — nothing was written.
    case ruleNotMet
    /// `lateLogIncrement`: `delta` must be a positive 2dp number.
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
    /// `changedTaskIds` may include ids reached only for CASCADE purposes (a
    /// shared-counter ROOT, whose linked rows are placed) — board-reachability
    /// walks the root's placement reach, so their boards re-derive.
    ///
    /// MUST run inside the caller's write transaction, after the event
    /// append/tombstone + any task-cache/propagation writes.
    static func reDeriveAfterLateLogWrite(db: Database, changedTaskIds: Set<String>, now: String, lateLogStamp: String?) throws {
        guard !changedTaskIds.isEmpty else { return }
        // "Counts toward" (docs/SHARED_COUNTER_SETTINGS.md §3b): a late log that
        // completes a contributor stamps its increment at the board's endDate —
        // the completing event's own `occurredAt` (D8). The counter's copies
        // join the re-derivation below (live, sealed and watchers alike).
        // `lateLogStamp` — this path re-derives every sealed board
        // deterministically, so a credit at exactly the stamped instant is
        // exempt from the counter's sealed windows; any other credit the same
        // cascade reaches stays suppressed (D11).
        let countsToward = try writeCountsToward(db: db, changedTaskIds: Array(changedTaskIds), now: now, lateLogStamp: lateLogStamp)
        try reDeriveReachedBoards(db: db, changedTaskIds: changedTaskIds.union(countsToward.cascadeIds), now: now)
    }

    /// `reDeriveAfterLateLogWrite`'s board half: live-cascade, sealed
    /// re-derive and watcher refresh over every board reached by
    /// `changedTaskIds`.
    private static func reDeriveReachedBoards(db: Database, changedTaskIds: Set<String>, now: String) throws {
        guard !changedTaskIds.isEmpty else { return }

        let affectedBoardIds = try Self.boardIdsReachedByTasks(db: db, taskIds: changedTaskIds)

        var changedBoardIds = Set<String>()
        for id in affectedBoardIds {
            guard let b = try Board.fetchOne(db, key: id), !b.isDeleted else { continue }
            if b.sealedAt == nil {
                try reDeriveLiveBoardTx(db: db, boardId: id, now: now)
            }
            changedBoardIds.insert(id)
        }

        // Sealed re-derivation already does its own reachability expansion
        // (incl. linked roots) — covers the closed board
        // itself plus any sealed parent.
        try Self.reDeriveSealedBoards(db: db, changedTaskIds: changedTaskIds)

        try Self.refreshWatchersForBoards(db: db, changedBoardIds: changedBoardIds, now: now)
    }

    /// Every non-deleted board placing one of `taskIds` — directly, via a
    /// placed parent compound, or (for a shared-counter ROOT, which is never
    /// placed itself) via one of its linked rows (`placementReach`).
    static func boardIdsReachedByTasks(db: Database, taskIds: Set<String>) throws -> Set<String> {
        try Self.placementReach(db: db, taskIds: taskIds).boardIds
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
            try Self.reDeriveAfterLateLogWrite(db: db, changedTaskIds: [taskId], now: now, lateLogStamp: occurredAt)
        }
    }

    // MARK: - lateLogIncrement (COUNTING — plain, source, or linked)

    /// Logs `delta` (> 0) on a closed board's COUNTING square, stamped at the
    /// board's `endDate`.
    ///
    ///   - Plain / source counting (`sharedCounterId == nil`): appends the
    ///     increment directly (event-owning).
    ///   - LINKED counter: the increment is appended on the ROOT (linked
    ///     rows own no events); every linked row resolves from the root's
    ///     events, so the side effects re-derive the root's placement reach
    ///     and nothing else is written.
    ///
    /// - Throws: `LateLogError.boardNotClosed` / `.taskNotPlaced` /
    ///   `.wrongTaskType` / `.invalidDelta`.
    func lateLogIncrement(boardId: String, taskId: String, delta: CountValue, now: String = AppDatabase.currentTimestamp()) throws {
        guard isQuantizedCount(delta) && delta > 0 else { throw LateLogError.invalidDelta }
        try write { db in
            let board = try Self.fetchClosedBoard(db: db, boardId: boardId)
            guard try Self.isTaskPlacedOnBoard(db: db, boardId: boardId, taskId: taskId) else {
                throw LateLogError.taskNotPlaced
            }
            guard let task = try Task.fetchOne(db, key: taskId), task.type == .counting else {
                throw LateLogError.wrongTaskType
            }
            // Plain / source counting authors on itself; a LINKED row authors
            // on its ROOT (linked rows own no events).
            let rootId = (task.sharedCounterId?.isEmpty == false) ? task.sharedCounterId! : taskId
            let occurredAt = lateLogOccurredAt(board: board, nowIso: now)
            // `boardId` = the closed board on BOTH branches — it is what makes
            // the event a late log (`selectClosedBoardLateLogs` /
            // `isEventSealImmune`), i.e. undoable (R2).
            try Self.appendIncrementEvent(db: db, taskId: rootId, delta: delta, boardId: boardId, now: now, occurredAt: occurredAt)
            // The side effects walk the root's placement reach (its linked rows
            // resolve from its events), so nothing else is written.
            try Self.reDeriveAfterLateLogWrite(db: db, changedTaskIds: [rootId, taskId], now: now, lateLogStamp: occurredAt)
        }
    }

    // MARK: - lateLogCompoundParts (COMPOUND)

    /// What a compound late-log commit would write, and whether it meets the
    /// rule — the ONE evaluation both the commit (`lateLogCompoundParts`) and
    /// the sheet's pre-check (`BoardPlayViewModel.wouldLateLogCompoundRuleBeMet`)
    /// use, so "Mark done on board" never enables for a commit the DB rejects.
    struct CompoundLateLogPlan: Equatable {
        /// NORMAL direct children to complete (not already done in-window).
        let completionIds: Set<String>
        /// Plain COUNTING direct children to log `+1` on (D7).
        let incrementIds: Set<String>
        /// LINKED counting direct children (slice 0) → the ROOT the `+1` is
        /// written on (a linked row owns no events).
        let linkedIncrementRoots: [String: String]
        /// The compound's rule under the staged state.
        let isRuleMet: Bool
    }

    /// Pure planner for a compound late log on a CLOSED board. Keeps only
    /// requested ids that are real, non-deleted, event-owning DIRECT children
    /// (NORMAL → completion unless already complete in the window; plain
    /// COUNTING → +1 increment), adds them as synthetic events stamped at
    /// `occurredAt`, and evaluates the compound with the shared windowed
    /// `CompoundEvaluation` over `[startDate, endDate]`, every event bounded
    /// at `sealedAt` (the sealed snapshot's own bound).
    ///
    /// - Parameters:
    ///   - eventsByTaskId: Non-deleted events by task id (any superset of the
    ///     compound's descendants).
    ///   - childrenByCompound: Non-deleted links by parent compound id.
    static func planCompoundLateLog(
        board: Board,
        compound: Task,
        requestedChildIds: Set<String>,
        taskById: [String: Task],
        childrenByCompound: [String: [CompoundChild]],
        eventsByTaskId: [String: [TaskEvent]],
        occurredAt: String,
        now: String,
        childTargets: [PlacementChildTarget]? = nil
    ) -> CompoundLateLogPlan {
        let sealedAtMs = board.sealedAt.flatMap { DateFormatting.parseISO($0) }
            .map { $0.timeIntervalSince1970 * 1000 } ?? .infinity
        var bounded: [String: [TaskEvent]] = [:]
        for (taskId, events) in eventsByTaskId {
            let kept = events.filter { e in
                guard !e.isDeleted, let t = DateFormatting.parseISO(e.occurredAt) else { return false }
                return t.timeIntervalSince1970 * 1000 <= sealedAtMs
            }
            if !kept.isEmpty { bounded[taskId] = kept }
        }

        let ownChildIds = Set((childrenByCompound[compound.id] ?? []).filter { !$0.isDeleted }.map(\.childTaskId))
        var completionIds = Set<String>()
        var incrementIds = Set<String>()
        var linkedIncrementRoots: [String: String] = [:]
        for id in requestedChildIds where ownChildIds.contains(id) {
            guard let child = taskById[id], !child.isDeleted else { continue }
            switch child.type {
            case .normal where isEventOwningTask(child):
                let state = resolveTaskWindowState(
                    task: child, events: bounded[id] ?? [], windowStart: board.startDate, windowEnd: boardWindowEnd(board)
                )
                if !state.isCompleted { completionIds.insert(id) }
            case .counting where child.sharedCounterId == nil && isEventOwningTask(child):
                incrementIds.insert(id)
            case .counting:
                // A LINKED counting child (slice 0) logs on its root, where the
                // kernel reads it over this board's window.
                guard let root = child.sharedCounterId, let rootTask = taskById[root], !rootTask.isDeleted else { continue }
                linkedIncrementRoots[id] = root
            default:
                continue
            }
        }

        var staged = bounded
        for id in completionIds.union(incrementIds) {
            let isIncrement = incrementIds.contains(id)
            staged[id, default: []].append(TaskEvent(
                id: "staged-\(id)", userId: compound.userId, taskId: id,
                kind: isIncrement ? .increment : .completion, delta: isIncrement ? 1 : nil,
                occurredAt: occurredAt, boardId: board.id, createdAt: now, updatedAt: now,
                lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
            ))
        }
        for (id, root) in linkedIncrementRoots {
            staged[root, default: []].append(TaskEvent(
                id: "staged-\(id)", userId: compound.userId, taskId: root,
                kind: .increment, delta: 1,
                occurredAt: occurredAt, boardId: board.id, createdAt: now, updatedAt: now,
                lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
            ))
        }
        // The PLACEMENT's child goals (slice 2a) — what the sealed re-derive scores with.
        let met = CompoundEvaluation.evaluate(
            compound: compound,
            childrenByCompound: childrenByCompound,
            taskById: taskById,
            windowContext: CompoundWindowContext(
                windowStart: board.startDate, windowEnd: boardWindowEnd(board), eventsByTaskId: staged
            ),
            childTargets: childTargets
        )
        return CompoundLateLogPlan(
            completionIds: completionIds, incrementIds: incrementIds,
            linkedIncrementRoots: linkedIncrementRoots, isRuleMet: met
        )
    }

    /// Commits the staged parts of a COMPOUND square on a closed board —
    /// a completion per staged NORMAL child and a `+1` per staged plain
    /// COUNTING child (D7), all stamped at the board's `endDate` — ONLY if
    /// doing so satisfies the compound's rule (`planCompoundLateLog`).
    /// Rejected (no write) when the rule isn't met.
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

            var taskById: [String: Task] = [:]
            for t in try Task.fetchAll(db) { taskById[t.id] = t }
            var childrenByCompound: [String: [CompoundChild]] = [:]
            for c in try CompoundChild.filter(Column("isDeleted") == false).fetchAll(db) {
                childrenByCompound[c.compoundTaskId, default: []].append(c)
            }
            var eventsByTaskId: [String: [TaskEvent]] = [:]
            for e in try TaskEvent.filter(Column("isDeleted") == false).fetchAll(db) {
                eventsByTaskId[e.taskId, default: []].append(e)
            }

            let occurredAt = lateLogOccurredAt(board: board, nowIso: now)
            let placement = try BoardTask
                .filter(Column("boardId") == boardId && Column("taskId") == compoundTaskId && Column("isDeleted") == false)
                .fetchOne(db)
            let plan = Self.planCompoundLateLog(
                board: board, compound: compound, requestedChildIds: Set(childTaskIds),
                taskById: taskById, childrenByCompound: childrenByCompound,
                eventsByTaskId: eventsByTaskId, occurredAt: occurredAt, now: now,
                childTargets: placement?.childTargets
            )
            guard plan.isRuleMet else { throw LateLogError.ruleNotMet }

            for id in plan.completionIds {
                try Self.appendCompletionEvent(db: db, taskId: id, boardId: boardId, now: now, occurredAt: occurredAt)
            }
            for id in plan.incrementIds {
                try Self.appendIncrementEvent(db: db, taskId: id, delta: 1, boardId: boardId, now: now, occurredAt: occurredAt)
            }
            var touched = plan.completionIds.union(plan.incrementIds).union([compoundTaskId])
            // A linked child (slice 0): the `+1` is the ROOT's, exactly as
            // `lateLogIncrement` writes it for a placed linked square.
            for (childId, root) in plan.linkedIncrementRoots.sorted(by: { $0.key < $1.key }) {
                try Self.appendIncrementEvent(db: db, taskId: root, delta: 1, boardId: boardId, now: now, occurredAt: occurredAt)
                touched.insert(root); touched.insert(childId)
            }
            try Self.reDeriveAfterLateLogWrite(db: db, changedTaskIds: touched, now: now, lateLogStamp: occurredAt)
        }
    }

    // MARK: - undoLateLog (D10, R2)

    /// Reverses exactly the newest late log a user made on `boardId` for
    /// `taskId` (`selectClosedBoardLateLogs` — newest `createdAt` first). For
    /// a linked square, pass the ROOT id (linked rows own no
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

            try Self.reDeriveAfterLateLogWrite(db: db, changedTaskIds: [taskId], now: now, lateLogStamp: latest.occurredAt)
        }
    }
}
