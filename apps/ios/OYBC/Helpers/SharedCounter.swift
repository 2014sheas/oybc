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

// MARK: - Phase 3 Shared Counter Propagation
//
// Swift port of `propagateIncrement` in
// `packages/shared/src/algorithms/sharedCounter.ts`. Same source-of-truth rule
// as above — mirror any math change there. The DB layer owns the writes; this
// function is pure.

/// Minimal slice of one linked (derived) task as needed by `propagateIncrement`.
/// Mirrors TS `PropagateIncrementLinkedTask`.
struct PropagateIncrementLinkedTask {
    let id: String
    /// The baseline offset for this linked task (0 = inherit; nil → 0).
    let baseline: Int?
    /// This linked task's personal threshold (nil → 0).
    let maxCount: Int?
    /// The task's persisted `isCompleted` value BEFORE this increment.
    /// One-way latch: if already `true`, the result keeps it `true`.
    let isCompleted: Bool
}

/// The new state to write for one linked task after a source increment.
/// Mirrors TS `LinkedTaskIncrementResult`.
struct LinkedTaskIncrementResult {
    let taskId: String
    /// New `currentCount` to store on the linked task (mirrors source's new
    /// count so cascade readers see the same number without re-deriving).
    let newCurrentCount: Int
    /// New `isCompleted` to store. One-way latch — never transitions from
    /// `true` to `false`; may transition `false` → `true` when the derived
    /// displayed value first reaches or exceeds `maxCount`.
    let newIsCompleted: Bool
    /// The derived display value (= `sourceAfterCurrentCount - baseline`,
    /// clamped to 0). Callers should render this, NOT `newCurrentCount`.
    let displayed: Int
}

/// Pure propagation helper for Phase 3's increment hot-path.
///
/// Given the source task's new `currentCount` (AFTER the increment) and an
/// array of all linked (derived) tasks, returns the new `currentCount` and
/// `isCompleted` to write for each linked task — one entry per linked task, in
/// the same order.
///
/// Invariants enforced (mirror `sharedCounter.ts`):
///   - NO HIGH-END CLAMP on source: callers must never clamp
///     `sourceAfterCurrentCount` before passing it in.
///   - ONE-WAY LATCH: if `linked.isCompleted` is already `true`, the result
///     keeps `newIsCompleted = true` regardless of the derived value.
///   - LOW-END CLAMP on display: `displayed` is never negative.
///   - Tasks with no `maxCount` (nil/0) are immediately complete.
///
/// Pure function — no DB calls, no side effects. The DB layer owns writes.
///
/// - Parameters:
///   - sourceAfterCurrentCount: Source task's `currentCount` AFTER the increment.
///   - linkedTasks: All tasks whose `sharedCounterId` == the source task id.
///     Pass only non-deleted tasks.
/// - Returns: One `LinkedTaskIncrementResult` per entry in `linkedTasks`, in
///   the same order.
func propagateIncrement(
    sourceAfterCurrentCount: Int,
    linkedTasks: [PropagateIncrementLinkedTask]
) -> [LinkedTaskIncrementResult] {
    return linkedTasks.map { linked in
        let derived = deriveDisplayedCount(
            derivedBaseline: linked.baseline ?? 0,
            derivedMaxCount: linked.maxCount ?? 0,
            sourceCurrentCount: sourceAfterCurrentCount
        )

        // ONE-WAY LATCH: once true, always true.
        let newIsCompleted = linked.isCompleted || derived.isCompleted

        return LinkedTaskIncrementResult(
            taskId: linked.id,
            // Mirror the source's current count so the linked task row carries
            // the same accumulator value. Cascade readers read this
            // currentCount and re-derive with the baseline.
            newCurrentCount: sourceAfterCurrentCount,
            newIsCompleted: newIsCompleted,
            displayed: derived.displayed
        )
    }
}
