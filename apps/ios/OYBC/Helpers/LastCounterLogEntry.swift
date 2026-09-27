import Foundation

// MARK: - Last Counter Log Entry (R2 Counters UX refresh)
//
// Swift port of `packages/shared/src/algorithms/lastCounterLogEntry.ts` —
// picks the most recent real log entry for a counter's Undo affordance
// ("Logged +N · Undo" toast, docs/SHARED_COUNTERS.md §Counters UX refresh
// → Amount logging).
//
// The platform Undo op (`AppDatabase.undoLastCounterLog`) calls this PURE
// selector first to find which event to reverse, then does the actual write
// (tombstone the event, subtract its `delta` from the source task's
// `currentCount`, re-run the cross-board cascade). This module only picks
// the entry — it never mutates anything.
//
// "Most recent" means the entry the user most recently MADE — ordered by
// `createdAt` (write time), not `occurredAt`. Since the 2026-09-24 amendment
// of WC Decision 1, a late log on an ended board is stamped at that board's
// `endDate` (`lateLogOccurredAt`), in the past, so `occurredAt` no longer
// tracks the order the user logged in: ordering by it would make Undo reverse
// an earlier-made entry instead of the late log just made.

/// Selects the most-recent non-deleted `.increment` event for a counter's
/// source task — the entry a fresh "Undo" tap reverses.
///
/// Excludes the seed/backfill sentinel (`TaskEvents.seedEventOccurredAt`): a
/// starting-count seed is not a "log" a user can undo. Ordered by `createdAt`
/// (the entry the user most recently made — a late log's `occurredAt` is
/// clamped into the past, see the file header); ties (identical `createdAt`,
/// which can happen for rapid-fire logs sharing a millisecond) break on
/// `occurredAt`, so the selector is deterministic.
///
/// - Parameters:
///   - events: Candidate events (typically the source task's full event set
///     — filtering to `taskId`/`kind`/`isDeleted`/sentinel happens
///     internally, so callers may pass an unfiltered array).
///   - sourceTaskId: The counter's source task id.
/// - Returns: The most recent qualifying event, or `nil` if there is none
///   (e.g. a brand-new counter, or one whose only event is its seed).
func selectLastIncrementEntry(events: [TaskEvent], sourceTaskId: String) -> TaskEvent? {
    var best: TaskEvent?

    for event in events {
        guard event.taskId == sourceTaskId else { continue }
        guard event.kind == .increment else { continue }
        guard !event.isDeleted else { continue }
        guard event.occurredAt != TaskEvents.seedEventOccurredAt else { continue }

        if let current = best {
            if isMoreRecent(event, than: current) { best = event }
        } else {
            best = event
        }
    }

    return best
}

/// `true` iff `candidate` is more recent than `current`: `createdAt` (write
/// time) first, then `occurredAt` as the tie-break. Unparseable timestamps
/// degrade to `.distantPast`, mirroring the TS twin's
/// `NaN`-comparison-always-false degrade.
private func isMoreRecent(_ candidate: TaskEvent, than current: TaskEvent) -> Bool {
    let candidateCreated = DateFormatting.parseISO(candidate.createdAt) ?? .distantPast
    let currentCreated = DateFormatting.parseISO(current.createdAt) ?? .distantPast
    if candidateCreated != currentCreated { return candidateCreated > currentCreated }

    let candidateOccurred = DateFormatting.parseISO(candidate.occurredAt) ?? .distantPast
    let currentOccurred = DateFormatting.parseISO(current.occurredAt) ?? .distantPast
    return candidateOccurred > currentOccurred
}

// MARK: - Closed-board late logs (Board Edit redesign slice 4, D10 / R2)

/// Selects the late logs a user made directly on a CLOSED board for one task,
/// newest first — the only sealed-window events that stay undoable (owner
/// ruling R2). Identified by provenance + timestamps, never a marker field:
/// non-deleted, `taskId` matches, `boardId == boardId`, `occurredAt` is the
/// board's `endDate` INSTANT (parsed compare — the late-log path re-encodes the
/// local-ISO `endDate` as UTC), `createdAt` strictly after `sealedAt`; any
/// kind. Ordered by `createdAt` descending, ties by `id` descending. An
/// unsealed board, or one with no parseable `endDate` / `sealedAt`, has none.
/// Mirrors the TS `selectClosedBoardLateLogs`.
///
/// - Parameters:
///   - events: Candidate events (may be unfiltered).
///   - boardId: The closed board's id.
///   - endDate: The board's window end (ISO8601), nil for indefinite.
///   - sealedAt: When the board closed (ISO8601), nil if unsealed.
///   - taskId: The task whose late logs to select (for a window-stamped derived
///     square, the ROOT counter — derived rows own no events).
/// - Returns: The qualifying events, newest `createdAt` first.
func selectClosedBoardLateLogs(
    events: [TaskEvent],
    boardId: String,
    endDate: String?,
    sealedAt: String?,
    taskId: String
) -> [TaskEvent] {
    guard let end = endDate.flatMap(DateFormatting.parseISO),
          let sealed = sealedAt.flatMap(DateFormatting.parseISO) else { return [] }
    let endMs = (end.timeIntervalSince1970 * 1000).rounded()
    let sealedMs = sealed.timeIntervalSince1970 * 1000

    func ms(_ iso: String) -> Double? {
        DateFormatting.parseISO(iso).map { ($0.timeIntervalSince1970 * 1000).rounded() }
    }

    let lateLogs = events.filter { e in
        guard !e.isDeleted, e.taskId == taskId, e.boardId == boardId else { return false }
        guard let occurred = ms(e.occurredAt), occurred == endMs else { return false }
        guard let created = DateFormatting.parseISO(e.createdAt) else { return false }
        return created.timeIntervalSince1970 * 1000 > sealedMs
    }
    return lateLogs.sorted { a, b in
        let ca = ms(a.createdAt) ?? 0
        let cb = ms(b.createdAt) ?? 0
        if ca != cb { return ca > cb }
        return a.id > b.id
    }
}

/// Convenience overload of `selectClosedBoardLateLogs` for a `Board` row.
func selectClosedBoardLateLogs(events: [TaskEvent], board: Board, taskId: String) -> [TaskEvent] {
    selectClosedBoardLateLogs(
        events: events,
        boardId: board.id,
        endDate: board.endDate,
        sealedAt: board.sealedAt,
        taskId: taskId
    )
}
