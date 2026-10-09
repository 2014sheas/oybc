import type { Task } from '@oybc/shared';
import type { RowContextMenuItem } from '../wizard/RowContextMenu';

/**
 * The counter's ROOT task when it can be edited (exists, not deleted), else
 * `null`. Counter Detail is keyed by `counterId` = the root task's id.
 *
 * @param task - The row read for the counter id (undefined while missing).
 * @returns The editable root, or `null`.
 */
export function editableCounterRoot(task: Task | undefined | null): Task | null {
  return task && !task.isDeleted ? task : null;
}

/**
 * Counter Detail's "⋯" overflow items: "Edit counter…" (only with a live
 * root — it opens the global task editor on that root) above
 * "Delete counter…". iOS twin: `CounterDetailContent.overflowMenu`.
 *
 * @param args.root - The editable root (`editableCounterRoot`), or `null`.
 * @param args.onEdit - Opens the editor on the root.
 * @param args.onDelete - Starts the delete-with-unlink flow.
 * @returns The menu items, in display order.
 */
export function counterDetailMenuItems(args: {
  root: Task | null;
  onEdit: (root: Task) => void;
  onDelete: () => void;
}): RowContextMenuItem[] {
  const { root, onEdit, onDelete } = args;
  const items: RowContextMenuItem[] = [];
  if (root) items.push({ label: 'Edit counter…', glyph: '✎', action: () => onEdit(root) });
  items.push({ label: 'Delete counter…', glyph: '✕', destructive: true, action: onDelete });
  return items;
}
