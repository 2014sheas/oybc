import type { Task } from '@oybc/shared';

/**
 * Pure candidate predicate (Board Edit redesign slice 3, D13) — moved from
 * `CellSwapModal.tsx`'s `isSwapCandidate` (the play-mode "+" / CellSwap
 * picker is retired, D17; the squares editor's `SquarePickerSheet` is the
 * only remaining add/replace surface). A task is pickable when it is:
 *   - an eligible non-center type, not deleted;
 *   - not the outgoing square's own task (replace mode);
 *   - NOT already in the DRAFT (staged adds included — `placedTaskIds` is
 *     the caller's current draft snapshot, not just the live board);
 *   - NOT a member of a shared-counter family already in the draft — the
 *     one-counter-per-board rule — except when the only draft member IS the
 *     outgoing square (replacing "Read 20" → "Read 50" legitimately
 *     replaces the family's slot).
 */
export function isSquarePickerCandidate(
  task: Task,
  args: {
    currentTaskId?: string;
    placedTaskIds?: Set<string>;
    counterFamilyByTaskId?: Record<string, string>;
  },
): boolean {
  const { currentTaskId, placedTaskIds, counterFamilyByTaskId } = args;
  if (task.isDeleted) return false;
  if (currentTaskId !== undefined && task.id === currentTaskId) return false;
  if (placedTaskIds !== undefined) {
    if (placedTaskIds.has(task.id) && task.id !== currentTaskId) return false;
    const fam = counterFamilyByTaskId?.[task.id];
    if (fam !== undefined) {
      for (const placedId of placedTaskIds) {
        if (placedId === currentTaskId) continue;
        if (counterFamilyByTaskId?.[placedId] === fam) return false;
      }
    }
  }
  return true;
}
