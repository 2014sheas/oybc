import {
  buildCounterFamilyMap,
  computeAchievablePoolSize,
  validateSpawnPool,
  type RecurringBoardTemplate,
  type SpawnPoolFailureReason,
  type Task,
} from '@oybc/shared';
import type { TemplateSupplyResolution } from '../../db/operations/boardSources';

/** Attention union for the sources-native roster health — the spawn's
 *  static twin (loose-ends sweep 2026-09-09). */
export type TemplateAttentionReason =
  | SpawnPoolFailureReason
  | 'no_pool_tasks_resolved'
  | 'source_board_missing';

/** Result of {@link computeRosterHealth}. */
export interface RosterHealth {
  /** Per-template ACHIEVABLE pool ids (the dry-run's picks) — feeds the
   *  roster's "N tasks" count and the pool preview, honestly (ranges,
   *  cap overlap, and the counter-family rule all applied). */
  mixByTemplateId: Record<string, string[]>;
  /** Per-template attention badge, `source_board_missing` included —
   *  static parity with the spawn pass's skip reasons. */
  attentionByTemplateId: Record<string, TemplateAttentionReason>;
}

/**
 * Sources-native roster health (supersedes `computeTemplateAttention` +
 * the legacy `computeTemplateMixes` pair for the Board-settings page):
 * evaluates each template exactly as the spawn pass would — dead board
 * source → `source_board_missing`; a deleted hand-added task →
 * `has_deleted_tasks`; nothing resolvable → `no_pool_tasks_resolved`;
 * then `validateSpawnPool` over the achievable pick (which carries the
 * honest size, so `pool_too_small` respects ranges/overlap/families).
 *
 * @param templates - The roster.
 * @param resolutionByTemplateId - From `fetchTemplateSupplyResolution`.
 * @param tasksById - The combined task universe from the same fetch.
 */
export function computeRosterHealth(
  templates: RecurringBoardTemplate[],
  resolutionByTemplateId: Record<string, TemplateSupplyResolution>,
  tasksById: Record<string, Task | undefined>,
): RosterHealth {
  const counterFamilyByTaskId = buildCounterFamilyMap(
    Object.values(tasksById).filter((t): t is Task => t !== undefined),
  );
  const mixByTemplateId: Record<string, string[]> = {};
  const attentionByTemplateId: Record<string, TemplateAttentionReason> = {};
  for (const t of templates) {
    const resolution = resolutionByTemplateId[t.id];
    if (resolution === undefined) {
      // Still loading / unresolvable — fall back to the raw seed list so
      // the row renders a count instead of flashing empty.
      mixByTemplateId[t.id] = t.seedTaskIds;
      continue;
    }
    const { supplies, deadBoardSourceIds, manualTaskIds } = resolution;
    // Resolvable manual layer (deleted manual ids stay OUT of the pick
    // but flag attention below — the spawn validator's exact rule).
    const manualResolvable = manualTaskIds.filter((id) => {
      const task = tasksById[id];
      return task !== undefined && !task.isDeleted;
    });
    const achievable = computeAchievablePoolSize({
      supplies,
      manualTaskIds: manualResolvable,
      counterFamilyByTaskId,
    });
    mixByTemplateId[t.id] = achievable.taskIds;

    if (deadBoardSourceIds.length > 0) {
      attentionByTemplateId[t.id] = 'source_board_missing';
      continue;
    }
    if (manualResolvable.length < manualTaskIds.length) {
      attentionByTemplateId[t.id] = 'has_deleted_tasks';
      continue;
    }
    if (achievable.size === 0) {
      attentionByTemplateId[t.id] = 'no_pool_tasks_resolved';
      continue;
    }
    const pool = achievable.taskIds
      .map((id) => tasksById[id])
      .filter((task): task is Task => task !== undefined);
    const v = validateSpawnPool(t, pool);
    if (!v.ok) attentionByTemplateId[t.id] = v.reason;
  }
  return { mixByTemplateId, attentionByTemplateId };
}

