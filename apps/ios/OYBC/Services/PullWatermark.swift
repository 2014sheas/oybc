import Foundation
import FirebaseFirestore

/// A Firestore server `_syncedAt` instant, kept exact as seconds + nanoseconds
/// (no float rounding) — the per-collection pull checkpoint (2026-10-07, the
/// launch-watchdog fix). Swift twin of `PullWatermark` in
/// `packages/shared/src/algorithms/pullWatermark.ts`, pinned by
/// `pullWatermarkVectors.json`.
///
/// The value is the SERVER instant of the newest applied doc, never the local
/// clock, so the pull path has no clock-skew window. Resume queries use `>=`,
/// so same-instant siblings of the last applied doc are re-read and the echo
/// guard skips them.
struct PullWatermark: Codable, Hashable, Comparable, Sendable {
    let seconds: Int64
    let nanoseconds: Int32

    init(seconds: Int64, nanoseconds: Int32) {
        self.seconds = seconds
        self.nanoseconds = nanoseconds
    }

    /// Floors `date` to whole nanoseconds. Flooring is the safe direction for
    /// a `>=` resume query (it can only re-read, never skip).
    ///
    /// - Parameter date: The instant to convert.
    init(date: Date) {
        let t = date.timeIntervalSince1970
        let whole = t.rounded(.down)
        let nanos = min(999_999_999, max(0, Int32(((t - whole) * 1_000_000_000).rounded(.down))))
        self.init(seconds: Int64(whole), nanoseconds: nanos)
    }

    /// Reads a doc's raw `_syncedAt` value: a Firestore `Timestamp` (live
    /// pulls) or a `Date` (test sources).
    ///
    /// - Parameter syncedAtValue: The raw `_syncedAt` field, if any.
    /// - Returns: nil for a missing / pending (`NSNull`) / unknown value.
    init?(syncedAtValue: Any?) {
        if let ts = syncedAtValue as? Timestamp {
            self.init(seconds: ts.seconds, nanoseconds: ts.nanoseconds)
        } else if let date = syncedAtValue as? Date {
            self.init(date: date)
        } else {
            return nil
        }
    }

    /// The Firestore query operand for this instant.
    var timestamp: Timestamp { Timestamp(seconds: seconds, nanoseconds: nanoseconds) }

    static func < (lhs: PullWatermark, rhs: PullWatermark) -> Bool {
        lhs.seconds != rhs.seconds ? lhs.seconds < rhs.seconds : lhs.nanoseconds < rhs.nanoseconds
    }
}

/// The checkpoint after applying one batch: the max of `prev` and every
/// non-nil instant in the batch. Never moves backwards. Twin of
/// `nextPullWatermark` in `@oybc/shared`.
///
/// - Parameters:
///   - prev: The stored checkpoint, or nil when none.
///   - syncedAts: The batch's `_syncedAt` instants (nil for a doc without one).
/// - Returns: The new checkpoint, or nil when neither side has a value.
func nextPullWatermark(_ prev: PullWatermark?, _ syncedAts: [PullWatermark?]) -> PullWatermark? {
    syncedAts.reduce(prev) { best, at in
        guard let at else { return best }
        guard let best else { return at }
        return max(best, at)
    }
}

/// The order the pull applies collections in (full pull loop + listener
/// attach) — dependency order, so each collection's cascade sees every input
/// it reads. Must equal `@oybc/shared`'s `PULL_APPLY_ORDER` (order-sensitive),
/// enforced by `SyncContractTests` against `syncContract.json`. The push path
/// keeps `syncableCollections` order.
let pullApplyOrder: [String] = [
    "tasks",
    "compoundChildren",
    "taskEvents",
    "boards",
    "boardTasks",
    "recurringBoardTemplates",
    "pools",
    "coreBoardDefaults",
]

/// `pullApplyOrder` as `(firestoreName, grdbTable)` pairs from
/// `syncableCollections`.
let pullApplyCollections: [(firestoreName: String, grdbTable: String)] = pullApplyOrder.compactMap { name in
    syncableCollections.first { $0.firestoreName == name }
}
