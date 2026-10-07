import { formatCountTotal, type CountKind } from '@oybc/shared';

/**
 * A member's "logged/goal" value as two display parts (thousands-grouped for
 * Discrete / Continuous, `Xh Ym` for Duration — R7 / U18), so call sites can
 * style the goal separately.
 *
 * @param logged - The member's logged value.
 * @param goal - The member's goal.
 * @param kind - The counter's kind.
 * @returns The two formatted parts.
 */
export function memberValueParts(logged: number, goal: number, kind: CountKind): { logged: string; goal: string } {
  return { logged: formatCountTotal(logged, kind), goal: formatCountTotal(goal, kind) };
}
