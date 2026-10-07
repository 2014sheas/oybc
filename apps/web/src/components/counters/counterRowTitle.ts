import { countKindNeedsUnit, generateCounterTaskTitle, resolveCountKind, type Task } from '@oybc/shared';

/**
 * The auto counting title from a task's own fields ("Run 26.2 miles",
 * "Practice 10h 30m"), or null when they cannot form one. The one helper the
 * Tasks-tab row, the wizard task row and the compound sub-task card share.
 *
 * @param task - The counting task's action / unit / goal / kind.
 * @returns The generated title, or `null` when action, goal or a needed unit is missing.
 */
export function counterRowTitle(
  task: Pick<Task, 'action' | 'unit' | 'maxCount' | 'countKind'>,
): string | null {
  const kind = resolveCountKind(task);
  const action = (task.action ?? '').trim();
  const unit = (task.unit ?? '').trim();
  if (!action || task.maxCount === undefined || task.maxCount === null) return null;
  if (countKindNeedsUnit(kind) && !unit) return null;
  return generateCounterTaskTitle(action, task.maxCount, unit, undefined, kind);
}

/**
 * The subtitle a library / wizard row shows under a counting task: its auto
 * title, or '' when that merely restates the row's own title.
 *
 * @param task - The counting task.
 * @returns The subtitle, or `''`.
 */
export function counterRowSubtitle(
  task: Pick<Task, 'action' | 'unit' | 'maxCount' | 'countKind' | 'title'>,
): string {
  const derived = counterRowTitle(task);
  if (!derived) return '';
  return derived.toLowerCase() === task.title.trim().toLowerCase() ? '' : derived;
}
