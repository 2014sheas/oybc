import type { Task } from '@oybc/shared';

/**
 * poolEditSheetSelectors.ts — pure derivations `PoolEditSheet` needs from
 * its raw `taskIds` + task lookups (Task Pools + Recurring Boards Rework,
 * P2 final review I-2/I-3). Extracted from the component so both
 * concerns have a directly testable seam without a component-render
 * harness (mirrors `poolDeckPreview.ts` / `poolEditSheetOps.ts`).
 */

/**
 * The library-reuse picker's candidate list (I-2): `browsableTasks` (the
 * SAME draft-filtered set the Library segment browses — never the raw,
 * un-filtered task set) minus ids already on the pool, filtered by a
 * case-insensitive title query. Pickers are browse surfaces — a
 * wizard-born draft task the Library tab hides shouldn't be offered here
 * either, even though a pool that already references one still resolves
 * its chip via `resolvePoolChips` below (which reads the full set).
 */
export function selectLibraryPickerResults(
  browsableTasks: readonly Task[],
  selectedIds: ReadonlySet<string>,
  query: string,
): Task[] {
  const q = query.trim().toLowerCase();
  return browsableTasks
    .filter((t) => !selectedIds.has(t.id))
    .filter((t) => q === '' || t.title.toLowerCase().includes(q));
}

/**
 * Resolves a pool's raw `taskIds` (which may include ids that don't
 * resolve — soft-deleted or otherwise missing, preserved per `Pool`'s
 * docstring contract) into the RESOLVABLE subset, in `taskIds` order
 * (I-3). This — never the raw id list — is what the sheet's "TASKS (N)"
 * count, chip row, and deck preview render, matching
 * `computePoolHealth`'s "resolvable, non-deleted" count semantics.
 *
 * `sessionCache` supplements `tasksById` for a task added earlier this
 * session (quick-add / library-pick) that may not have round-tripped
 * through the caller's live-query snapshot yet — sidesteps a title flash.
 */
export function resolvePoolChips(
  taskIds: readonly string[],
  tasksById: ReadonlyMap<string, Task>,
  sessionCache: ReadonlyMap<string, Task>,
): Task[] {
  const out: Task[] = [];
  for (const id of taskIds) {
    const task = tasksById.get(id) ?? sessionCache.get(id);
    if (task) out.push(task);
  }
  return out;
}
