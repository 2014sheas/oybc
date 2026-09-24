import { patchesEqual, type TaskEditPatch } from '../../db/taskEditPatch';

/**
 * Whether the compound's rule / sub-tasks differ from what the Task Detail
 * sheet opened with. The title is ignored — the sheet's Title field owns it
 * and it saves through either route. `false` while either side is still
 * loading.
 *
 * @param baseline - The structure seeded on open (`null` until loaded).
 * @param draft - The current edited structure (`null` until loaded).
 * @returns `true` only when the structure itself was edited.
 */
export function compoundStructureChanged(
  baseline: TaskEditPatch | null,
  draft: TaskEditPatch | null,
): boolean {
  if (baseline === null || draft === null) return false;
  return !patchesEqual({ ...baseline, title: '' }, { ...draft, title: '' });
}

/**
 * The compound structure the sheet should submit, or `undefined` to save
 * through the basic route. Only an edited structure is submitted, so a
 * compound whose STORED structure already fails validation (one sub-task
 * left, a stale threshold, zero sub-tasks) can still be renamed or
 * re-described exactly as before.
 *
 * @param baseline - The structure seeded on open (`null` until loaded).
 * @param draft - The current edited structure (`null` until loaded).
 * @param title - The sheet's Title field (trimmed into the structure).
 * @returns The structure patch titled from the sheet, or `undefined`.
 */
export function compoundSubmitFor(
  baseline: TaskEditPatch | null,
  draft: TaskEditPatch | null,
  title: string,
): TaskEditPatch | undefined {
  if (draft === null || !compoundStructureChanged(baseline, draft)) return undefined;
  return { ...draft, title: title.trim() };
}
