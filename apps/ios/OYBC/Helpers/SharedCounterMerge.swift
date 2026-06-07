import Foundation

// MARK: - Phase 4 Shared Counter Sync — Additive-Merge Conflict Resolution
//
// Swift port of `packages/shared/src/algorithms/sharedCounterMerge.ts`.
// Any change to the math there MUST be mirrored here to avoid
// cross-platform divergence. The TS file is the source of truth.
//
// Canonical design: ARCHITECTURE.md §Shared counters — Phase 4 design
//
// ## Why additive merge is needed
//
// Plain LWW silently loses count increments when two devices both increment
// the same shared-counter source while offline:
//
//   Both start at 10. Device A: +5 → 15. Device B: +3 → 13.
//   Both push. LWW picks 15. Expected: 18 (10+5+3). 3 lost.
//
// Three-way merge preserves both deltas:
//   mergedCount = remote.currentCount + (local.currentCount - lastSyncedCount)
//               = 13 + (15 - 10) = 18  ✓

/// Output of `additiveMergeCount(_:remote:lastSyncedCount:)`.
struct MergeCountResult {
    /// The resolved `currentCount` to write to GRDB and push to Firestore.
    /// Clamped to a minimum of 0 (low-end only). NO high-end clamp —
    /// overshoot is valid per `feedback_counter_overshoot_is_valid`.
    let merged: Int
    /// True when additive merge was applied; false when LWW was used
    /// (e.g., `lastSyncedCount` was nil — no common ancestor).
    let mergeApplied: Bool
}

/// Resolves a concurrent-increment conflict for a shared-counter source task
/// using three-way additive merge.
///
/// Call this when:
///   1. The task is a shared-counter source (other tasks reference it via `sharedCounterId`).
///   2. Both local and remote `currentCount` differ from `lastSyncedCount`
///      (both devices incremented since their common ancestor).
///
/// Formula:
///   mergedCount = remoteCount + (localCount - lastSyncedCount)
///
/// - Parameters:
///   - localCount: The local device's `Task.currentCount` AFTER local increments.
///   - remoteCount: The remote Firestore document's `currentCount`.
///   - lastSyncedCount: The common-ancestor value (last confirmed sync). Nil → LWW fallback.
/// - Returns: `MergeCountResult` with `merged` and `mergeApplied`.
func additiveMergeCount(
    localCount: Int,
    remoteCount: Int,
    lastSyncedCount: Int?
) -> MergeCountResult {
    guard let base = lastSyncedCount else {
        // No common ancestor → LWW fallback (local wins on tie).
        let lwwWinner = max(localCount, remoteCount)
        return MergeCountResult(merged: max(0, lwwWinner), mergeApplied: false)
    }

    // Three-way merge: apply local delta on top of remote.
    // localDelta may be negative (the user decremented to correct an over-count).
    let localDelta = localCount - base
    let raw = remoteCount + localDelta

    // LOW-END CLAMP: merged must not go below 0.
    // NO HIGH-END CLAMP: overshoot is intentional — NO min(raw, maxCount).
    return MergeCountResult(merged: max(0, raw), mergeApplied: true)
}

/// Returns true when both local and remote `currentCount` have deviated from
/// `lastSyncedCount`, indicating concurrent edits that require additive merge.
///
/// Returns false (LWW is sufficient) when:
///   - Only one device changed.
///   - `lastSyncedCount` is nil (no common ancestor; LWW fallback).
///   - Neither device changed (counts match the common ancestor).
///
/// - Parameters:
///   - localCount: The local device's current `Task.currentCount`.
///   - remoteCount: The remote Firestore `currentCount`.
///   - lastSyncedCount: The common-ancestor value. Nil → always false.
/// - Returns: True if additive merge should fire; false if LWW is sufficient.
func needsAdditiveMerge(
    localCount: Int,
    remoteCount: Int,
    lastSyncedCount: Int?
) -> Bool {
    guard let base = lastSyncedCount else { return false }
    let localChanged = localCount != base
    let remoteChanged = remoteCount != base
    return localChanged && remoteChanged
}
