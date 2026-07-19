import type { Task } from '@oybc/shared';
import type { PendingTaskPayload } from '../../pages/createPage/useCreateFormState';

/**
 * Merges a persisted task list with a wizard session's in-memory pending
 * tasks (Bug #85 deferred-persist), deduplicating by id (persisted wins on
 * a collision, which shouldn't happen in practice since pending tasks carry
 * freshly-generated UUIDs).
 *
 * R1 counters refresh review fix — extracted as a pure function so
 * `BoardWizardTasksStep`'s `effectiveSuggestionPool` (the unfiltered pool
 * fed to `findLinkableCounter` for the counter-link auto-link match) is
 * unit-testable without DOM/Dexie infra. Mirrors iOS's
 * `BoardWizardTasksStepView.effectiveSuggestionPool` merge semantics
 * exactly (and the sibling `effectiveAllTasks` merge already inlined in
 * `BoardWizardTasksStep.tsx`, which this does not change).
 *
 * @param persisted - The full (unfiltered) persisted task list, e.g.
 *   `TaskLibrary.allTasks`.
 * @param pendingTasks - This wizard session's in-memory pending payloads, or
 *   `undefined`/empty when not in deferred-persist mode.
 * @returns `persisted` with any pending tasks not already present appended.
 */
export function mergeSuggestionPool(
  persisted: Task[],
  pendingTasks: Map<string, PendingTaskPayload> | undefined,
): Task[] {
  if (!pendingTasks || pendingTasks.size === 0) return persisted;
  const pendingArr = Array.from(pendingTasks.values()).map((p) => p.task);
  const ids = new Set(persisted.map((t) => t.id));
  return [...persisted, ...pendingArr.filter((t) => !ids.has(t.id))];
}
