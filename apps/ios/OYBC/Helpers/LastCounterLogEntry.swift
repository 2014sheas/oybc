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

/// Selects the most-recent non-deleted `.increment` event for a counter's
/// source task — the entry a fresh "Undo" tap reverses.
///
/// Excludes the seed/backfill sentinel (`TaskEvents.seedEventOccurredAt`): a
/// starting-count seed is not a "log" a user can undo. Ties (identical
/// `occurredAt`, which can happen for rapid-fire logs sharing a millisecond)
/// break on `createdAt`, so the selector is deterministic even when two
/// events share the same semantic timestamp.
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

/// `true` iff `candidate` is more recent than `current` (occurredAt, then
/// createdAt tie-break). Unparseable timestamps degrade to `.distantPast`,
/// mirroring the TS twin's `NaN`-comparison-always-false degrade.
private func isMoreRecent(_ candidate: TaskEvent, than current: TaskEvent) -> Bool {
    let candidateOccurred = DateFormatting.parseISO(candidate.occurredAt) ?? .distantPast
    let currentOccurred = DateFormatting.parseISO(current.occurredAt) ?? .distantPast
    if candidateOccurred != currentOccurred { return candidateOccurred > currentOccurred }

    let candidateCreated = DateFormatting.parseISO(candidate.createdAt) ?? .distantPast
    let currentCreated = DateFormatting.parseISO(current.createdAt) ?? .distantPast
    return candidateCreated > currentCreated
}
