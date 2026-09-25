import Foundation
import GRDB

// MARK: - AppDatabase + Board-context completion writes

/// The board-context completion write paths (Windowed Completion, docs
/// §Write paths): `completeTaskOrchestrated` (a play-surface tap) and
/// `toggleCompoundChildFallback` (a compound child not placed on the host
/// board). Split out of `AppDatabase+Tasks.swift` when the 2026-09-24
/// amendment of WC Decision 1 (end-bounded windows, late-log stamp, sealed
/// guard) pushed that file past the 1000-line drift-guardrail ceiling — a
/// move along an existing seam, no behaviour change beyond the amendment.
extension AppDatabase {
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
    /// the Task sync entry), all inside THIS transaction. The board's window is
    /// `[startDate, endDate]` (2026-09-24 amendment of WC Decision 1): the
    /// delta read and the un-complete tombstone are bounded at both ends, and
    /// the appended event is stamped `lateLogOccurredAt(board, now)` — `now`
    /// while the window is open, the board's `endDate` once it has ended — so
    /// a log on an ended-but-unsealed board counts there and on no later
    /// window's board.
    ///
    /// A SEALED board is a no-op (no event, no write, empty result): its record
    /// is permanent and its surface is play-locked anyway. The sealed check
    /// reads the board row inside the transaction, so a seal that landed after
    /// the caller loaded `board` still wins. Mirrors web `handleTaskCompletion`.
    ///
    /// - Parameters:
    ///   - board: The current board (its `.draft` → `.active` flip happens here).
    ///   - taskId: The event-owning Task the user tapped (normal or plain/source
    ///     counting).
    ///   - intent: The desired windowed state (see `CompletionIntent`).
    ///   - boardTask: The `BoardTask` placement record on the current board
    ///     (its `updatedAt`/`version` are bumped + sync-queued).
    ///   - now: ISO8601 timestamp stamped on every row written here.
    /// - Returns: A `[boardId: CascadeBoardResult]` map for flash derivation
    ///   (empty for a sealed board).
    func completeTaskOrchestrated(
        board: Board,
        taskId: String,
        intent: CompletionIntent,
        boardTask: BoardTask,
        now: String
    ) throws -> [String: CascadeBoardResult] {
        try write { db in
            // 0. Sealed guard — a sealed board's record never mutates here.
            let current = try Board.fetchOne(db, key: board.id) ?? board
            if current.sealedAt != nil { return [:] }

            // 1. Auto-activate DRAFT boards on first interaction. Copies the
            //    row read inside THIS transaction (`current`), never the
            //    caller's possibly-stale `board`, so no newer field is clobbered.
            if current.status == .draft {
                var activated = current
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
            let windowStart = current.startDate
            let windowEnd = boardWindowEnd(current)
            let occurredAt = lateLogOccurredAt(board: current, nowIso: now)
            switch intent {
            case .setCompleted(let desired):
                if desired {
                    try Self.appendCompletionEvent(
                        db: db, taskId: taskId, boardId: board.id, now: now, occurredAt: occurredAt
                    )
                } else {
                    try Self.tombstoneWindowCompletions(
                        db: db, taskId: taskId, windowStart: windowStart, now: now, windowEnd: windowEnd
                    )
                }
            case .setWindowedCount(let desired):
                let windowedCount = try Self.windowedState(
                    db: db, taskId: taskId, windowStart: windowStart, windowEnd: windowEnd
                ).count
                var delta = desired - windowedCount
                // Gate a decrement so the window sum stays ≥ 0 (belt against a
                // local gesture poisoning the window with a dangling negative).
                if delta < 0 { delta = max(delta, -windowedCount) }
                if delta != 0 {
                    try Self.appendIncrementEvent(
                        db: db, taskId: taskId, delta: delta, boardId: board.id, now: now, occurredAt: occurredAt
                    )
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
    /// to the host board's window `[windowStart, windowEnd]` (2026-09-24
    /// amendment). Complete → append a completion event stamped with the host
    /// board's late-log stamp (`lateLogStampForBoard` — its `endDate` once its
    /// window has ended); un-complete → tombstone only the completions inside
    /// the host window, so another window's completion (e.g. the next window's
    /// board, completed today) is never deleted from this board's sheet.
    ///
    /// The caller passes `desiredCompleted` from the WINDOWED state the detail
    /// sheet paints (`BoardPlayViewModel.compoundChildIsCompleted`), never the
    /// lifetime latch. A sealed host board is a no-op (empty result). Mirrors
    /// the web `toggleCompoundChildFallback` (`tasks.crud.ts`).
    ///
    /// ONE rule on both platforms: the fallback WRITES only for an
    /// event-owning child (NORMAL / plain COUNTING — events + the late-log
    /// stamp). A NON-event-owning child is a no-op — early return, empty
    /// result: no latch write, no event, no sync enqueue, and no cascade
    /// (nothing changed). Its state is never authored from here: a hub-linked
    /// derived counter's latch is propagation output from its ROOT, a
    /// window-stamped derived row is never authored (it resolves from the
    /// root's in-window events and freezes once its window ends), and a nested
    /// compound is derived from its own children.
    ///
    /// - Parameters:
    ///   - childTaskId: The event-owning child Task being toggled.
    ///   - desiredCompleted: The desired windowed completed state.
    ///   - windowStart: The host board's `startDate` (window lower bound).
    ///   - windowEnd: The host board's inclusive upper bound
    ///     (`boardWindowEnd(board)`), or `nil` for an indefinite board.
    ///   - boardId: The host board id (event provenance + late-log stamp).
    ///   - now: ISO8601 timestamp stamped on every row written here.
    /// - Returns: A `[boardId: CascadeBoardResult]` map for flash derivation
    ///   (empty for a sealed host board or a non-event-owning / missing child).
    func toggleCompoundChildFallback(
        childTaskId: String,
        desiredCompleted: Bool,
        windowStart: String,
        windowEnd: String?,
        boardId: String?,
        now: String
    ) throws -> [String: CascadeBoardResult] {
        try write { db in
            if let boardId, try Board.fetchOne(db, key: boardId)?.sealedAt != nil { return [:] }
            // Non-event-owning (or missing) child: nothing is authored (see the rule above).
            guard let child = try Task.fetchOne(db, key: childTaskId), isEventOwningTask(child) else { return [:] }
            if desiredCompleted {
                let occurredAt = try Self.lateLogStampForBoard(db: db, boardId: boardId, now: now)
                try Self.appendCompletionEvent(
                    db: db, taskId: childTaskId, boardId: boardId, now: now, occurredAt: occurredAt
                )
            } else {
                try Self.tombstoneWindowCompletions(
                    db: db, taskId: childTaskId, windowStart: windowStart, now: now, windowEnd: windowEnd
                )
            }

            return try Self.runBoardCascadeForTaskWithResults(
                db: db,
                changedTaskId: childTaskId,
                now: now
            )
        }
    }
}
