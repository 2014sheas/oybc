import Foundation

// MARK: - Counter Arrivals (Swift port of counterArrivals.ts)
//
// Swift port of `packages/shared/src/algorithms/counterArrivals.ts`.
// Any change to the math there MUST be mirrored here to avoid cross-platform
// divergence. The TS file is the source of truth.
//
// The "arrival banner" signature moment: when a shared counter is logged
// ELSEWHERE (its Counter Detail, or another board — same device in the MVP),
// the P2 engine has already fanned the increment out to this board's square
// (marked done, bingo recomputed) in one transaction. This helper is the pure
// DETECTION layer: on board open, it diffs each shared-counting square's
// current displayed value against a LOCAL last-seen snapshot (persisted per
// board in UserDefaults — NOT synced schema) and reports which squares
// "arrived" (increased since last view) so the UI can banner + pulse.
//
// Increase-only: a decrement made elsewhere never triggers an arrival. A
// square with no last-seen entry is a first view — it establishes the
// baseline and is NOT an arrival.
//
// Canonical design: docs/SHARED_COUNTERS.md §P3. The 8 fixture vectors in
// `OYBCTests/CounterArrivalsVectorTests.swift` (from
// `packages/shared/tests/fixtures/counterArrivalsVectors.json`) mirror those
// exercised on the TS side by `packages/shared/tests/algorithms/counterArrivals.test.ts`.

// MARK: - Types

/// One shared-counting square on the board being opened. Mirrors the TS
/// `ArrivalSquare` interface.
struct ArrivalSquare {
    /// The square's task id (a board_task's taskId). Keys the last-seen snapshot.
    let taskId: String
    /// The shared counter's source task id — used to deep-link the banner to Counter Detail.
    let counterId: String
    /// The counter's display name — used in the banner copy.
    let counterName: String
    /// The square's current displayed count (post cross-board fan-out).
    let displayed: Int
}

/// One distinct counter that arrived, aggregated across its squares on this
/// board. Mirrors the TS `ArrivedCounter` interface.
struct ArrivedCounter: Equatable {
    let counterId: String
    let counterName: String
    /// How many squares on this board arrived from this counter.
    var squareCount: Int
}

/// Mirrors the TS `CounterArrivalResult` interface.
struct CounterArrivalResult {
    /// Task ids of arrived squares — for the gold pulse.
    let arrivedTaskIds: [String]
    /// Distinct arrived counters (for the banner), sorted by name.
    let arrivedCounters: [ArrivedCounter]
    /// Total arrived squares across all counters (drives the "N squares" copy).
    let totalArrivedSquares: Int
}

// MARK: - Algorithm

/// Detect which shared-counting squares arrived since the board was last viewed.
///
/// - Parameters:
///   - lastSeen: taskId → displayed count when this board was last viewed. An
///     absent taskId is a first view (establishes a baseline, never an arrival).
///   - squares: The board's current shared-counting squares.
/// - Returns: Arrived task ids (to pulse), distinct arrived counters (for the
///   banner), and the total arrived-square count. All empty when nothing arrived.
func detectCounterArrivals(
    lastSeen: [String: Int],
    squares: [ArrivalSquare]
) -> CounterArrivalResult {
    var arrivedTaskIds: [String] = []
    var byCounter: [String: ArrivedCounter] = [:]
    var counterOrder: [String] = []

    for sq in squares {
        // First view (no baseline) is never an arrival — it seeds the baseline.
        guard let seen = lastSeen[sq.taskId] else { continue }
        if sq.displayed > seen {
            arrivedTaskIds.append(sq.taskId)
            if var existing = byCounter[sq.counterId] {
                existing.squareCount += 1
                byCounter[sq.counterId] = existing
            } else {
                byCounter[sq.counterId] = ArrivedCounter(
                    counterId: sq.counterId,
                    counterName: sq.counterName,
                    squareCount: 1
                )
                counterOrder.append(sq.counterId)
            }
        }
    }

    let arrivedCounters = counterOrder
        .compactMap { byCounter[$0] }
        .sorted { $0.counterName.localizedCaseInsensitiveCompare($1.counterName) == .orderedAscending }

    return CounterArrivalResult(
        arrivedTaskIds: arrivedTaskIds,
        arrivedCounters: arrivedCounters,
        totalArrivedSquares: arrivedTaskIds.count
    )
}

/// Build the next last-seen snapshot to persist (taskId → displayed) from the
/// board's current shared-counting squares. Call on board disappear (and
/// after an arrival is shown) so a local tap or an acknowledged arrival
/// doesn't re-trigger the banner on the next open.
///
/// The TS twin accepts a narrower structural type (`{ taskId, displayed }[]`)
/// since only those two fields are read; Swift has no structural typing, so
/// this takes `[ArrivalSquare]` directly — callers already hold that type
/// from `detectCounterArrivals`, and only `taskId`/`displayed` are used here.
///
/// - Parameter squares: The board's current shared-counting squares.
func snapshotCounterSquares(squares: [ArrivalSquare]) -> [String: Int] {
    var out: [String: Int] = [:]
    for sq in squares { out[sq.taskId] = sq.displayed }
    return out
}
