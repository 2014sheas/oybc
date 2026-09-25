import Foundation

/// CompoundEvaluation — pure evaluator for compound Tasks.
///
/// Swift twin of `@oybc/shared`'s `evaluateCompound`. Takes pre-fetched maps
/// (no DB I/O, no caller-visible side effects) and computes whether a compound
/// Task's operator condition is satisfied by its children's states.
///
/// Recurses into nested compounds, with cycle detection.
/// Filters soft-deleted children.
/// Treats unresolvable childTaskId / soft-deleted child Task as incomplete.
/// Non-compound inputs return `task.isCompleted` directly (defensive uniform
/// lookup).
///
/// **Cycle handling.** A `compound_children` cycle (e.g., A→B→A) can in
/// principle land via sync of malformed data. If evaluation hits a compound
/// already on the recursion stack, the back-edge is treated as `false` for
/// that branch (and the rest of the operator evaluates normally). Deterministic,
/// bounded, never traps — preferred to a stack overflow that would brick board
/// derivation across the entire workspace.
enum CompoundEvaluation {

    /// Evaluate whether a compound Task is complete.
    ///
    /// **Windowed evaluation (Windowed Completion, PR A/B).** When
    /// `windowContext` is supplied, primitive children resolve against the host
    /// board's window via `resolveTaskWindowState` instead of reading the
    /// lifetime `isCompleted` cache; derived (shared-counter-linked) counting
    /// children fall back to their cache (the carve-out); nested compounds
    /// inherit the SAME window (host-window inheritance). When `windowContext`
    /// is omitted the behavior is byte-identical to before — the lifetime
    /// default that keeps every existing caller unchanged.
    ///
    /// - Parameters:
    ///   - compound: The Task to evaluate. If `type != .compound`, returns
    ///     `compound.isCompleted` directly.
    ///   - childrenByCompound: Map of `compoundTaskId` → list of CompoundChild
    ///     rows. Caller may pass non-deleted rows only, or all rows — this
    ///     function filters `isDeleted` links itself.
    ///   - taskById: Map of `taskId` → Task. Missing keys evaluate the child as
    ///     incomplete.
    ///   - windowContext: Optional. When present, switches primitive-child
    ///     resolution to windowed events (see above).
    /// - Returns: `true` if the compound's operator condition is satisfied.
    static func evaluate(
        compound: Task,
        childrenByCompound: [String: [CompoundChild]],
        taskById: [String: Task],
        windowContext: CompoundWindowContext? = nil
    ) -> Bool {
        var visiting: Set<String> = []
        return evaluateInner(
            compound: compound,
            childrenByCompound: childrenByCompound,
            taskById: taskById,
            visiting: &visiting,
            windowContext: windowContext
        )
    }

    /// Resolve a single primitive (non-compound) child's completion, honoring
    /// the window context when present. Window-stamped derived counters
    /// resolve from their root's events; hub-linked derived-counting children
    /// are carved out (read their lifetime cache); every other event-owning
    /// primitive resolves windowed. Mirrors the TS `resolvePrimitiveChildState`.
    private static func resolvePrimitiveChildState(
        _ child: Task,
        _ windowContext: CompoundWindowContext?
    ) -> Bool {
        guard let windowContext else { return child.isCompleted }
        // Window-stamped derived counter child (a "Split up" member's part):
        // resolve from the ROOT's events inside the child's own window, never
        // the latch — the same branch `DerivationPass.computeBoardGrid` takes.
        if let derived = resolveDerivedCounterWindowState(
            task: child, eventsByTaskId: windowContext.eventsByTaskId
        ) {
            return derived.isCompleted
        }
        // Derived-task carve-out: HUB-LINKED derived counting children keep
        // their propagation-stamped lifetime cache — they don't own events.
        if !isEventOwningTask(child) { return child.isCompleted }
        let events = windowContext.eventsByTaskId[child.id] ?? []
        return resolveTaskWindowState(
            task: child,
            events: events,
            windowStart: windowContext.windowStart,
            windowEnd: windowContext.windowEnd
        ).isCompleted
    }

    private static func evaluateInner(
        compound: Task,
        childrenByCompound: [String: [CompoundChild]],
        taskById: [String: Task],
        visiting: inout Set<String>,
        windowContext: CompoundWindowContext?
    ) -> Bool {
        guard compound.type == .compound else {
            return compound.isCompleted
        }

        // Cycle guard: a compound already on the recursion stack resolves to
        // `false` for this branch.
        if visiting.contains(compound.id) { return false }
        visiting.insert(compound.id)
        defer { visiting.remove(compound.id) }

        let links = (childrenByCompound[compound.id] ?? []).filter { !$0.isDeleted }
        let childStates: [Bool] = links.map { link in
            guard let child = taskById[link.childTaskId], !child.isDeleted else {
                return false
            }
            if child.type == .compound {
                // Nested compounds inherit the same host window.
                return evaluateInner(
                    compound: child,
                    childrenByCompound: childrenByCompound,
                    taskById: taskById,
                    visiting: &visiting,
                    windowContext: windowContext
                )
            }
            return resolvePrimitiveChildState(child, windowContext)
        }

        switch compound.operatorType {
        case .and:
            // Vacuous truth: AND over zero children is true.
            // Matches set-theoretic AND-of-empty semantics and avoids surprising
            // an editor mid-restructure with a permanently-incomplete parent.
            return childStates.isEmpty || childStates.allSatisfy { $0 }
        case .or:
            return childStates.contains(true)
        case .mOfN:
            // Floor threshold at 1. A missing/null threshold (?? 0) or an
            // explicit 0 would produce vacuous-true (`0 >= 0`) and silently
            // mark the compound complete with zero work done — possible if a
            // migrated legacy composite lacks an explicit M_OF_N threshold.
            // `max(1, threshold ?? 1)` makes the worst-case behave like OR
            // rather than always-complete. Mirrors the TS twin.
            let required = max(1, compound.threshold ?? 1)
            return childStates.filter { $0 }.count >= required
        case .none:
            // Operator missing on a compound row — treat as incomplete.
            // Swift / Zod validation should have rejected this upstream.
            return false
        }
    }

    /// Clamp a compound "at least N" (M_OF_N) threshold into the valid
    /// **stored** range `1...max(1, childCount)`.
    ///
    /// Swift twin of `@oybc/shared`'s `clampCompoundThreshold` — the single
    /// source of truth for the threshold clamp both platforms apply before
    /// persisting. It replaces the hand-rolled `min(max(1, t), max(1|2, count))`
    /// clamps that had drifted on the upper-bound floor (`max(1)` vs `max(2)`),
    /// which could store a different threshold across platforms at edge child
    /// counts. Pinned by the shared `clampCompoundThreshold` test vector.
    ///
    /// - lower bound 1 (a threshold below 1 makes M_OF_N vacuously true — see
    ///   the `max(1, …)` floor in `evaluate` above);
    /// - upper bound `max(1, childCount)` (a threshold can't exceed the real
    ///   child count; `max(1, …)` avoids a degenerate empty range at 0 children).
    ///
    /// The stepper's *display* max (a UI affordance that may sit above the
    /// stored ceiling while sub-tasks are still being added) is a separate
    /// concern and not this function's job.
    static func clampCompoundThreshold(_ threshold: Int, childCount: Int) -> Int {
        let maxN = max(1, childCount)
        return min(max(1, threshold), maxN)
    }

    /// Human-readable completion rule for a compound, shown under the Task
    /// Detail "Subtasks" heading.
    ///
    /// Swift twin of `@oybc/shared`'s `compoundRuleLabel` — both platforms
    /// must return identical strings (pinned by mirrored unit tests):
    /// - `.and` (or no operator — the stored default) → `All of N`
    /// - `.or` → `Any of N`
    /// - `.mOfN` → `M of N`, where M is `clampCompoundThreshold(threshold ?? 1, childCount:)`
    ///
    /// - Parameters:
    ///   - operator: The compound's stored operator (`nil` ⇒ AND).
    ///   - threshold: The stored "at least M" threshold (M_OF_N only).
    ///   - childCount: How many sub-tasks the compound resolves to.
    /// - Returns: The label, e.g. `All of 3`, `Any of 3`, `2 of 3`.
    static func compoundRuleLabel(_ operator: OperatorType?, threshold: Int?, childCount: Int) -> String {
        switch `operator` {
        case .or:
            return "Any of \(childCount)"
        case .mOfN:
            return "\(clampCompoundThreshold(threshold ?? 1, childCount: childCount)) of \(childCount)"
        case .and, .none:
            return "All of \(childCount)"
        }
    }
}
