import { isFrozenDerivedRow, type Board, type BoardTask, type Task } from '@oybc/shared';
import { isBoardCreditable } from './boardDisplayUtils';

/** Inputs to {@link buildSharedCounterHints}. */
export interface SharedCounterHintsInput {
  /** Workspace-wide id → Task lookup. */
  taskMap: Record<string, Task>;
  /** Ids of tasks other tasks point at (shared-counter roots). */
  sharedCounterSourceIds: Set<string>;
  /** Every live placement in the workspace. */
  allBoardTasks: BoardTask[];
  allBoards: Board[];
  /** The board being played — excluded from its own hint. */
  boardId: string;
  /** Pinned clock (sealed / ended / frozen checks). */
  now: Date;
}

/**
 * "↔ Shared · also counts on {board}" hints for every member of every
 * shared-counter group, so the stepper / context menu can say a log ripples.
 *
 *   1 other board  → "↔ Shared · also counts on {name}"
 *   2+ other boards → "↔ Shared · also counts on {name} + {N} more"
 *
 * Windowed linked counters (owner rule 2026-10-01): a board qualifies only if
 * a log can still change it (`isBoardCreditable` — live, ACTIVE, not sealed,
 * not ended) AND its member row is live for its window (`!isFrozenDerivedRow`).
 * `status === ACTIVE` alone kept a closed June board in a September log's hint.
 * Mirrors the credit toast set in `propagateToLinkedRows`.
 *
 * @param input - See {@link SharedCounterHintsInput}.
 * @returns taskId → hint text (members of groups with no other qualifying board are absent).
 */
export function buildSharedCounterHints({
  taskMap,
  sharedCounterSourceIds,
  allBoardTasks,
  allBoards,
  boardId,
  now,
}: SharedCounterHintsInput): Map<string, string> {
  const hints = new Map<string, string>();
  // Build a lookup from boardId → board for boards a log can still change.
  // Windowed linked counters (owner rule 2026-10-01): a sealed (Closed) or
  // ended board is excluded — `status === ACTIVE` alone kept a closed board
  // in the hint.
  const nowDate = now;
  const nowIso = nowDate.toISOString();
  const activeBoardsById = new Map<string, Board>();
  for (const b of allBoards) {
    if (isBoardCreditable(b, nowDate)) {
      activeBoardsById.set(b.id, b);
    }
  }
  // Build a lookup from taskId → set of active boardIds (workspace-wide).
  const activeBoardsByTask = new Map<string, Set<string>>();
  for (const bt of allBoardTasks) {
    // …and only boards whose member row is LIVE for its window (a frozen
    // window-stamped row no longer takes logs).
    const member = taskMap[bt.taskId];
    if (member && isFrozenDerivedRow(member, nowIso)) continue;
    if (activeBoardsById.has(bt.boardId)) {
      let set = activeBoardsByTask.get(bt.taskId);
      if (!set) { set = new Set(); activeBoardsByTask.set(bt.taskId, set); }
      set.add(bt.boardId);
    }
  }

  // For each shared-counter group, collect all member task ids,
  // resolve their OTHER active board names, and build the hint.
  for (const sourceId of Object.keys(taskMap)) {
    // Only process sources (tasks that other tasks point to).
    if (!sharedCounterSourceIds.has(sourceId)) continue;

    // Find all member task ids: source + every linked task.
    const memberIds: string[] = [sourceId];
    for (const t of Object.values(taskMap)) {
      if (t.sharedCounterId === sourceId) memberIds.push(t.id);
    }

    // Collect distinct active board names EXCLUDING the current play board.
    const otherBoardNames = new Set<string>();
    for (const memberId of memberIds) {
      const memberBoards = activeBoardsByTask.get(memberId);
      if (!memberBoards) continue;
      for (const bId of memberBoards) {
        if (bId === boardId) continue;
        const b = activeBoardsById.get(bId);
        if (b) otherBoardNames.add(b.name);
      }
    }

    if (otherBoardNames.size === 0) continue;

    const namesArr = [...otherBoardNames];
    const hint =
      namesArr.length === 1
        ? `↔ Shared · also counts on ${namesArr[0]}`
        : `↔ Shared · also counts on ${namesArr[0]} + ${namesArr.length - 1} more`;

    // Apply the same hint to every member task in this group.
    for (const memberId of memberIds) {
      if (taskMap[memberId]) hints.set(memberId, hint);
    }
  }
  return hints;
}
