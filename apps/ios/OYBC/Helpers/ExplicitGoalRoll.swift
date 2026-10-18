import Foundation

/// The dice roll for a hand-added counter that carries an EXPLICIT goal — a typed
/// wizard goal, or a repeating board's frozen `manualTaskTargets` entry. The planner
/// rolls a hand-added member around its own / window-default goal; an explicit goal
/// replaces that base, so the roll is redone AROUND the explicit goal (in its kind) and
/// the dice are never lost behind it. Twin of the TS `rollExplicitGoal`.
enum ExplicitGoalRoll {

    /// The target an explicit goal resolves to after its dice: `BoardSources.rollTarget`
    /// around `goal` in `kind` (exactly one `rng` sample, none for a degenerate range).
    /// With the dice off the goal is returned as-is, untouched, without consuming `rng`.
    ///
    /// - Parameters:
    ///   - goal: The explicit goal.
    ///   - kind: The kind the goal is expressed in.
    ///   - vary: The member's dice level.
    ///   - rng: Uniform `[0, 1)` source.
    /// - Returns: The effective goal, in `kind`.
    static func rolledExplicitGoal(
        goal: CountValue, kind: CountKind, vary: VaryLevel, rng: () -> Double
    ) -> CountValue {
        guard vary != .off else { return goal }
        return BoardSources.rollTarget(t: goal, level: vary, goal: goal, rng: rng, kind: kind)
    }
}
