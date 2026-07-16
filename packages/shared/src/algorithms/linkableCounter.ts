/**
 * linkableCounter.ts — "add a new task to an existing counter" match (Shared Counters).
 *
 * When a user creates a new COUNTING task, if its `action + unit` match an
 * existing counter, the create form surfaces a one-tap "link to it" suggestion
 * (the user confirms — never silent). This is the pure MATCH: given the typed
 * action+unit, which existing counter (source task) should the new task join?
 *
 * In OYBC's model the counting `action` field carries the ACTIVITY ("Push-ups"),
 * with `unit` ("reps") — there is no separate generic verb — so `action + unit`
 * cleanly identifies a counter (Push-ups ≠ Sit-ups even though both are "· reps").
 *
 * Linking sets the new task's `sharedCounterId` to the returned `counterId` and
 * a baseline (start-from-zero by default). No engine change — this feeds the
 * existing linked-counter create path. The iOS `LinkableCounter.swift` port
 * mirrors this match.
 */

import type { Task } from '../types/task';
import { TaskType } from '../constants/enums';

/** The existing counter a new task can join, plus display stats for the suggestion. */
export interface LinkableCounter {
  /** The source counting task id — set as the new task's `sharedCounterId`. */
  counterId: string;
  /** Display label for the suggestion — the counter's activity (source `action`). */
  name: string;
  /** All-time lifetime = the source's `currentCount`. */
  lifetime: number;
  /** Tasks already sharing this counter (source + linkers) — for "N tasks". */
  memberCount: number;
}

export interface FindLinkableCounterInput {
  /** The new task's action (activity) as typed. */
  action: string;
  /** The new task's unit as typed. */
  unit: string;
  /** Exclude this task id from matches (when editing an existing task). */
  excludeTaskId?: string;
}

const norm = (s: string | undefined | null): string => (s ?? '').trim().toLowerCase();

/**
 * Find the existing counter a new counting task (with the given action+unit)
 * should be suggested to join.
 *
 * A candidate is a live COUNTING task that is NOT itself derived
 * (`sharedCounterId == null` — a standalone becomes a source on link; an
 * existing source stays one) whose normalized action+unit match. Derived tasks
 * aren't link targets; you link to their source, which itself matches. When
 * several candidates match, the most-established counter wins (most member
 * tasks, then highest all-time count, then a stable id tie-break).
 *
 * @returns the counter to suggest, or `null` when action/unit are blank or
 *   nothing matches (no suggestion shown).
 */
export function findLinkableCounter(
  input: FindLinkableCounterInput,
  tasks: readonly Task[],
): LinkableCounter | null {
  const a = norm(input.action);
  const u = norm(input.unit);
  if (a === '' || u === '') return null;

  const live = tasks.filter((t) => !t.isDeleted && t.type === TaskType.COUNTING);

  // Linkers per source (source id → count of tasks pointing at it).
  const linkerCountBySource = new Map<string, number>();
  for (const t of live) {
    if (t.sharedCounterId != null) {
      linkerCountBySource.set(
        t.sharedCounterId,
        (linkerCountBySource.get(t.sharedCounterId) ?? 0) + 1,
      );
    }
  }

  const candidates = live.filter(
    (t) =>
      t.id !== input.excludeTaskId &&
      t.sharedCounterId == null && // link targets are sources / standalones only
      norm(t.action) === a &&
      norm(t.unit) === u,
  );
  if (candidates.length === 0) return null;

  candidates.sort((x, y) => {
    const mx = 1 + (linkerCountBySource.get(x.id) ?? 0);
    const my = 1 + (linkerCountBySource.get(y.id) ?? 0);
    if (mx !== my) return my - mx; // most-established counter first
    const cx = x.currentCount ?? 0;
    const cy = y.currentCount ?? 0;
    if (cx !== cy) return cy - cx; // then highest all-time
    return x.id < y.id ? -1 : 1; // stable
  });

  const best = candidates[0];
  return {
    counterId: best.id,
    name: (best.action ?? '').trim() || best.title,
    lifetime: best.currentCount ?? 0,
    memberCount: 1 + (linkerCountBySource.get(best.id) ?? 0),
  };
}

/** P5 — hub-create dedupe classification result. */
export type CounterCreateMatch = {
  kind: 'established' | 'standalone';
  /** The matched source/standalone Task row (promote target when standalone). */
  task: Task;
  lifetime: number;
  memberCount: number;
};

/**
 * Classify what the hub "+ New counter" form's typed action+unit collides
 * with: an ESTABLISHED counter (has linked tasks or is flagged `isCounter`)
 * → the UI blocks create and offers jump-to; a STANDALONE counting task →
 * the UI offers one-tap promote (set `isCounter: true` on it). `null` when
 * nothing matches (create proceeds). Wraps `findLinkableCounter`; the task
 * row is looked up because `memberCount` alone cannot distinguish a
 * standalone from a flagged single-member counter
 * (docs/SHARED_COUNTERS.md §P5 decision 7).
 */
export function classifyCounterCreateMatch(
  input: FindLinkableCounterInput,
  tasks: readonly Task[],
): CounterCreateMatch | null {
  const match = findLinkableCounter(input, tasks);
  if (!match) return null;
  const task = tasks.find((t) => t.id === match.counterId);
  if (!task) return null;
  const established = match.memberCount > 1 || task.isCounter === true;
  return {
    kind: established ? 'established' : 'standalone',
    task,
    lifetime: match.lifetime,
    memberCount: match.memberCount,
  };
}
