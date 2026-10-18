import { rollTarget, type CountKind, type VaryLevel } from '@oybc/shared';

/**
 * explicitGoalRoll.ts — the dice roll for a hand-added counter that carries an
 * EXPLICIT goal (a typed wizard goal, or a repeating board's frozen
 * `manualTaskTargets` entry). The planner rolls a hand-added member around its
 * own / window-default goal; an explicit goal replaces that base, so the roll
 * is redone around the explicit goal — the dice never get lost behind it.
 *
 * iOS twin: `ExplicitGoalRoll.rolledExplicitGoal`.
 */

/** An explicit goal and the kind it is expressed in. */
export interface ExplicitGoal {
  target: number;
  kind: CountKind;
}

/**
 * The target a hand-added member's explicit goal resolves to after its dice:
 * `rollTarget` around the explicit goal in the explicit goal's own kind
 * (exactly ONE rng sample, none when the range is degenerate). With the dice
 * off the goal is returned as-is, untouched and without consuming `rng`.
 *
 * @param goal - The explicit goal and its kind.
 * @param vary - The member's dice level (0 = off).
 * @param rng - Uniform `[0, 1)` source.
 * @returns The effective goal, in `goal.kind`.
 */
export function rollExplicitGoal(goal: ExplicitGoal, vary: VaryLevel, rng: () => number): ExplicitGoal {
  if (vary === 0) return goal;
  return { target: rollTarget(goal.target, vary, goal.target, rng, goal.kind), kind: goal.kind };
}
