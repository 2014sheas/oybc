import {
  validateSpawnPool,
  type RecurringBoardTemplate,
  type SpawnPoolFailureReason,
  type Task,
} from '@oybc/shared';

/**
 * Computes the "needs attention" badge reason for every template on the
 * Recurring templates page.
 *
 * P1 (Task Pools + Recurring Boards Rework, docs/POOLS_RECURRING.md
 * §Migration "seedTaskIds end state" — "never read after P1" is
 * unconditional) — this used to walk `template.seedTaskIds` directly.
 * That went stale the first time the legacy-editor write-through ran
 * (it edits the linked Pool's `taskIds`, not this field), which meant
 * the badge could show a WRONG pool-health warning: a `pool_too_small`
 * that a prior "Add tasks" edit had already fixed (stale-small
 * `seedTaskIds` outliving a since-grown Pool), or silence over an
 * actually-short Pool the field never reflected. Callers must now pass
 * the resolved mix (from `useTemplateMixes`/`computeTemplateMixes`) per
 * template instead — "fix once, heals everywhere" applies to this badge
 * exactly as it does to the wizard hydration and the spawn path.
 *
 * @param templates - Templates to evaluate.
 * @param mixByTemplateId - Each template's CURRENT resolved task-id mix
 *   (id → `resolveMix(...).taskIds`, or the `seedTaskIds` fallback for an
 *   unresolvable/loading entry — see `computeTemplateMixes`). A missing
 *   entry falls back to that template's own `seedTaskIds` (loading-state
 *   safety net so the badge doesn't flash "pool too small" before the
 *   batched mix query resolves).
 * @param taskMap - id → Task lookup (the Tasks-tab library; only
 *   non-deleted, browsable tasks are present — an id missing here is
 *   either genuinely deleted or otherwise unresolvable).
 */
export function computeTemplateAttention(
  templates: RecurringBoardTemplate[],
  mixByTemplateId: Record<string, string[]>,
  taskMap: Record<string, Task | undefined>,
): Record<string, SpawnPoolFailureReason> {
  const out: Record<string, SpawnPoolFailureReason> = {};
  for (const t of templates) {
    const mixTaskIds = mixByTemplateId[t.id] ?? t.seedTaskIds;
    const pool: Task[] = [];
    let hasMissingFromLibrary = false;
    for (const id of mixTaskIds) {
      const found = taskMap[id];
      if (found) pool.push(found);
      else hasMissingFromLibrary = true;
    }
    if (hasMissingFromLibrary) {
      out[t.id] = 'has_deleted_tasks';
      continue;
    }
    const v = validateSpawnPool(t, pool);
    if (!v.ok) out[t.id] = v.reason;
  }
  return out;
}
