import type { Task } from '@oybc/shared';

/** What a "Derive smaller version…" save should link the new task to. */
export interface DeriveLinkTarget {
  /** The counter (source Task id) the new derived task should link to. */
  sharedCounterId: string;
  /**
   * "Start fresh" baseline — the resolved root source's own lifetime
   * `currentCount`. The new task's own window then starts counting from 0
   * forward, same semantics as the auto-link path (`LinkableCounter.
   * lifetime` = `best.currentCount ?? 0`).
   */
  baseline: number;
}

/**
 * Resolves the link target for the "Derive smaller version…" context-menu
 * action (R1 counters refresh — the modal's own copy promises "same
 * counter, lower goal" / "still counts {noun}", so the save MUST produce a
 * linked task, not a standalone duplicate).
 *
 * `source` is the task the user is deriving from. Two cases:
 *   - `source` is a plain counter (its own `sharedCounterId` is unset) —
 *     link straight to `source.id`; `source` IS the root, so its own
 *     `currentCount` is the baseline.
 *   - `source` is itself a derived/linked task (`source.sharedCounterId`
 *     set) — link to THAT id instead, never to `source.id`, which would
 *     chain a link onto a link rather than pointing at the actual counter.
 *     This mirrors `findLinkableCounter`'s "link targets are sources/
 *     standalones only" rule. The baseline in this branch is the ROOT
 *     source's lifetime `currentCount`, not `source.currentCount` (which
 *     would be the derived task's own local window) — the caller resolves
 *     the root Task (sync map lookup or an async fetch, platform-
 *     dependent) and passes it as `rootTask`.
 *
 * @param source - The task being derived from.
 * @param rootTask - The resolved root source Task when `source` is itself
 *   derived. Ignored (and may be omitted) when `source` is already a root
 *   counter. Falls back to `source` if resolution failed (best-effort —
 *   should not happen in practice; a task can't have a `sharedCounterId`
 *   pointing at a row that no longer exists without going through the
 *   unlink-then-delete cascade, which clears it).
 */
export function resolveDeriveLinkTarget(source: Task, rootTask?: Task): DeriveLinkTarget {
  const sharedCounterId = source.sharedCounterId ?? source.id;
  const resolvedRoot = sharedCounterId === source.id ? source : (rootTask ?? source);
  return { sharedCounterId, baseline: resolvedRoot.currentCount ?? 0 };
}
