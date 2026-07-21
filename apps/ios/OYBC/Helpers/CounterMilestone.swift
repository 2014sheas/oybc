import Foundation

// MARK: - Counter Milestone (R2 Counters UX refresh)
//
// Swift port of `packages/shared/src/algorithms/counterMilestone.ts`. Lifted
// from the drift-prone local `milestone` computed property that used to live
// directly on `CounterDetailContent` (`Views/ProfileTab/CounterDetailView.swift`)
// — that call site now consumes this single implementation instead of
// hand-maintaining the same step list twice. See docs/SHARED_COUNTERS.md
// §Counters UX refresh.
//
// Pure, deterministic: a function of `lifetime` alone. Any change to the
// math in the TS source MUST be mirrored here.

/// Fixed round-number steps a counter climbs through on its way up. Beyond
/// the top step (100,000), `nextCounterMilestone` falls back to the next
/// multiple of 10,000.
private let counterMilestoneSteps: [Int] = [
    100, 250, 500, 1_000, 2_500, 5_000, 10_000, 25_000, 50_000, 100_000,
]

/// The next round-number milestone strictly above `lifetime`.
///
/// Matches the TS implementation exactly: the first fixed step greater than
/// `lifetime`, or — once past the top fixed step — the next multiple of
/// 10,000 strictly above `lifetime` (`ceil((lifetime + 1) / 10_000) * 10_000`,
/// computed here via the integer ceil-division identity
/// `(n + 9_999) / 10_000` to avoid floating-point rounding at large values).
///
/// - Parameter lifetime: Non-negative lifetime total (overshoot beyond a
///   task's own `maxCount` is fine — this helper only cares about the raw
///   number).
/// - Returns: The next milestone, always strictly greater than `lifetime`.
func nextCounterMilestone(_ lifetime: Int) -> Int {
    if let fixedStep = counterMilestoneSteps.first(where: { $0 > lifetime }) {
        return fixedStep
    }
    let n = lifetime + 1
    return ((n + 9_999) / 10_000) * 10_000
}

/// Progress toward the next milestone, for a progress bar / "N to go" caption.
struct CounterMilestoneProgress: Equatable {
    /// The next milestone (see `nextCounterMilestone`).
    let next: Int
    /// How much further the counter has to climb to reach `next`.
    let remaining: Int
    /// `lifetime / next`, clamped to `[0, 1]` — a progress-bar fill fraction.
    let fraction: Double
}

/// Derives the next milestone plus remaining/fraction for a progress bar.
///
/// - Parameter lifetime: Non-negative lifetime total.
/// - Returns: `{ next, remaining, fraction }`. `fraction` is
///   `min(1, lifetime / next)`; `remaining` is `next - lifetime`.
func counterMilestoneProgress(_ lifetime: Int) -> CounterMilestoneProgress {
    let next = nextCounterMilestone(lifetime)
    let remaining = next - lifetime
    let fraction = min(1.0, Double(lifetime) / Double(next))
    return CounterMilestoneProgress(next: next, remaining: remaining, fraction: fraction)
}
