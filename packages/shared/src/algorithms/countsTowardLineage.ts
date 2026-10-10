/**
 * countsTowardLineage.ts — the fork-lineage half of "counts toward"
 * (docs/SHARED_COUNTER_SETTINGS.md §3a / §3e). A board-scoped fork copies the
 * original's in-window events onto itself (`forkedEventId`) and keeps the
 * flag; these helpers let the original and its forks share ONE credit per
 * occurrence: {@link createForkEventResolver} maps a copied event back to its
 * source, {@link lineageRootId} is the scope every contributor-scoped credit
 * key of a lineage is minted under, and {@link forkLineageIds} enumerates the
 * other members whose wants protect a credit from a premature tombstone.
 *
 * Swift twin: the lineage section of `Helpers/CountsToward.swift`.
 */

import type { Task } from '../types/task';
import type { TaskEvent } from '../types/taskEvent';
import { forkedEventId } from './boardScopedFork';

const compareIds = (a: string, b: string): number => (a < b ? -1 : a > b ? 1 : 0);

/** Deepest `forkedFromTaskId` chain followed when resolving a copied event / a lineage. */
export const MAX_FORK_LINEAGE = 8;

/**
 * Resolves an event of a board-scoped fork to its SOURCE event id
 * (`forkedEventId(fork.id, source.id)` inverted), transitively up the
 * `forkedFromTaskId` lineage. Builds ONE reverse map per fork from its
 * source's events (O(M) hashes) the first time that fork is asked, then every
 * further event of that fork is a lookup — never a hash per (event × source
 * event) pair.
 */
export interface ForkEventResolver {
  /**
   * @param eventId - An event of `task`.
   * @param task - The event's owner.
   * @returns The canonical (source) event id; `eventId` itself for a non-copy.
   */
  resolve(eventId: string, task: Pick<Task, 'id' | 'forkedFromTaskId'>): string;
}

/**
 * Create a {@link ForkEventResolver} over the workspace's tasks and events.
 *
 * @param taskById - Every task by id (the fork lineage is walked through it).
 * @param allEventsByTaskId - Every event (any state) by `taskId` — at least
 *   the fork ancestors' events must be present for a copy to resolve.
 */
export function createForkEventResolver(
  taskById: Record<string, Pick<Task, 'id' | 'forkedFromTaskId'>>,
  allEventsByTaskId: Record<string, TaskEvent[]>,
): ForkEventResolver {
  const reverseByFork = new Map<string, Map<string, string>>();
  const reverseFor = (forkId: string, sourceId: string): Map<string, string> => {
    let map = reverseByFork.get(forkId);
    if (!map) {
      map = new Map();
      for (const e of allEventsByTaskId[sourceId] ?? []) map.set(forkedEventId(forkId, e.id), e.id);
      reverseByFork.set(forkId, map);
    }
    return map;
  };
  return {
    resolve(eventId, task) {
      let current = task;
      let id = eventId;
      for (let depth = 0; depth < MAX_FORK_LINEAGE; depth += 1) {
        const sourceId = current.forkedFromTaskId;
        if (sourceId == null) return id;
        const source = taskById[sourceId];
        if (!source) return id;
        const sourceEventId = reverseFor(current.id, sourceId).get(id);
        if (sourceEventId === undefined) return id;
        id = sourceEventId;
        current = source;
      }
      return id;
    },
  };
}

/**
 * {@link ForkEventResolver} for one lookup (tests / one-off callers; the
 * writers share one resolver per cascade).
 */
export function canonicalOccurrenceEventId(
  eventId: string,
  task: Pick<Task, 'id' | 'forkedFromTaskId'>,
  taskById: Record<string, Pick<Task, 'id' | 'forkedFromTaskId'>>,
  allEventsByTaskId: Record<string, TaskEvent[]>,
): string {
  return createForkEventResolver(taskById, allEventsByTaskId).resolve(eventId, task);
}

/** `forkedFromTaskId` → the ids of the tasks forked from it (any state). */
export function buildForkChildrenIndex(tasks: Iterable<Pick<Task, 'id' | 'forkedFromTaskId'>>): Record<string, string[]> {
  const out: Record<string, string[]> = {};
  for (const t of tasks) if (t.forkedFromTaskId != null) (out[t.forkedFromTaskId] ??= []).push(t.id);
  return out;
}

/**
 * The OTHER members of `taskId`'s fork lineage: its ancestors (via
 * `forkedFromTaskId`), its descendants (via `forkChildren`), and their
 * relatives, transitively, bounded by {@link MAX_FORK_LINEAGE} hops. A task
 * with no `forkedFromTaskId` and no forks has an empty lineage.
 *
 * @param taskId - The task.
 * @param taskById - Every task by id.
 * @param forkChildren - {@link buildForkChildrenIndex}.
 * @returns Sorted ids, `taskId` excluded.
 */
export function forkLineageIds(
  taskId: string,
  taskById: Record<string, Pick<Task, 'id' | 'forkedFromTaskId'>>,
  forkChildren: Record<string, string[]>,
): string[] {
  const seen = new Set<string>([taskId]);
  let frontier = [taskId];
  for (let depth = 0; depth < MAX_FORK_LINEAGE && frontier.length > 0; depth += 1) {
    const next: string[] = [];
    for (const id of frontier) {
      const parent = taskById[id]?.forkedFromTaskId;
      const related = [...(parent != null ? [parent] : []), ...(forkChildren[id] ?? [])];
      for (const r of related) {
        if (seen.has(r) || !taskById[r]) continue;
        seen.add(r);
        next.push(r);
      }
    }
    frontier = next;
  }
  seen.delete(taskId);
  return [...seen].sort(compareIds);
}

/**
 * The top of `task`'s `forkedFromTaskId` chain that is present in `taskById`
 * (bounded by {@link MAX_FORK_LINEAGE}) — the scope every contributor-scoped
 * credit key of the lineage is minted under. A task that is not a fork, or
 * whose original is not loaded, is its own root.
 *
 * @param task - The contributor.
 * @param taskById - Every task by id.
 */
export function lineageRootId(task: Pick<Task, 'id' | 'forkedFromTaskId'>, taskById: Record<string, Pick<Task, 'id' | 'forkedFromTaskId'>>): string {
  let current = task;
  for (let depth = 0; depth < MAX_FORK_LINEAGE; depth += 1) {
    const parentId = current.forkedFromTaskId;
    if (parentId == null) return current.id;
    const parent = taskById[parentId];
    if (!parent) return current.id;
    current = parent;
  }
  return current.id;
}

/**
 * Whether every ancestor on `task`'s `forkedFromTaskId` chain is present in
 * `taskById` (bounded by {@link MAX_FORK_LINEAGE}). A fork whose original has
 * not been pulled yet produces no credits and no actions until it has — its
 * scope ({@link lineageRootId}) would otherwise move when the original lands.
 *
 * @param task - The contributor.
 * @param taskById - Every loaded task by id.
 */
export function isForkLineageLoaded(task: Pick<Task, 'id' | 'forkedFromTaskId'>, taskById: Record<string, Pick<Task, 'id' | 'forkedFromTaskId'>>): boolean {
  let current = task;
  for (let depth = 0; depth < MAX_FORK_LINEAGE; depth += 1) {
    const parentId = current.forkedFromTaskId;
    if (parentId == null) return true;
    const parent = taskById[parentId];
    if (!parent) return false;
    current = parent;
  }
  return true;
}
