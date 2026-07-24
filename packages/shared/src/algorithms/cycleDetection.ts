import type { Board, BoardTask, Task } from '../types';
import { TaskType } from '../constants/enums';
import { isWithinTimeframe } from './calendarBoundaries';

/**
 * Phase 6.3 — cycle detection for achievement-task cross-board references.
 *
 * After the ACHIEVEMENT-as-TaskType refactor, achievement-task semantics
 * live on `Task` (`type === ACHIEVEMENT` carrying `referencedBoardId` XOR
 * `referencedTemplateId`). The same Task can be placed on multiple boards
 * via `BoardTask` rows; each placement contributes one cycle edge:
 *
 *     placingBoardId → referencedBoardId
 *     placingBoardId → spawnId, for every in-template spawn
 *
 * Without a check, a user could create a chain that loops back on itself —
 * Achievement Task watching B placed on A, plus an Achievement Task watching
 * A placed on B — leaving both boards stuck in a deadlock where neither can
 * ever satisfy the other (derivation reads stored states, so no infinite
 * loop, but the user-visible behavior is broken).
 *
 * `hasCycle` runs at two points:
 *   1. When creating/editing an ACHIEVEMENT Task. Pass `parentBoardIds` =
 *      every board id currently placing that Task (empty on the brand-new
 *      Task path; non-empty when editing references on a placed Task).
 *   2. When placing an existing ACHIEVEMENT Task on a new board. Pass
 *      `parentBoardIds` = [newBoardId] (or include existing placements too;
 *      both are safe — the algorithm is idempotent).
 *
 * Cycle detection is best-effort, NOT a strict invariant: two devices
 * concurrently writing achievement tasks can each individually pass their
 * own check and still form a cycle once both writes settle. Derivation
 * reads stored states (not recursive computations), so a post-sync cycle
 * just leaves the involved boards stuck rather than crashing.
 *
 * Mirrors the iOS `CycleDetection.swift` implementation — when one changes,
 * the other must change in lockstep.
 */

export interface CycleCheckCandidate {
  /**
   * Every board id that places (or will place) the candidate ACHIEVEMENT
   * Task. Each contributes one edge: `parentBoardId → target`. The cycle
   * check passes only if NO parent is reachable from ANY target.
   */
  parentBoardIds: string[];
  /** Optional: the specific board id the candidate Task references. */
  referencedBoardId?: string;
  /** Optional: the recurring-template id the candidate Task references. */
  referencedTemplateId?: string;
}

export interface CycleCheckContext {
  /** All non-deleted board_tasks in the workspace (placements that contribute
   *  edges when their Task is ACHIEVEMENT-typed). */
  allBoardTasks: BoardTask[];
  /** Map (or array) of every non-deleted Task in the workspace, keyed for
   *  lookup. Edges are only contributed by BoardTasks whose Task is
   *  ACHIEVEMENT-typed; non-achievement placements contribute nothing. */
  allTasks: Task[];
  /** All non-deleted boards in the workspace (used to resolve template
   *  spawns AND to check the parent's `spawnedFromTemplateId` for
   *  template-self-reference). */
  allBoards: Board[];
}

export type CycleCheckResult =
  | { ok: true }
  | { ok: false; cyclePath: string[] };

/**
 * Walks the reference graph from the candidate's targets looking for a path
 * back to any of the candidate's parent boards. Self-reference of either
 * kind is a degenerate one-step cycle and short-circuits.
 *
 * Algorithm:
 *   1. Self-reference checks first (cheap, common bug guards).
 *   2. Build adjacency: `boardId → outgoing target boardIds`. Edges come
 *      from achievement-square placements:
 *        - For each `BoardTask` whose Task is type=ACHIEVEMENT and has
 *          a reference, add edge `bt.boardId → target(s)`.
 *        - `referencedBoardId`: one direct edge.
 *        - `referencedTemplateId`: fan-out edge to every non-deleted board
 *          with `spawnedFromTemplateId === referencedTemplateId`.
 *   3. Inject the candidate's prospective outgoing edges from every
 *      `parentBoardId` so the walk considers the placement under
 *      consideration.
 *   4. DFS from each candidate target; if we reach any parent, return the
 *      path.
 */
export function hasCycle(
  candidate: CycleCheckCandidate,
  context: CycleCheckContext,
): CycleCheckResult {
  const { parentBoardIds, referencedBoardId, referencedTemplateId } = candidate;
  const { allBoardTasks, allTasks, allBoards } = context;

  if (parentBoardIds.length === 0) {
    // No placements means the candidate doesn't contribute any edges to the
    // graph yet (creating a brand-new achievement Task that hasn't been
    // placed). Trivially safe — actual cycle is detected at placement time.
    return { ok: true };
  }

  const parentSet = new Set(parentBoardIds);

  // ── Self-reference: degenerate cycle ──
  if (referencedBoardId && parentSet.has(referencedBoardId)) {
    return { ok: false, cyclePath: [referencedBoardId, referencedBoardId] };
  }
  if (referencedTemplateId) {
    // Template-self-reference: any parent board is itself a spawn of the
    // template the candidate would watch. Degenerate (parent watches its
    // own template).
    for (const parentId of parentBoardIds) {
      const parent = allBoards.find((b) => b.id === parentId);
      if (parent && parent.spawnedFromTemplateId === referencedTemplateId) {
        return { ok: false, cyclePath: [parentId, parentId] };
      }
    }
  }

  // ── Build adjacency from existing achievement-task placements ──
  const tasksById = new Map<string, Task>();
  for (const t of allTasks) {
    if (t.isDeleted) continue;
    tasksById.set(t.id, t);
  }
  const boardsById = new Map<string, Board>();
  for (const b of allBoards) {
    if (b.isDeleted) continue;
    boardsById.set(b.id, b);
  }

  // Index spawns once for template-fan-out edges. Holds full Board
  // objects (not just ids) so the window-filter below can read each
  // spawn's `startDate` without a second lookup. All values are
  // non-deleted (filtered through `boardsById`).
  const spawnsByTemplate = new Map<string, Board[]>();
  for (const b of boardsById.values()) {
    if (b.spawnedFromTemplateId) {
      const list = spawnsByTemplate.get(b.spawnedFromTemplateId) ?? [];
      list.push(b);
      spawnsByTemplate.set(b.spawnedFromTemplateId, list);
    }
  }

  /**
   * Return the in-window spawns of `templateId` for the given placing
   * board. Mirrors the window filter in `derivationPass.ts` so cycle
   * edges match the set of spawns derivation actually evaluates. If
   * the placing board is missing (sync race / soft-deleted) we
   * conservatively skip the fan-out — no edges added.
   *
   * Without this filter the cycle check over-approximates and rejects
   * legitimate placements: e.g., a May spawn referencing back to an
   * April parent doesn't contribute to April's evaluation, so it
   * shouldn't contribute to cycle adjacency from April either.
   */
  const inWindowSpawns = (placingBoardId: string, templateId: string): Board[] => {
    const placing = boardsById.get(placingBoardId);
    if (!placing) return [];
    const all = spawnsByTemplate.get(templateId) ?? [];
    // Use the shared timestamp-based helper rather than lexicographic
    // string compare — `Board.startDate`/`endDate` may be either
    // local-ISO (no zone) or UTC-with-`Z` (sync round-trip), and the
    // two encodings don't compare correctly as strings.
    return all.filter((s) =>
      isWithinTimeframe(s.startDate, placing.startDate, placing.endDate),
    );
  };

  const adjacency = new Map<string, Set<string>>();
  const addEdge = (from: string, to: string): void => {
    if (from === to) return; // self-edges don't contribute to a multi-step cycle
    const set = adjacency.get(from) ?? new Set<string>();
    set.add(to);
    adjacency.set(from, set);
  };

  for (const bt of allBoardTasks) {
    // Board-integrity PR-1 (docs/BOARD_INTEGRITY.md) — a tombstoned
    // placement no longer places the task on this board; including its
    // edge would yield a false-positive cycle rejection for an
    // Achievement that's no longer actually placed there.
    if (bt.isDeleted) continue;
    const t = tasksById.get(bt.taskId);
    if (!t || t.type !== TaskType.ACHIEVEMENT) continue;
    // Skip placements on a deleted/missing board — derivation ignores
    // them, and including their edges in the graph yields false-positive
    // cycle rejections. (Soft-deleted boards filtered out of
    // `boardsById` above.)
    if (!boardsById.has(bt.boardId)) continue;
    if (t.referencedBoardId) {
      // Skip edges pointing at a deleted/missing referenced board.
      // Same reasoning: derivation never evaluates those targets, so
      // the edge can't participate in a real cycle.
      if (!boardsById.has(t.referencedBoardId)) continue;
      addEdge(bt.boardId, t.referencedBoardId);
    } else if (t.referencedTemplateId) {
      // `inWindowSpawns` already filters to non-deleted spawns (it
      // iterates `boardsById.values()`), so no extra guard needed here.
      for (const target of inWindowSpawns(bt.boardId, t.referencedTemplateId)) {
        addEdge(bt.boardId, target.id);
      }
    }
  }

  // Inject the candidate's prospective edges from each parent. The candidate
  // (Task + its placements) may already be reflected in `allBoardTasks`
  // (e.g., editing an existing Task) — re-adding identical edges is
  // idempotent (Set semantics). Template fan-out is window-aware per
  // parent: a candidate placed on two boards with different windows gets
  // different in-window spawn sets per placement.
  //
  // Skip parents that don't resolve to a non-deleted board (mirrors the
  // existing-placement guard above). Pre-resolve the candidate's
  // `referencedBoardId` to a known non-deleted board id so a deleted
  // reference doesn't contribute any edges — derivation wouldn't
  // evaluate it either, so no real cycle can run through it.
  const refBoardResolved =
    referencedBoardId && boardsById.has(referencedBoardId)
      ? referencedBoardId
      : undefined;
  const allCandidateTargets = new Set<string>();
  for (const parentId of parentBoardIds) {
    if (!boardsById.has(parentId)) continue;
    if (refBoardResolved) {
      addEdge(parentId, refBoardResolved);
      allCandidateTargets.add(refBoardResolved);
    }
    if (referencedTemplateId) {
      for (const target of inWindowSpawns(parentId, referencedTemplateId)) {
        addEdge(parentId, target.id);
        allCandidateTargets.add(target.id);
      }
    }
  }

  // ── DFS from each candidate target looking for a path back to any parent ──
  for (const start of allCandidateTargets) {
    const path = dfsToAnyTarget(start, parentSet, adjacency, new Set<string>());
    if (path !== null) {
      // The hit board id (`path[path.length - 1]`) is the parent we landed
      // on. Prepend it again so the returned cyclePath reads parent → … →
      // back to parent — making the cycle visually obvious.
      const closingParent = path[path.length - 1];
      return { ok: false, cyclePath: [closingParent, ...path] };
    }
  }

  return { ok: true };
}

/**
 * Iterative DFS — returns the path from `start` to any node in `targets`
 * if reachable, or `null` if not. Visited-set prevents revisits (graph may
 * have cycles unrelated to the candidate).
 *
 * The `visited` check runs BEFORE the `targets` hit-check so a node we've
 * already explored isn't reported as a fresh hit on its second pop. This
 * matters for graphs where an intermediate node is also in `targets`:
 * without the early-skip, the path returned would include the already-
 * visited node at the end rather than being a clean reachability path.
 * The self-reference guards in `hasCycle` already short-circuit the
 * "start node is in targets" case, so the explicit hit check below is
 * only reached for genuine traversal endpoints.
 */
function dfsToAnyTarget(
  start: string,
  targets: Set<string>,
  adjacency: Map<string, Set<string>>,
  visited: Set<string>,
): string[] | null {
  // Stack carries (node, pathSoFar) so we can reconstruct the path on hit.
  const stack: Array<{ node: string; path: string[] }> = [{ node: start, path: [start] }];
  while (stack.length > 0) {
    const { node, path } = stack.pop()!;
    if (visited.has(node)) continue;
    if (targets.has(node)) return path;
    visited.add(node);
    const neighbors = adjacency.get(node);
    if (!neighbors) continue;
    for (const next of neighbors) {
      if (!visited.has(next)) {
        stack.push({ node: next, path: [...path, next] });
      }
    }
  }
  return null;
}
