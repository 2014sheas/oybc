import { formatCount, formatCountWithUnit, type CountKind, type SharedCounterMemberTask } from '@oybc/shared';

/**
 * A Counter Detail task card's caption (R2 order: remaining first, "ends
 * {window}" last), formatted at the counter's kind.
 *
 * @param task - The member task.
 * @param unit - The counter's unit noun (ignored for Duration).
 * @param kind - The counter's kind.
 * @returns The caption.
 */
export function buildTaskCardCaption(task: SharedCounterMemberTask, unit: string, kind: CountKind): string {
  if (task.met && task.over > 0) return `✓ Goal met · ${formatCount(task.over, kind)} over`;
  if (task.met) return '✓ Goal met this window';
  const base = `${formatCountWithUnit(Math.max(0, task.goal - task.logged), kind, unit)} to go`;
  return task.window ? `${base} · ends ${task.window}` : base;
}
