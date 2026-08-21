import { useMemo } from 'react';
import { useLiveQuery } from 'dexie-react-hooks';
import {
  BoardStatus,
  computeBoardGrid,
  detectBingos,
  resolvePlacements,
  type Board,
  type BoardSize,
  type BoardTask,
  type CellState,
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
  /**
   * Board-integrity PR-3 (issue #360) — the kernel's per-cell resolution
   * (`computeBoardGrid`'s `cells[]`), keyed by `BoardTask.id`. The single
   * source of truth for "is this cell done" (including the ACHIEVEMENT
   * branch, which `taskToSquareState` can't resolve on its own — it has no
   * cross-board context). Every render surface that needs a cell's
   * completion should read from here rather than re-deriving.
   */
  cellStateByBoardTaskId: Record<string, CellState>;
  /**
   * Board-integrity PR-3, Part 3 (ring coherence) — the bingo line ids
   * detected from the SAME live kernel grid `cellStateByBoardTaskId` was
   * built from, for THIS render. On a live (unsealed) board this is what
   * the gold ring should highlight from — not `board.completedLineIds`,
   * whose write lags one cascade transaction behind the reactive grid (the
   * render-side stale-ring window pull-ordering transients created). Sealed
   * boards render their frozen `board.completedLineIds`/`sealedCompletedCells`
   * snapshot instead (this field is still computed for them but unused).
   */
  liveCompletedLineIds: string[];
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
  /**
   * P6 (Task Pools + Recurring Boards Rework, docs/POOLS_RECURRING.md
   * §Surfaces item 7) — the `RecurringBoardTemplate` this board was spawned
   * from (`board.spawnedFromTemplateId`), looked up from `allTemplates`
   * (already fetched above for the achievement-badge lookup). `undefined`
   * for a one-off board, OR a repeating board whose template was hard-gone
   * (shouldn't happen — templates only soft-delete). Lets
   * `BoardPlaySurface` render the manage row / spawn-provenance note
   * without a second template fetch.
   */
  sourceTemplate: RecurringBoardTemplate | undefined;
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

  const gridSize = board.boardSize ?? 3;

  // Board-integrity PR-2 (docs/BOARD_INTEGRITY.md, Part 2) — resolve the raw
  // live rows through the shared winner rule BEFORE any reader (render,
  // edit-draft seeding via this hook's `boardTasks` output, achievement
  // badge lookup below) touches them, so no two readers can disagree about
  // which row occupies a cell — even before the repair pass (Part 1) has
  // caught up. `resolvePlacements` also drops out-of-bounds rows and
  // filters tombstones (defense-in-depth on top of the query's own filter).
  const rawBoardTasks = useBoardTasks(boardId) ?? EMPTY_BOARD_TASKS;
  const boardTasks =
    rawBoardTasks.length === 0 ? rawBoardTasks : resolvePlacements(rawBoardTasks, gridSize);
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

  // P6 — resolve this board's source template (undefined for a one-off
  // board). Reuses the same `allTemplates` fetch above rather than a
  // second query.
  const sourceTemplate: RecurringBoardTemplate | undefined = board.spawnedFromTemplateId
    ? allTemplates.find((t) => t.id === board.spawnedFromTemplateId)
    : undefined;

  // Windowed Completion — all non-deleted TaskEvents grouped by taskId, plus
  // the board's window start. `taskToSquareState` uses this to resolve each
  // primitive square windowed (derived / compound carve-outs handled inside).
  // Shared with RisoBoard + useBoardPlay's rearrange preview via
  // `useSquareWindowContext` so every board-square surface reads windowed.
  // Hoisted above the kernel memo below (PR-3) since `computeBoardGrid`
  // needs its `eventsByTaskId` to resolve windowed primitive cells.
  const squareWindowContext: SquareWindowContext = useSquareWindowContext(board);

  // Board-integrity PR-3 (issue #360) — the ONE per-cell resolver. Runs the
  // canonical derivation kernel over this board's resolved placements, once
  // per render, memoized on the same inputs `computeBoardStatsUpdate` /
  // `computeSealedCompletedCells` key off. Every render surface that needs
  // "is this cell done" — including the ACHIEVEMENT branch, which
  // `taskToSquareState` can't resolve on its own (it has no cross-board
  // context) — reads from `cellStateByBoardTaskId` below instead of
  // re-deriving the branch order locally (closes the web achievement-render
  // bug: docs/BOARD_INTEGRITY.md finding 2).
  const kernelResult = useMemo(
    () =>
      computeBoardGrid(
        board,
        boardTasks,
        compoundChildrenByCompound,
        taskMap,
        allBoards,
        { eventsByTaskId: squareWindowContext.eventsByTaskId },
      ),
    [board, boardTasks, compoundChildrenByCompound, taskMap, allBoards, squareWindowContext],
  );

  const cellStateByBoardTaskId = useMemo<Record<string, CellState>>(() => {
    const out: Record<string, CellState> = {};
    for (const c of kernelResult.cells) out[c.boardTaskId] = c;
    return out;
  }, [kernelResult]);

  // Board-integrity PR-3, Part 3 (ring coherence) — bingo lines detected
  // from the SAME live grid `cellStateByBoardTaskId` was built from, for
  // THIS render. See the `liveCompletedLineIds` doc on `BoardPlayData`.
  const liveCompletedLineIds = useMemo(
    () => detectBingos(kernelResult.grid, gridSize).completedLines,
    [kernelResult, gridSize],
  );

  // Phase 6.3 — per-cell achievement-task badge data, keyed by
  // BoardTask.id. Board-integrity PR-3: the kernel (`cellStateByBoardTaskId`)
  // already resolved WHICH board/template each achievement cell watches and
  // whether it's met; this memo only adds the display NAME lookups
  // (board/template name), which are outside the kernel's completion-
  // derivation domain (see `AchievementCellBadge`'s doc comment in
  // derivationPass.ts) — no more hand-copying the trigger/meets/spawn-filter
  // logic here.
  const achievementBadgesByBoardTaskId = useMemo<Record<string, AchievementSquareBadgeData>>(() => {
    const out: Record<string, AchievementSquareBadgeData> = {};
    const boardById = new Map<string, Board>();
    for (const b of allBoards) {
      if (b.isDeleted) continue;
      boardById.set(b.id, b);
    }
    const templateById = new Map(allTemplates.map((t) => [t.id, t]));

    for (const bt of boardTasks) {
      const achievement = cellStateByBoardTaskId[bt.id]?.achievement;
      if (!achievement) continue;
      if (achievement.mode === 'specificBoard') {
        const ref = achievement.referencedBoardId ? boardById.get(achievement.referencedBoardId) : undefined;
        out[bt.id] = {
          mode: 'specificBoard',
          referencedBoardName: ref?.name,
          referencedBoardCompleted: achievement.referencedBoardCompleted ?? false,
        };
        continue;
      }
      // mode === 'recurringTemplate'
      const tmpl = achievement.referencedTemplateId
        ? templateById.get(achievement.referencedTemplateId)
        : undefined;
      out[bt.id] = {
        mode: 'recurringTemplate',
        templateName: tmpl?.name,
        templateInWindowMet: achievement.templateInWindowMet ?? 0,
        templateRequiredCount: achievement.templateRequiredCount ?? 0,
      };
    }
    return out;
  }, [boardTasks, cellStateByBoardTaskId, allBoards, allTemplates]);

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

  // `boardTasks` is already `resolvePlacements` output above — sorted by
  // (row, col, id) with at most one row per cell — so this sort/dict-build
  // is now just a cheap re-derivation, not a second source of collision
  // resolution. Kept as separate steps (rather than reading resolvePlacements'
  // order directly) so this stays correct even if a future caller passes
  // `boardTasks` through additional filtering before this point.
  const sortedBoardTasks = [...boardTasks].sort((a, b) =>
    a.row !== b.row ? a.row - b.row : a.col - b.col
  );

  const btByPosition: Record<string, BoardTask> = {};
  for (const bt of sortedBoardTasks) {
    btByPosition[`${bt.row}-${bt.col}`] = bt;
  }

  const isExpired = isBoardExpired(board);

  return {
    boardTasks,
    taskMap,
    compoundChildrenByCompound,
    allBoardTasks,
    allBoards,
    achievementBadgesByBoardTaskId,
    cellStateByBoardTaskId,
    liveCompletedLineIds,
    sharedCounterSourceIds,
    sharedCounterHintsByTaskId,
    sortedBoardTasks,
    gridSize,
    btByPosition,
    isExpired,
    squareWindowContext,
    sourceTemplate,
  };
}
