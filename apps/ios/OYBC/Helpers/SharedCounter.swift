import Foundation

// MARK: - Phase 1 Shared Counter Math
//
// Swift port of `packages/shared/src/algorithms/sharedCounter.ts`.
// Any change to the math there MUST be mirrored here to avoid
// cross-platform divergence. The TS file is the source of truth.
//
// Canonical design: ARCHITECTURE.md § "Shared counters (Issue #84 — Phase 0 design)"

/// Output of `deriveDisplayedCount(_:source:)`.
struct DeriveDisplayedCountResult {
    /// Count relative to the derived task's baseline, clamped to a minimum
    /// of 0. May exceed `derivedMaxCount` — NO high-end clamp per Phase 0
    /// Decision 2 + the counter-overshoot-invariant section.
    let displayed: Int
    /// True when `displayed >= derivedMaxCount`.
    let isCompleted: Bool
}

/// Derives the displayed count and completion snapshot for a derived counting
/// task that shares a source task's running total.
///
/// Invariants (from Phase 0 ARCHITECTURE.md):
///   - LOW-END CLAMP: `displayed` is always >= 0 via `max(0, ...)`.
///   - **NO HIGH-END CLAMP**: `displayed` is NOT clamped to `derivedMaxCount`.
///     If the source overshoots, the overshoot is intentionally visible.
///     There is NO `min(displayed, derivedMaxCount)` anywhere in this function.
///   - `isCompleted` is a snapshot — the one-way latch lives on Task in Phase 3.
///
/// - Parameters:
///   - derivedBaseline: The source count at link time (Decision 6). `0` means
///     "inherit from source start" (no offset); non-zero means "start from zero"
///     (source value was `baseline` when the derived task was created).
///   - derivedMaxCount: The derived task's personal threshold.
///   - sourceCurrentCount: The live running total on the source task.
/// - Returns: `DeriveDisplayedCountResult` with `displayed` and `isCompleted`.
func deriveDisplayedCount(
    derivedBaseline: Int,
    derivedMaxCount: Int,
    sourceCurrentCount: Int
) -> DeriveDisplayedCountResult {
    // LOW-END CLAMP ONLY — no high-end clamp (see invariants above).
    let displayed = max(0, sourceCurrentCount - derivedBaseline)

    // maxCount == 0 → immediately complete (cannot be below zero progress).
    let isCompleted = displayed >= derivedMaxCount

    return DeriveDisplayedCountResult(displayed: displayed, isCompleted: isCompleted)
}
