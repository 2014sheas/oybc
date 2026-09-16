import type { Board, RecurringBoardTemplate } from '@oybc/shared';

/**
 * What the recurring badge should render for a board.
 *
 * `hidden` covers BOTH "not a repeating board" and "we haven't resolved
 * its template yet" — because rendering the un-paused variant while the
 * pause state is unknown is an assertion we can't back up, and it
 * visibly flips to "↻ PAUSED" when the query lands (late-mutation
 * audit, shape B; see `reference_late_mutation_bug_class`).
 *
 * iOS twin: `RisoRecurringBadge.state(board:template:templatesLoaded:)`.
 */
export type RecurringBadgeState = 'hidden' | 'recurring' | 'paused';

export function recurringBadgeState(
  board: Pick<Board, 'spawnedFromTemplateId'>,
  template: Pick<RecurringBoardTemplate, 'isActive'> | undefined,
  templatesLoaded: boolean,
): RecurringBadgeState {
  if (board.spawnedFromTemplateId == null) return 'hidden';
  // Unknown ≠ un-paused: stay hidden until the lookup resolves.
  if (!templatesLoaded) return 'hidden';
  if (template === undefined) return 'recurring'; // resolved: template gone
  return template.isActive ? 'recurring' : 'paused';
}
