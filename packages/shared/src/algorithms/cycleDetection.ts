import type { Board, BoardTask } from '../types';

/**
 * Phase 6.3 — cycle detection for achievement-square cross-board references.
 *
 * Achievement squares can reference another board (`referencedBoardId`) or a
 * recurring template (`referencedTemplateId`, which fans out to all of the
 * template's spawned boards). Without a check, a user could create a chain
 * that loops back on itself — Square on A → references B; Square on B →
 * references A — leaving both boards stuck in a deadlock where neither can
 * ever satisfy the other (derivation reads stored states, so no infinite
 * loop, but the user-visible behavior is broken).
 *
 * `hasCycle` runs at placement time. Given a candidate placement (the
 * `BoardTask` the user is about to write), it returns `{ ok: true }` if no
 * cycle would form, or `{ ok: false; cyclePath }` with the chain of board
 * ids that closes the loop, suitable for surfacing in the UI.
 *
 * Cycle detection is best-effort, NOT a strict invariant: two devices
 * concurrently placing achievement squares can each individually pass their
 * own check and still form a cycle once both writes settle. Derivation reads
 * stored states (not recursive computations), so a post-sync cycle just
 * leaves the involved boards stuck rather than crashing.
 *
 * Mirrors the iOS `CycleDetection.swift` implementation — when one changes,
 * the other must change in lockstep.
 */

export interface CycleCheckCandidate {
  /** The board the achievement square sits on (the *parent* board). */
  boardId: string;
  /** Optional: the specific board id the square would reference. */
  referencedBoardId?: string;
  /** Optional: the recurring-template id the square would reference. */
  referencedTemplateId?: string;
}

export interface CycleCheckContext {
  /** All non-deleted board_tasks in the workspace (used to walk the graph). */
  allBoardTasks: BoardTask[];
  /** All non-deleted boards in the workspace (used to resolve template
   *  spawns AND to check the parent's `spawnedFromTemplateId` for
   *  template-self-reference). */
  allBoards: Board[];
}

export type CycleCheckResult =
  | { ok: true }
  | { ok: false; cyclePath: string[] };

/**
 * Walks the reference graph from the candidate placement looking for a path
 * back to the candidate's own `boardId`. Self-reference of either kind is
 * a degenerate one-step cycle and short-circuits.
 *
 * Algorithm:
 *   1. Self-reference checks first (cheap, common bug guards).
 *   2. Build adjacency: `boardId → outgoing target boardIds`. Edges come
 *      from achievement-square `BoardTask` rows on each board:
 *        - `referencedBoardId`: one direct edge.
 *        - `referencedTemplateId`: fan-out edge to every non-deleted board
 *          with `spawnedFromTemplateId === referencedTemplateId`.
 *   3. Inject the candidate's outgoing edges from `boardId` so the walk
 *      considers the placement under consideration.
 *   4. DFS from the candidate's targets; if we reach `boardId`, return the
 *      path.
 */
export function hasCycle(
  candidate: CycleCheckCandidate,
  context: CycleCheckContext,
): CycleCheckResult {
  const { boardId, referencedBoardId, referencedTemplateId } = candidate;
  const { allBoardTasks, allBoards } = context;

  // ── Self-reference: degenerate cycle ──
  if (referencedBoardId && referencedBoardId === boardId) {
    return { ok: false, cyclePath: [boardId, boardId] };
  }
  if (referencedTemplateId) {
    // Template-self-reference: the parent board is itself a spawn of the
    // template the square would watch. The square would (conceptually)
    // wait on its own parent's status — degenerate.
    const parent = allBoards.find((b) => b.id === boardId);
    if (parent && parent.spawnedFromTemplateId === referencedTemplateId) {
      return { ok: false, cyclePath: [boardId, boardId] };
    }
  }

  // ── Build adjacency from existing board_tasks ──
  // Map<boardId, Set<targetBoardId>>
  const adjacency = new Map<string, Set<string>>();

  // Index spawns once for template-fan-out edges.
  const spawnsByTemplate = new Map<string, string[]>();
  for (const b of allBoards) {
    if (b.isDeleted) continue;
    if (b.spawnedFromTemplateId) {
      const list = spawnsByTemplate.get(b.spawnedFromTemplateId) ?? [];
      list.push(b.id);
      spawnsByTemplate.set(b.spawnedFromTemplateId, list);
    }
  }

  const addEdge = (from: string, to: string): void => {
    if (from === to) return; // self-edges don't contribute to a multi-step cycle
    const set = adjacency.get(from) ?? new Set<string>();
    set.add(to);
    adjacency.set(from, set);
  };

  for (const bt of allBoardTasks) {
    if (!bt.isAchievementSquare) continue;
    if (bt.referencedBoardId) {
      addEdge(bt.boardId, bt.referencedBoardId);
    } else if (bt.referencedTemplateId) {
      const targets = spawnsByTemplate.get(bt.referencedTemplateId) ?? [];
      for (const t of targets) addEdge(bt.boardId, t);
    }
  }

  // Inject the candidate's prospective edges. The candidate is NOT yet in
  // `allBoardTasks` (it's the row about to be written), so its outgoing
  // edges must be added explicitly.
  const candidateTargets = new Set<string>();
  if (referencedBoardId) candidateTargets.add(referencedBoardId);
  if (referencedTemplateId) {
    const targets = spawnsByTemplate.get(referencedTemplateId) ?? [];
    for (const t of targets) candidateTargets.add(t);
  }
  for (const t of candidateTargets) addEdge(boardId, t);

  // ── DFS from each candidate target looking for a path back to boardId ──
  // Visited-set keyed on board id; standard cycle-walk. We track the path
  // so the failure return can show the user which boards form the loop.
  for (const start of candidateTargets) {
    const path = dfsToTarget(start, boardId, adjacency, new Set<string>());
    if (path !== null) {
      // Prepend the candidate's own boardId so the returned cyclePath
      // reads start → … → loops back to start. Trailing element is
      // boardId again, making the cycle visually obvious.
      return { ok: false, cyclePath: [boardId, ...path] };
    }
  }

  return { ok: true };
}

/**
 * Iterative DFS — returns the path from `start` to `target` if reachable,
 * or `null` if not. Visited-set prevents revisits (graph may have cycles
 * unrelated to the candidate; we just need to know if `target` is
 * reachable from `start`).
 */
function dfsToTarget(
  start: string,
  target: string,
  adjacency: Map<string, Set<string>>,
  visited: Set<string>,
): string[] | null {
  // Stack carries (node, pathSoFar) so we can reconstruct the path on hit.
  const stack: Array<{ node: string; path: string[] }> = [{ node: start, path: [start] }];
  while (stack.length > 0) {
    const { node, path } = stack.pop()!;
    if (node === target) return path;
    if (visited.has(node)) continue;
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
