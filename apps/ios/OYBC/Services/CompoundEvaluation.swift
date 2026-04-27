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
    /// - Parameters:
    ///   - compound: The Task to evaluate. If `type != .compound`, returns
    ///     `compound.isCompleted` directly.
    ///   - childrenByCompound: Map of `compoundTaskId` → list of CompoundChild
    ///     rows. Caller may pass non-deleted rows only, or all rows — this
    ///     function filters `isDeleted` links itself.
    ///   - taskById: Map of `taskId` → Task. Missing keys evaluate the child as
    ///     incomplete.
    /// - Returns: `true` if the compound's operator condition is satisfied.
    static func evaluate(
        compound: Task,
        childrenByCompound: [String: [CompoundChild]],
        taskById: [String: Task]
    ) -> Bool {
        var visiting: Set<String> = []
        return evaluateInner(
            compound: compound,
            childrenByCompound: childrenByCompound,
            taskById: taskById,
            visiting: &visiting
        )
    }

    private static func evaluateInner(
        compound: Task,
        childrenByCompound: [String: [CompoundChild]],
        taskById: [String: Task],
        visiting: inout Set<String>
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
                return evaluateInner(
                    compound: child,
                    childrenByCompound: childrenByCompound,
                    taskById: taskById,
                    visiting: &visiting
                )
            }
            return child.isCompleted
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
            return childStates.filter { $0 }.count >= (compound.threshold ?? 0)
        case .none:
            // Operator missing on a compound row — treat as incomplete.
            // Swift / Zod validation should have rejected this upstream.
            return false
        }
    }
}
