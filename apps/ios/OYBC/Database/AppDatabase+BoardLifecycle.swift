import Foundation
import GRDB

// MARK: - Board lifecycle: Close / Reopen + achievement-watcher refresh
//
// Board Edit redesign slice 4 (docs/BOARD_EDIT_REDESIGN.md, D3/D6/D8/D12).
// Swift twin of `apps/web/src/db/operations/boardLifecycle.ts`.
//
//   - `closeBoard` — the "Close board" menu action / closing-out banner's
//     "Close out" button: the existing seal path, verbatim (D3), plus the
//     achievement-watcher refresh (D8).
//   - `reopenBoard` — "Reopen board": clears the frozen snapshot, stamps
//     `reopenedAt` (never auto-closes again), re-derives this board LIVE from
//     its event union, then refreshes watchers (D6).
//   - `refreshWatchersForBoards` — the achievement-watcher fan-out both above
//     need, plus every closed-board late log (`AppDatabase+LateLog.swift`,
//     D9): which ACHIEVEMENT tasks watch a changed board, and which OTHER
//     boards place those watchers — live-cascade the unsealed ones,
//     sealed-re-derive the sealed ones, iterated to a fixpoint (a watcher
//     board's own change can itself be watched by another achievement task).

/// Typed failures for the Close / Reopen menu actions. Twin of the web
/// `BoardLifecycleError`.
enum BoardLifecycleError: Error, Equatable {
    /// Close: the board is missing, deleted, a draft, indefinite, or its
    /// window hasn't ended yet (`!isBoardClosingOut`).
    case notClosable
    /// Reopen: the board is missing, deleted, or not currently sealed.
    case notReopenable
}

extension AppDatabase {

    // MARK: - Close (D3)

    /// Closes a board: the existing seal transaction (`sealBoardTx`),
    /// verbatim, then the achievement-watcher refresh (D8). One transaction.
    ///
    /// Idempotent on an ALREADY-closed board — returns `false`, no error,
    /// no writes (mirrors `sealBoardTx`'s own idempotence; the menu action
    /// simply disappears once closed, so a double-tap race is a silent no-op
    /// rather than a surfaced error).
    ///
    /// - Throws: `BoardLifecycleError.notClosable` for a missing / deleted /
    ///   draft / indefinite board, or one whose window hasn't ended yet.
    /// - Returns: `true` iff this call actually closed the board.
    @discardableResult
    func closeBoard(boardId: String, now: String = AppDatabase.currentTimestamp()) throws -> Bool {
        try write { db in
            guard let board = try Board.fetchOne(db, key: boardId), !board.isDeleted else {
                throw BoardLifecycleError.notClosable
            }
            if board.sealedAt != nil { return false }

            let nowMs = (DateFormatting.parseISO(now)?.timeIntervalSince1970 ?? Date().timeIntervalSince1970) * 1000
            guard isBoardClosingOut(board, nowMs: nowMs) else {
                throw BoardLifecycleError.notClosable
            }

            let sealed = try Self.sealBoardTx(db: db, boardId: boardId, now: now)
            if sealed {
                try Self.refreshWatchersForBoards(db: db, changedBoardIds: [boardId], now: now)
            }
            return sealed
        }
    }

    // MARK: - Reopen (D6)

    /// Reopens a closed board: clears `sealedAt` + `sealedCompletedCells`,
    /// stamps `reopenedAt` (so it never auto-closes again — D1/D4), bumps
    /// `version`, enqueues sync, re-derives this board LIVE from its
    /// `[startDate, endDate]` event union (status ACTIVE ↔ COMPLETED
    /// included), then refreshes achievement watchers. One transaction.
    ///
    /// Writes no template / spawn row — a reopened board never re-triggers
    /// recurring spawn.
    ///
    /// - Throws: `BoardLifecycleError.notReopenable` for a missing / deleted
    ///   / not-currently-sealed board.
    @discardableResult
    func reopenBoard(boardId: String, now: String = AppDatabase.currentTimestamp()) throws -> Bool {
        try write { db in
            guard var board = try Board.fetchOne(db, key: boardId),
                  !board.isDeleted, board.sealedAt != nil else {
                throw BoardLifecycleError.notReopenable
            }

            board.sealedAt = nil
            board.sealedCompletedCells = nil
            board.reopenedAt = now
            board.updatedAt = now
            board.version += 1
            try board.save(db)
            // `Board.encode(to:)` deliberately OMITS `sealedCompletedCells`
            // (and, empirically, GRDB's Codable→PersistenceContainer bridge
            // treats it differently from `sealedAt`'s `encodeIfPresent`) when
            // nil, so `save(db)` alone can leave the STALE frozen snapshot on
            // the row. Force-clear it with a raw SQL UPDATE, mirroring the
            // sync pull-side NULL-out (`SyncService+ClearableFields.swift`).
            try db.execute(sql: "UPDATE boards SET sealedCompletedCells = NULL WHERE id = ?", arguments: [boardId])
            try SyncQueueBuilder.makeItem(
                entityType: "boards",
                entityId: boardId,
                operationType: .update,
                payload: board,
                now: now
            ).enqueue(db)

            try Self.reDeriveLiveBoardTx(db: db, boardId: boardId, now: now)
            try Self.refreshWatchersForBoards(db: db, changedBoardIds: [boardId], now: now)
            return true
        }
    }

    /// Live re-derivation for exactly ONE (now-unsealed) board — the
    /// per-board slice of `reDeriveActiveBoards`'s loop body, extracted so
    /// Reopen (and the watcher refresh below) can recompute a single board's
    /// stats without re-deriving the whole workspace. No-op for a
    /// missing / deleted / still-sealed board.
    ///
    /// `authored` (default `true`): bump `version` + `updatedAt` and enqueue the
    /// Board sync — the local-write contract. `authored: false` writes the SAME
    /// derived fields (stats + greenlog status) in place with no version bump
    /// and no enqueue — for pull-path refreshes triggered by a pulled BOARD
    /// row (a pulled Reopen; the watcher refresh), where an authored write
    /// would push the board back and re-trigger the refresh on the peer (a
    /// ping-pong). Output is a deterministic function of converged local data,
    /// so each device converges independently (the sealed re-derive contract).
    ///
    /// MUST run inside the caller's write transaction.
    static func reDeriveLiveBoardTx(db: Database, boardId: String, now: String, authored: Bool = true) throws {
        guard var board = try Board.fetchOne(db, key: boardId), !board.isDeleted, board.sealedAt == nil else { return }

        let allBoardTasks: [BoardTask] = try BoardTask.filter(Column("isDeleted") == false).fetchAll(db)
        let allTasks: [Task] = try Task.fetchAll(db)
        let allBoards: [Board] = try Board.fetchAll(db)
        let allChildren: [CompoundChild] = try CompoundChild.filter(Column("isDeleted") == false).fetchAll(db)

        var taskById: [String: Task] = [:]
        for t in allTasks { taskById[t.id] = t }
        var childrenByCompound: [String: [CompoundChild]] = [:]
        for c in allChildren { childrenByCompound[c.compoundTaskId, default: []].append(c) }

        let windowContext = try Self.buildWindowContext(db: db)
        let boardTasksOnBoard = PlacementIntegrity.resolvePlacements(
            allBoardTasks.filter { $0.boardId == boardId },
            boardSize: board.boardSize
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
        var newStatus = board.status
        var newCompletedAt = board.completedAt
        if isGreenlogNow, board.status == .active {
            newStatus = .completed
            newCompletedAt = now
        } else if !isGreenlogNow, board.status == .completed {
            newStatus = .active
            newCompletedAt = nil
        }

        let newCompletedLineIds = update.completedLineIds.isEmpty ? nil : update.completedLineIds
        let changed = board.completedTasks != update.completedTasks
            || board.linesCompleted != update.linesCompleted
            || Set(board.completedLineIds ?? []) != Set(newCompletedLineIds ?? [])
            || board.status != newStatus
        guard changed else { return }

        board.completedTasks = update.completedTasks
        board.linesCompleted = update.linesCompleted
        board.completedLineIds = newCompletedLineIds
        board.status = newStatus
        board.completedAt = newCompletedAt
        guard authored else { return try board.save(db) }
        board.updatedAt = now
        board.version += 1
        try board.save(db)
        try SyncQueueBuilder.makeItem(
            entityType: "boards", entityId: boardId, operationType: .update, payload: board, now: now
        ).enqueue(db)
    }

    // MARK: - Achievement-watcher refresh (D8)

    /// Refreshes every achievement watcher of `changedBoardIds`'s boards: find
    /// watcher task ids via the pure `findWatcherTaskIds`, then the boards
    /// PLACING those watchers — live-cascade the unsealed ones,
    /// sealed-re-derive the sealed ones — iterating to a fixpoint over
    /// newly-changed boards (a watcher board's own stats change can itself be
    /// watched by another achievement task). Called by Close, Reopen, and
    /// every closed-board late-log / undo commit (`AppDatabase+LateLog.swift`).
    ///
    /// MUST run inside the caller's write transaction, AFTER the board(s) in
    /// `changedBoardIds` have already been persisted with their new stats.
    ///
    /// - Parameters:
    ///   - db: The active GRDB write transaction.
    ///   - changedBoardIds: The boards whose persisted stats just changed.
    ///   - now: The write timestamp for any re-derivation this triggers.
    ///   - authored: `true` (default) for a LOCAL write (Close / Reopen / late
    ///     log) — this device made the change, so it owns pushing the watcher
    ///     boards' new stats. The PULL cascades pass `false` (via
    ///     `refreshWatchersAfterPull`): the authoring peer already pushed its
    ///     own refresh, and watcher stats are a deterministic function of
    ///     converged data, so each receiving device re-derives in place (no
    ///     version bump, no enqueue) and never pushes back (no ping-pong).
    ///     Sealed watcher boards always re-derive non-authored either way.
    static func refreshWatchersForBoards(db: Database, changedBoardIds: Set<String>, now: String, authored: Bool = true) throws {
        guard !changedBoardIds.isEmpty else { return }
        var visited = Set<String>()
        var frontier = changedBoardIds
        // Fixpoint bound: cycles are already forbidden upstream (achievement
        // creation blocks a reference cycle), so this is a defensive belt,
        // not a real ceiling in practice.
        var iterations = 0
        while !frontier.isEmpty, iterations < 25 {
            iterations += 1
            visited.formUnion(frontier)

            let changedBoards = try frontier.compactMap { try Board.fetchOne(db, key: $0) }
            // Only ACHIEVEMENT rows can watch — fetch just those (the pull path
            // calls this once per pulled board), not the whole table.
            let achievementTasks = try Task.filter(Column("type") == TaskType.achievement.rawValue).fetchAll(db)
            let watcherIds = Set(findWatcherTaskIds(tasks: achievementTasks, changedBoards: changedBoards))
            guard !watcherIds.isEmpty else { break }

            let allBoardTasks = try BoardTask.filter(Column("isDeleted") == false).fetchAll(db)
            let allChildren = try CompoundChild.filter(Column("isDeleted") == false).fetchAll(db)
            var watcherBoardIds = Set<String>()
            for watcherId in watcherIds {
                let parents = DerivationPass.findTransitiveParentCompounds(changedTaskId: watcherId, children: allChildren)
                let ids = DerivationPass.findAffectedBoardIds(changedTaskId: watcherId, parentCompounds: parents, boardTasks: allBoardTasks)
                watcherBoardIds.formUnion(ids)
            }
            // Only NEWLY-reached boards continue the fixpoint / need re-deriving.
            watcherBoardIds.subtract(visited)
            guard !watcherBoardIds.isEmpty else { break }

            var sealedIds = Set<String>()
            var liveIds = Set<String>()
            for id in watcherBoardIds {
                guard let b = try Board.fetchOne(db, key: id), !b.isDeleted else { continue }
                if b.sealedAt != nil { sealedIds.insert(id) } else { liveIds.insert(id) }
            }

            for id in liveIds { try reDeriveLiveBoardTx(db: db, boardId: id, now: now, authored: authored) }
            if !sealedIds.isEmpty { try reDeriveSealedBoardSnapshots(db: db, boardIds: sealedIds) }

            frontier = watcherBoardIds
        }
    }

    // MARK: - Pull-path hooks (Board Edit post-merge sweep, findings 1 + 3)

    /// The achievement-watcher refresh for boards a PULL just changed —
    /// non-authored (see `refreshWatchersForBoards`). MUST run inside the
    /// pull's write transaction.
    static func refreshWatchersAfterPull(db: Database, boardIds: Set<String>) throws {
        try refreshWatchersForBoards(db: db, changedBoardIds: boardIds, now: currentTimestamp(), authored: false)
    }

    /// Side effects of an LWW-applied pulled `boards` row, inside the pull's
    /// write transaction (both `SyncService` pull paths call this):
    ///   - pulled SEALED → sealed-transport convergence: re-derive the frozen
    ///     snapshot from the LOCAL event union (a sealed-offline peer may have
    ///     derived it from a partial union) — local-only, no version / enqueue.
    ///   - pulled a REOPEN (sealed here, unsealed in the pulled row) → the row
    ///     carries the reopening device's live stats from ITS union, which may
    ///     lack this device's own late logs (made while sealed here, so only a
    ///     non-authored sealed re-derive ever counted them). Re-derive LIVE
    ///     from the local union, non-authored; the peer converges once it
    ///     pulls our late-log event (its taskEvents cascade is authored).
    ///   - either way, refresh this board's achievement watchers (non-authored).
    static func applyPulledBoardSideEffects(
        db: Database, boardId: String, remoteData: [String: Any], localData: [String: Any]?
    ) throws {
        if remoteData["sealedAt"] is String {
            try reDeriveSealedBoardSnapshots(db: db, boardIds: [boardId])
        } else if localData?["sealedAt"] is String {
            try reDeriveLiveBoardTx(db: db, boardId: boardId, now: currentTimestamp(), authored: false)
        }
        try refreshWatchersAfterPull(db: db, boardIds: [boardId])
    }

    // MARK: - D12 metadata-write guard (Archive / Repeat on a closed board)

    /// The relaxed editability guard D12 grants to exactly two metadata
    /// writes on a CLOSED board — Archive and Repeat's back-stamp: unlike
    /// `assertBoardEditable` (which also rejects a sealed board), only a
    /// missing / deleted board is rejected here. Neither write touches the
    /// frozen snapshot fields.
    ///
    /// - Throws: `BoardEditError.boardNotEditable` for a missing / deleted board.
    static func assertBoardMetadataWritable(db: Database, boardId: String) throws {
        guard let board = try Board.fetchOne(db, key: boardId), !board.isDeleted else {
            throw BoardEditError.boardNotEditable
        }
    }
}
