import { useMemo } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import {
  AchievementTrigger,
  BoardStatus,
  TaskType,
  isWithinTimeframe,
  type Board,
  type BoardSize,
  type BoardTask,
  type CompoundChild,
  type RecurringBoardTemplate,
  type Task,
} from '@oybc/shared';
import { db } from '../db/internal';
import type { SquareWindowContext } from '../db/adapters';
import { useBoardTasks } from './useBoardTasks';
import { useBoards } from './useBoards';
import { useRecurringBoardTemplates } from './useRecurringBoardTemplates';
import { useSquareWindowContext } from './useSquareWindowContext';
import { useTaskLibrary } from '../pages/createPage/useTaskLibrary';
import { isBoardExpired } from '../utils/boardDisplayUtils';
import type { AchievementSquareBadgeData } from '../components/InteractiveTaskSquare';

// Module-scoped frozen empty arrays. Reused as a stable fallback for
// `useLiveQuery(...) ?? FALLBACK` so React Compiler can preserve memoization
// of downstream useCallback/useMemo deps; an inline `?? []` re-allocates on
// every render and trips `react-hooks/preserve-manual-memoization`. Typed as
// the mutable element array because consumers (legacy step helpers) require
// `T[]`, not `readonly T[]`; the runtime frozen array still throws on mutation.
const EMPTY_BOARD_TASKS = Object.freeze([]) as unknown as BoardTask[];
// Phase 6.3 — frozen empty fallbacks for the workspace-wide board /
// template hooks. Same pattern as EMPTY_BOARD_TASKS above (preserves
// React Compiler memoization of downstream deps).
const EMPTY_BOARDS = Object.freeze([]) as unknown as Board[];
const EMPTY_TEMPLATES = Object.freeze([]) as unknown as RecurringBoardTemplate[];

/**
 * The reactive-read + derived-data read-model for playing a board.
 * Extracted from `BoardPlaySurface` (B2-W1, issue #270) — pure code-motion,
 * no behavior change. See that component for how each field is consumed.
 */
export interface BoardPlayData {
  boardTasks: BoardTask[];
  taskMap: Record<string, Task>;
  compoundChildrenByCompound: Record<string, CompoundChild[]>;
  allBoardTasks: BoardTask[];
  allBoards: Board[];
  achievementBadgesByBoardTaskId: Record<string, AchievementSquareBadgeData>;
  sharedCounterSourceIds: Set<string>;
  sharedCounterHintsByTaskId: Map<string, string>;
  sortedBoardTasks: BoardTask[];
  gridSize: BoardSize;
  btByPosition: Record<string, BoardTask>;
  isExpired: boolean;
  /**
   * Windowed Completion (docs/WINDOWED_COMPLETION.md §Semantics): the window
   * context to thread into `taskToSquareState` so each square resolves against
   * THIS board's window (`[startDate, ∞)`) via events instead of the lifetime
   * cache. This is what stops a task completed in a previous window bleeding
   * green onto a freshly-spawned board.
   */
  squareWindowContext: SquareWindowContext;
}

/**
 * Loads and derives all the reactive read-model data `BoardPlaySurface`
 * needs to render a board: the board's own placements, the workspace-wide
 * task/compound-child library, achievement badge data, shared-counter
 * source/hint lookups, and simple grid-layout derivations.
 *
 * @param board - The resolved board being played.
 * @param userId - Active user id, used for workspace-wide compound/achievement lookups.
 */
export function useBoardPlayData(board: Board, userId: string | undefined): BoardPlayData {
  const boardId = board.id;

  const boardTasks = useBoardTasks(boardId) ?? EMPTY_BOARD_TASKS;
  // Post-unification, taskSteps was dropped in Dexie v5. The adapter still
  // accepts a steps array for the legacy progress branch, but every consumer
  // here passes EMPTY_TASK_STEPS — the live query was needlessly hitting a
  // deregistered store. The adapter's progress branch is itself dead code
  // post-migration; Phase 8 will remove it.

  // Compound resolution data (all BoardTasks workspace-wide for child lookup).
  const { taskMap, compoundChildrenByCompound } = useTaskLibrary(userId);

  // Workspace-wide BoardTask list for compound child toggle fallback.
  const allBoardTasks: BoardTask[] =
    useLiveQuery(() => db.boardTasks.filter((bt) => !bt.isDeleted).toArray(), []) ?? EMPTY_BOARD_TASKS;

  // Phase 6.3 — workspace data needed by per-cell badge data computation
  // for ACHIEVEMENT-typed Tasks. Reuses existing hooks; `useBoards`
  // returns non-deleted boards for the user, and
  // `useRecurringBoardTemplates` returns non-deleted templates.
  const allBoards: Board[] = useBoards(userId) ?? EMPTY_BOARDS;
  const allTemplates: RecurringBoardTemplate[] =
    useRecurringBoardTemplates(userId) ?? EMPTY_TEMPLATES;

  // Phase 6.3 — per-cell achievement-task badge data, keyed by
  // BoardTask.id. The badge labels what each ACHIEVEMENT-typed Task is
  // watching; the cell's actual completion state still comes from
  // derivationPass.
  //
  // Build the lookup maps once per render (boardById, spawnsByTemplate)
  // then loop cells to assemble the badge entries. This mirrors the
  // performance optimization in `derivationPass.ts` — without the
  // template index, each template-mode cell would re-scan all boards.
  const achievementBadgesByBoardTaskId = useMemo<Record<string, AchievementSquareBadgeData>>(() => {
    const out: Record<string, AchievementSquareBadgeData> = {};
    const boardById = new Map<string, Board>();
    const spawnsByTemplate = new Map<string, Board[]>();
    for (const b of allBoards) {
      if (b.isDeleted) continue;
      boardById.set(b.id, b);
      if (b.spawnedFromTemplateId) {
        const list = spawnsByTemplate.get(b.spawnedFromTemplateId) ?? [];
        list.push(b);
        spawnsByTemplate.set(b.spawnedFromTemplateId, list);
      }
    }
    const templateById = new Map(allTemplates.map((t) => [t.id, t]));

    for (const bt of boardTasks) {
      const t = taskMap[bt.taskId];
      if (!t || t.type !== TaskType.ACHIEVEMENT) continue;
      const trigger = t.achievementTrigger ?? AchievementTrigger.GREENLOG;
      const meets = (b: Board): boolean =>
        trigger === AchievementTrigger.BINGO
          ? (b.linesCompleted ?? 0) > 0
          : b.status === BoardStatus.COMPLETED;
      // Phase 6.3 precedence: referencedBoardId wins when both fields
      // somehow get set. The Zod refinement should prevent this, but
      // the badge stays predictable for bad-data payloads.
      if (t.referencedBoardId) {
        const ref = boardById.get(t.referencedBoardId);
        out[bt.id] = {
          mode: 'specificBoard',
          referencedBoardName: ref?.name,
          referencedBoardCompleted: ref ? meets(ref) : false,
        };
        continue;
      }
      if (t.referencedTemplateId) {
        const tmpl = templateById.get(t.referencedTemplateId);
        const spawns = spawnsByTemplate.get(t.referencedTemplateId) ?? [];
        // Parse to timestamps via the shared helper — `Board.startDate`/
        // `endDate` may be local-ISO (no zone) or UTC-with-`Z` (sync
        // round-trips), and the two encodings don't compare correctly
        // as strings. Same fix as derivationPass.ts.
        const inWindow = spawns.filter((b) =>
          isWithinTimeframe(b.startDate, board.startDate, board.endDate),
        );
        const met = inWindow.filter(meets).length;
        out[bt.id] = {
          mode: 'recurringTemplate',
          templateName: tmpl?.name,
          templateInWindowMet: met,
          templateRequiredCount: t.requiredCount ?? 0,
        };
      }
      // No reference set on an ACHIEVEMENT task: skip the badge entirely
      // (the cell renders as a regular task; derivation marks incomplete).
    }
    return out;
  }, [boardTasks, allBoards, allTemplates, taskMap, board.startDate, board.endDate]);

  // Phase 3 — Shared Counters: Set of task ids that are shared-counter SOURCES
  // (i.e., at least one other task points to them via `sharedCounterId`).
  // Computed once per render from taskMap so the grid `onAct` can detect
  // whether tapping a counting task should route through incrementSharedCounter.
  const sharedCounterSourceIds = useMemo<Set<string>>(() => {
    const sources = new Set<string>();
    for (const t of Object.values(taskMap)) {
      if (t.sharedCounterId) sources.add(t.sharedCounterId);
      if (t.isCounter === true) sources.add(t.id); // P5: promoted zero-link counters
    }
    return sources;
  }, [taskMap]);

  /**
   * Phase 2 — Shared Counters: for each shared-counter task (source or linked),
   * map its task id → the hint string listing OTHER active boards the counter
   * also appears on (excluding the current board being played).
   *
   * Format:
   *   1 other board  → "↔ Shared · also counts on {name}"
   *   2+ other boards → "↔ Shared · also counts on {name} + {N} more"
   *
   * The hint is used by FloatingContextMenu and DetailModal so the user knows
   * a tap will ripple.
   */
  const sharedCounterHintsByTaskId = useMemo<Map<string, string>>(() => {
    const hints = new Map<string, string>();
    // Build a lookup from boardId → board for active boards.
    const activeBoardsById = new Map<string, Board>();
    for (const b of allBoards) {
      if (!b.isDeleted && b.status === BoardStatus.ACTIVE) {
        activeBoardsById.set(b.id, b);
      }
    }
    // Build a lookup from taskId → set of active boardIds (workspace-wide).
    const activeBoardsByTask = new Map<string, Set<string>>();
    for (const bt of allBoardTasks) {
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
  }, [taskMap, sharedCounterSourceIds, allBoardTasks, allBoards, boardId]);

  const sortedBoardTasks = [...boardTasks].sort((a, b) =>
    a.row !== b.row ? a.row - b.row : a.col - b.col
  );

  const gridSize = board.boardSize ?? 3;

  const btByPosition: Record<string, BoardTask> = {};
  for (const bt of sortedBoardTasks) {
    btByPosition[`${bt.row}-${bt.col}`] = bt;
  }

  const isExpired = isBoardExpired(board);

  // Windowed Completion — all non-deleted TaskEvents grouped by taskId, plus
  // the board's window start. `taskToSquareState` uses this to resolve each
  // primitive square windowed (derived / compound carve-outs handled inside).
  // Shared with RisoBoard + useBoardPlay's rearrange preview via
  // `useSquareWindowContext` so every board-square surface reads windowed.
  const squareWindowContext: SquareWindowContext = useSquareWindowContext(board);

  return {
    boardTasks,
    taskMap,
    compoundChildrenByCompound,
    allBoardTasks,
    allBoards,
    achievementBadgesByBoardTaskId,
    sharedCounterSourceIds,
    sharedCounterHintsByTaskId,
    sortedBoardTasks,
    gridSize,
    btByPosition,
    isExpired,
    squareWindowContext,
  };
}
