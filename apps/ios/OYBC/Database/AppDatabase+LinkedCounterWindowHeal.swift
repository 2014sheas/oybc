import Foundation
import GRDB

// MARK: - Windowed linked counters — heal + placement minting (data layer)
//
// Owner rule 2026-10-01: a counting square on a board accounts ONLY for the
// counter's logs inside that board's window. The hub-linked lifetime-latch
// carve-out is retired for anything placed on a board; every linked
// placement is a per-board window-stamped derived row. Pure planning lives in
// `Helpers/LinkedCounterWindowHeal.swift` (vector-pinned against the TS twin);
// this file applies it:
//
//   - `healLinkedCounterWindowsTx` — one-time + post-pull sweep (GRDB v37 and
//     `SyncService.pullSync`, mirroring heal-on-pull #448). AUTHORED writes with
//     deterministic content, so every device converges and a re-run is a no-op.
//   - `resolveWindowStampedPlacementId` — the placement choke points
//     (`addBoardTaskToBoard`, `updateBoardTaskAndCascade`) resolve a hub-linked
//     task to its board's own row before placing it. Board Edit's add/replace
//     square bypasses the wizard planner and lands in those two ops, so this is
//     what makes it window-safe.

extension AppDatabase {

    /// Can a log made now still change this board? Credit toast + stepper
    /// hint qualify a board only when it is live, `.active`, not closed
    /// (`sealedAt == nil`) and not ended (`endDate` parses and is `< now` —
    /// compared as INSTANTS, never as strings). A closed or ended board's
    /// squares are frozen for new logs, so crediting it is a false claim.
    ///
    /// - Parameters:
    ///   - board: The candidate board.
    ///   - now: ISO8601 clock.
    /// - Returns: True when a log made at `now` can still move this board.
    static func boardCanStillCountLogs(_ board: Board, now: String) -> Bool {
        guard !board.isDeleted, board.status == .active, board.sealedAt == nil else { return false }
        if let endDate = board.endDate, let end = DateFormatting.parseISO(endDate),
           let nowDate = DateFormatting.parseISO(now), end < nowDate { return false }
        return true
    }

    /// Instance wrapper over ``healLinkedCounterWindowsTx(db:userId:now:)``.
    ///
    /// - Parameter userId: The owner whose rows to heal.
    /// - Returns: How many rows were stamped in place / minted as copies.
    @discardableResult
    func healLinkedCounterWindows(userId: String) throws -> (stamped: Int, copied: Int) {
        try write { db in
            try Self.healLinkedCounterWindowsTx(db: db, userId: userId, now: Self.currentTimestamp())
        }
    }

    /// Heal pre-rule hub-linked counters into per-board window-stamped rows.
    /// Runs INSIDE the caller's write transaction.
    ///
    /// Plans with ``BoardSources/planLinkedCounterWindowHeal(tasks:boardTasks:boards:compoundChildren:)``;
    /// each stamp sets `timeframe` / `startDate` / `endDate` /
    /// `createdInWizard = true` (+ `baseline`, so the authored payload is
    /// complete) with a version bump + UPDATE enqueue; each copy is minted
    /// (or restored from a tombstone) with the deterministic
    /// `derivedTaskId`, enqueued, and its `BoardTask` repointed (version bump
    /// + UPDATE enqueue). Then the touched roots' baselines refresh
    /// (non-authored), and every reached board re-derives (live cascade,
    /// sealed re-derivation, watcher refresh) via the late-log choke point.
    ///
    /// - Parameters:
    ///   - db: The caller's open write transaction.
    ///   - userId: Owner of the rows; other users' rows are ignored.
    ///   - now: ISO8601 write stamp.
    /// - Returns: Counts of rows stamped in place and minted as copies.
    @discardableResult
    static func healLinkedCounterWindowsTx(
        db: Database, userId: String, now: String
    ) throws -> (stamped: Int, copied: Int) {
        let tasks = try Task.filter(Column("userId") == userId).fetchAll(db)
        let boards = try Board.filter(Column("userId") == userId).fetchAll(db)
        let boardIds = Set(boards.map(\.id))
        let boardTasks = try BoardTask.filter(Column("isDeleted") == false).fetchAll(db)
            .filter { boardIds.contains($0.boardId) }
        let children = try CompoundChild.filter(Column("isDeleted") == false).fetchAll(db)

        let plan = BoardSources.planLinkedCounterWindowHeal(
            tasks: tasks, boardTasks: boardTasks, boards: boards, compoundChildren: children
        )
        if plan.stamps.isEmpty && plan.copies.isEmpty { return (0, 0) }

        let tasksById = Dictionary(tasks.map { ($0.id, $0) }, uniquingKeysWith: { a, _ in a })
        var rootsTouched = Set<String>()
        var changedIds = Set<String>()
        var stamped = 0
        var copied = 0
        var eventsByRoot: [String: [TaskEvent]] = [:]
        func rootEvents(_ root: String) throws -> [TaskEvent] {
            if let cached = eventsByRoot[root] { return cached }
            let events = try TaskEvent
                .filter(Column("taskId") == root && Column("isDeleted") == false).fetchAll(db)
            eventsByRoot[root] = events
            return events
        }

        for stamp in plan.stamps {
            guard var task = tasksById[stamp.taskId], let root = task.sharedCounterId else { continue }
            task.timeframe = stamp.timeframe
            task.startDate = stamp.startDate
            task.endDate = stamp.endDate
            task.createdInWizard = true
            task.baseline = BoardSources.computeWindowBaseline(
                rootTaskId: root, events: try rootEvents(root), boundary: stamp.startDate
            )
            task.updatedAt = now
            task.version += 1
            try task.save(db)
            try SyncQueueBuilder.makeItem(
                entityType: "tasks", entityId: task.id, operationType: .update,
                payload: task, now: now, ownerUid: userId
            ).enqueue(db)
            rootsTouched.insert(root)
            changedIds.insert(task.id)
            stamped += 1
        }

        // board id -> live placements, built once (the duplicate-square guard).
        var livePlacementsByBoard: [String: [BoardTask]] = [:]
        for placement in boardTasks { livePlacementsByBoard[placement.boardId, default: []].append(placement) }

        for copy in plan.copies {
            // Residual (i): the board already shows a LIVE square for the copy id
            // (e.g. a peer's sweep already repointed another placement) — minting +
            // repointing would put the same task on two squares. Skip; the stale
            // placement stays on the source row until the user edits it.
            if livePlacementsByBoard[copy.boardId]?.contains(where: { $0.taskId == copy.id }) == true { continue }
            // Residual (ii): the deterministic copy row exists TOMBSTONED. Reviving it
            // could lose to a higher-version remote tombstone and orphan the repointed
            // placement, so the sweep never revives (the placement choke point, which
            // is user-authored intent, still does). The row stays on the source.
            if let dead = try Task.fetchOne(db, key: copy.id), dead.isDeleted { continue }
            guard let source = tasksById[copy.sourceTaskId],
                  let rootTask = try Task.fetchOne(db, key: copy.rootTaskId) else { continue }
            let baseline = BoardSources.computeWindowBaseline(
                rootTaskId: copy.rootTaskId, events: try rootEvents(copy.rootTaskId), boundary: copy.startDate
            )
            guard let draft = BoardSources.windowStampedCopyDraft(
                copy: copy, sourceTask: source, baseline: baseline
            ) else { continue }
            try mintLinkedCounterCopy(
                db: db, draft: draft, root: rootTask, userId: userId, now: now, reviveTombstoned: false
            )

            if var placement = try BoardTask.fetchOne(db, key: copy.boardTaskId), !placement.isDeleted {
                placement.taskId = copy.id
                placement.updatedAt = now
                placement.version += 1
                try placement.save(db)
                try SyncQueueBuilder.makeItem(
                    entityType: "boardTasks", entityId: placement.id, operationType: .update,
                    payload: placement, now: now, ownerUid: userId
                ).enqueue(db)
            }
            rootsTouched.insert(copy.rootTaskId)
            changedIds.insert(copy.id)
            changedIds.insert(copy.sourceTaskId) // its old placement just moved off
            copied += 1
        }

        for root in rootsTouched { try refreshDerivedBaselines(db: db, rootTaskId: root) }
        try reDeriveAfterLateLogWrite(db: db, changedTaskIds: changedIds, now: now)
        return (stamped, copied)
    }

    /// Materialise one window-stamped copy draft: build the row from the root
    /// and write it idempotently (insert + CREATE enqueue, skip a live row,
    /// or RESTORE a tombstoned deterministic row with a version bump).
    private static func mintLinkedCounterCopy(
        db: Database, draft: BoardSources.DerivedTaskDraft, root: Task, userId: String, now: String,
        reviveTombstoned: Bool = true
    ) throws {
        let rows = BoardSources.buildDerivedRows(
            drafts: BoardSources.PlanDerivedTasksResult(
                placementIds: [draft.id], derivedTasks: [draft], derivedCompounds: []
            ),
            userId: userId, now: now, rootsById: [root.id: root], compoundsById: [:]
        )
        for row in rows.tasks {
            try writeMintedTask(db: db, row: row, now: now, ownerUid: userId, reviveTombstoned: reviveTombstoned)
        }
    }

    /// The placement choke points' gate (docs: owner rule 2026-10-01). If
    /// `task` is a linked counting row that is NOT window-stamped for `board`,
    /// resolve it to the board's own per-window row
    /// (`derivedTaskId(board.id, root)`): reuse a live one, restore a
    /// tombstoned one, else mint it. Returns the id to PLACE — `task.id`
    /// unchanged for anything else (including a goal-less linked row, which
    /// has nothing to mint a target from).
    ///
    /// Runs inside the caller's write transaction. Covers Board Edit's
    /// add/replace square, which bypasses the wizard's member-rule planner.
    ///
    /// - Parameters:
    ///   - db: The caller's open write transaction.
    ///   - task: The task about to be placed.
    ///   - board: The board receiving it.
    ///   - now: ISO8601 write stamp.
    /// - Returns: The task id the placement must point at.
    static func resolveWindowStampedPlacementId(
        db: Database, task: Task, board: Board, now: String
    ) throws -> String {
        guard task.type == .counting, let root = task.sharedCounterId, !root.isEmpty,
              !BoardSources.isWindowStampedForBoard(task, board: board) else { return task.id }
        let id = BoardSources.derivedTaskId(boardId: board.id, rootTaskId: root)
        if id == task.id { return task.id }

        if let existing = try Task.fetchOne(db, key: id), !existing.isDeleted {
            return BoardSources.isWindowStampedForBoard(existing, board: board) ? id : task.id
        }
        guard let rootTask = try Task.fetchOne(db, key: root) else { return task.id }
        let events = try TaskEvent
            .filter(Column("taskId") == root && Column("isDeleted") == false).fetchAll(db)
        let copy = BoardSources.LinkedCounterWindowCopy(
            id: id, boardId: board.id, boardTaskId: "", sourceTaskId: task.id, rootTaskId: root,
            timeframe: board.timeframe, startDate: board.startDate, endDate: board.endDate
        )
        let baseline = BoardSources.computeWindowBaseline(
            rootTaskId: root, events: events, boundary: board.startDate
        )
        guard let draft = BoardSources.windowStampedCopyDraft(copy: copy, sourceTask: task, baseline: baseline)
        else { return task.id }
        try mintLinkedCounterCopy(db: db, draft: draft, root: rootTask, userId: task.userId, now: now)
        try refreshDerivedBaselines(db: db, rootTaskId: root)
        return id
    }
}

extension LinkedCounterWindow {
    /// The window a linked counting square on `board` is evaluated against:
    /// the board's own `[startDate, endDate]` (owner rule 2026-10-01). Sealing
    /// is bounded separately via `resolveLinkedCounterDisplay(sealedAt:)`.
    ///
    /// - Parameter board: The placing board.
    init(board: Board) {
        self.init(startDate: board.startDate, endDate: board.endDate)
    }
}
