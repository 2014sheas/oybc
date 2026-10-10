import type { CountsTowardProblem } from '@oybc/shared';

/**
 * The inline validation line for a refused counts-toward assignment
 * (`countsTowardProblem` codes → short labels; docs/SHARED_COUNTER_SETTINGS.md
 * §3e). iOS twin: `CountsToward.Problem.label`.
 */
const LABELS: Record<CountsTowardProblem, string> = {
  self: 'Not itself.',
  'contributor-is-counter': "A counter can't count toward a counter.",
  'contributor-is-linked': "A linked counter can't count toward a counter.",
  'contributor-is-achievement': "An achievement can't count toward a counter.",
  'target-not-counter': 'Pick a shared counter.',
  'target-not-discrete': 'Pick a Discrete counter.',
  'invalid-amount': 'Amount must be a whole number, 1 or more.',
  cycle: 'That counter already feeds this task.',
};

/**
 * @param code - The refusal code.
 * @returns The validation-line text.
 */
export function countsTowardProblemLabel(code: CountsTowardProblem): string {
  return LABELS[code];
}

/** The "Counts toward" field's label. */
export const COUNTS_TOWARD_LABEL = 'Counts toward';

/** The value shown when a task counts toward nothing. */
export const COUNTS_TOWARD_NONE = 'None';
