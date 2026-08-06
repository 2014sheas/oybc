import type { Task, CompoundChild, BoardTask, Board } from '../types';
import { detectBingos, type BoardSize, CenterSquareType } from '@oybc/bingo-core';
import { AchievementTrigger, BoardStatus, TaskType } from '../constants/enums';
import { isWithinTimeframe } from './calendarBoundaries';
import { evaluateCompound } from './compoundEvaluation';
import {
  resolveTaskWindowState,
  isEventOwningTask,
  type CompoundWindowContext,
  type WindowEvaluationContext,
} from './taskEvents';

/**
 * Walk `compound_children` upward from `changedTaskId` and return the set of
 * compound Task ids that transitively contain it as a child.
 *
 * Bounded by compound-nesting depth (typically ≤ 2 in practice). Stops on
 * cycles defensively (a child that's already in the result set is not
 * re-queued).
 *
 * @param changedTaskId  The Task whose state just changed.
 * @param children       All non-deleted CompoundChild rows in the workspace
 *                       (deleted rows are filtered internally).
 * @returns Set of compound Task ids that transitively contain the changed task.
 */
export function findTransitiveParentCompounds(
  changedTaskId: string,
  children: CompoundChild[],
): Set<string> {
  const out = new Set<string>();
  const queue: string[] = [changedTaskId];
  while (queue.length > 0) {
    const id = queue.shift()!;
    for (const link of children) {
      if (link.isDeleted) continue;
      if (link.childTaskId === id && !out.has(link.compoundTaskId)) {
        out.add(link.compoundTaskId);
        queue.push(link.compoundTaskId);
      }
    }
  }
  return out;
}

/**
 * Resolve the set of board ids that need recomputing after `changedTaskId`
 * updates. A board is affected if it places either:
 *   - the changed task directly, OR
 *   - any compound that transitively contains the changed task.
 *
 * @param changedTaskId   The Task whose state just changed.
 * @param parentCompounds Set of compound Task ids that transitively contain the changed task.
 * @param boardTasks      All BoardTask rows in the workspace (non-deleted
 *                        rows are filtered internally — Board-integrity PR-1).
 * @returns Set of board ids that need their stats recomputed.
 */
export function findAffectedBoardIds(
  changedTaskId: string,
  parentCompounds: Set<string>,
  boardTasks: BoardTask[],
): Set<string> {
  const taskIds = new Set<string>([changedTaskId, ...parentCompounds]);
  const out = new Set<string>();
  for (const bt of boardTasks) {
    if (bt.isDeleted) continue;
    if (taskIds.has(bt.taskId)) out.add(bt.boardId);
  }
  return out;
}

/**
 * Board-integrity PR-3 (issue #360) — per-cell achievement-badge inputs
 * attached to a {@link CellState} when the cell's Task is ACHIEVEMENT-typed
 * and carries a reference (`referencedBoardId` XOR `referencedTemplateId`).
 *
 * Deliberately carries only the RAW ids/counts the kernel already computed
 * while resolving `isCompleted` — NOT display names. Both platforms' render
 * layers already maintain their own board/template lookup maps (for other
 * reasons — the workspace board list, the recurring-template list); adding a
 * `RecurringBoardTemplate[]` parameter to the kernel just to resolve a label
 * string would widen `computeBoardStatsUpdate`/`computeSealedCompletedCells`
 * beyond the "signatures unchanged" constraint for a cosmetic lookup the
 * caller can do in one line from data it already has. See
 * `apps/web/src/hooks/useBoardPlayData.ts`'s `achievementBadgesByBoardTaskId`
 * memo (web) / `BoardPlayView.achievementBadge(for:)` (iOS) for the thin
 * name-resolution step built on top of these ids.
 */
export interface AchievementCellBadge {
  mode: 'specificBoard' | 'recurringTemplate';
  /** Specific-board mode only. */
  referencedBoardId?: string;
  /** Specific-board mode only — whether the referenced board (if it still
   *  exists and isn't soft-deleted) currently meets the Task's trigger. */
  referencedBoardCompleted?: boolean;
  /** Recurring-template mode only. */
  referencedTemplateId?: string;
  /** Recurring-template mode only — count of in-window spawns meeting the
   *  trigger (0 when the in-window spawn set is empty). */
  templateInWindowMet?: number;
  /** Recurring-template mode only — the Task's `requiredCount` (0 if unset). */
  templateRequiredCount?: number;
}

/**
 * Board-integrity PR-3 (issue #360) — one per-cell resolution result from
 * {@link computeBoardGrid}, one entry per surviving `BoardTask` placement
 * (i.e. NOT the odd-board FREE center auto-fill, which is not a
 * placement and has no BoardTask/Task id to key on).
 *
 * This is the single per-cell "is this done, and if it's an achievement
 * square what is it watching" resolution both platforms' render surfaces
 * (play grid, board-preview mini-grid, achievement badge) now read instead
 * of hand-mirroring the branch order themselves.
 */
export interface CellState {
  boardTaskId: string;
  taskId: string;
  row: number;
  col: number;
  /** Flat index (`row * boardSize + col`) — matches `grid`'s indexing and
   *  `Board.sealedCompletedCells`'s encoding. */
  idx: number;
  /** Exactly the boolean this placement contributed to `grid[idx]` — for a
   *  cell a later duplicate placement lost to (the `grid[idx]` dup-guard),
   *  no CellState is emitted at all (see {@link computeBoardGrid}). */
  isCompleted: boolean;
  /** Present only when the Task is ACHIEVEMENT-typed and carries a
   *  reference. Absent for every other cell, and for a reference-less
   *  ACHIEVEMENT Task (degrades to incomplete, no badge — write-time
   *  validation should already reject that shape). */
  achievement?: AchievementCellBadge;
}

/**
 * The shape returned by `computeBoardStatsUpdate` — a payload the caller
 * applies to the `boards` row, plus signals it can surface to the user.
 */
export interface BoardStatsUpdate {
  boardId: string;
  completedTasks: number;
  linesCompleted: number;
  completedLineIds: string[];
  /** Bingo lines that newly appeared since the previous boards.completedLineIds. */
  newBingos: string[];
  /** Bingo lines that disappeared since the previous boards.completedLineIds. */
  lostBingos: string[];
}

/**
 * For one board: rebuild its completion grid (reading post-write Task states +
 * recursively evaluating compounds), run bingo detection, diff against the
 * board's previous `completedLineIds`, and return the stats payload the caller
 * should write to `boards`.
 *
 * Pure — no I/O, no input mutation. Caller is responsible for actually
 * persisting the returned payload + enqueuing the sync entry.
 *
 * Center auto-fill: for odd-sized boards (3 / 5) where the centre square is
 * unoccupied AND the board's centerSquareType is FREE, the
 * centre cell is treated as completed (mirrors current per-platform logic).
 *
 * @param board              The board whose stats need recomputing.
 * @param boardTasksOnBoard  All BoardTask rows for this specific board.
 * @param childrenByCompound Map of compoundTaskId → list of CompoundChild rows.
 * @param taskById           Map of taskId → Task (all tasks in the workspace).
 * @param allBoards          All non-deleted boards in the workspace. Required
 *                           for Phase 6.3 ACHIEVEMENT-typed Tasks — they
 *                           read another board's (or template-spawn set's)
 *                           state directly. Pass `[]` when the caller has
 *                           no cross-board context (will degrade those
 *                           branches to "incomplete", matching the
 *                           missing-reference semantic).
 * @returns A payload to MERGE into the board row. The caller is responsible
 *          for ALSO setting `board.updatedAt` (current timestamp) and
 *          incrementing `board.version` before persisting — those are
 *          deliberately omitted here because shared has no clock access.
 *          Skipping them silently breaks LWW sync; both platforms' write
 *          path code must remember to apply them.
 */
export function computeBoardStatsUpdate(
  board: Board,
  boardTasksOnBoard: BoardTask[],
  childrenByCompound: Record<string, CompoundChild[]>,
  taskById: Record<string, Task>,
  allBoards: Board[],
  windowContext: WindowEvaluationContext | undefined,
): BoardStatsUpdate {
  const { grid, completedTasks } = computeBoardGrid(
    board,
    boardTasksOnBoard,
    childrenByCompound,
    taskById,
    allBoards,
    windowContext,
  );

  const detection = detectBingos(grid, board.boardSize as BoardSize);
  const previous = new Set(board.completedLineIds ?? []);
  const current = new Set(detection.completedLines);
  const newBingos = detection.completedLines.filter((l) => !previous.has(l));
  const lostBingos = (board.completedLineIds ?? []).filter((l) => !current.has(l));

  return {
    boardId: board.id,
    completedTasks,
    linesCompleted: detection.completedLines.length,
    completedLineIds: detection.completedLines,
    newBingos,
    lostBingos,
  };
}

/**
 * Re-derive the set of green cell indexes (`row * size + col`) for a board from
 * the (windowed or lifetime) task state — the pure input to a sealed board's
 * `sealedCompletedCells` snapshot (docs §Seal snapshots re-derive from the
 * event union). Deterministic: the same converged event union yields the same
 * cells on any device, so sealing never LWW-races.
 *
 * Sealing itself (Board schema fields, the seal transaction, the pull-path
 * re-derivation hook) lands in PR C; this builder is the shared kernel it and
 * the migration's expired-board sealing call.
 *
 * @param board              The board to snapshot.
 * @param boardTasksOnBoard  All BoardTask rows for this board.
 * @param childrenByCompound Map of compoundTaskId → CompoundChild rows.
 * @param taskById           Map of taskId → Task.
 * @param allBoards          Cross-board context (achievement watchers).
 * @param windowContext      Windowed-event context; pass `undefined` for
 *                           lifetime resolution (deliberate migration / seal
 *                           snapshots). Required positionally so a live
 *                           cascade can never silently fall back to lifetime.
 * @returns Ascending cell indexes that are green.
 */
export function computeSealedCompletedCells(
  board: Board,
  boardTasksOnBoard: BoardTask[],
  childrenByCompound: Record<string, CompoundChild[]>,
  taskById: Record<string, Task>,
  allBoards: Board[],
  windowContext: WindowEvaluationContext | undefined,
): number[] {
  const { grid } = computeBoardGrid(
    board,
    boardTasksOnBoard,
    childrenByCompound,
    taskById,
    allBoards,
    windowContext,
  );
  const cells: number[] = [];
  for (let i = 0; i < grid.length; i += 1) {
    if (grid[i]) cells.push(i);
  }
  return cells;
}

/**
 * Shared grid builder for `computeBoardStatsUpdate` + `computeSealedCompletedCells`
 * — and, as of Board-integrity PR-3 (issue #360), the ONE per-cell resolver
 * both platforms' render surfaces (play grid, board-preview mini-grid,
 * achievement badge) call into directly instead of hand-mirroring this
 * branch order themselves.
 *
 * Returns the completion grid plus the `completedTasks` tally computed with the
 * exact same increment logic both callers historically used, PLUS `cells` — a
 * {@link CellState} per surviving BoardTask placement (see that type's docs).
 * `grid`/`completedTasks` are computed by the EXACT same code path as before
 * PR-3 (only additionally recorded into a `cells` entry) — this widening is
 * additive and byte-identical for those two fields. When `windowContext` is
 * absent the resolution is byte-identical to the pre-Windowed-Completion
 * behavior (lifetime `isCompleted` cache); when present, primitive squares
 * resolve against the board's window via events and derived-counting squares
 * stay on their cache (the carve-out).
 */
export function computeBoardGrid(
  board: Board,
  boardTasksOnBoard: BoardTask[],
  childrenByCompound: Record<string, CompoundChild[]>,
  taskById: Record<string, Task>,
  allBoards: Board[],
  windowContext: WindowEvaluationContext | undefined,
): { grid: boolean[]; completedTasks: number; cells: CellState[] } {
  const size = board.boardSize as BoardSize;
  const totalSquares = size * size;
  const grid: boolean[] = new Array(totalSquares).fill(false);
  let completedTasks = 0;
  const cells: CellState[] = [];

  // Window context for compound + primitive resolution. `board.startDate` is
  // the window lower bound `[startDate, ∞)`; indefinite boards use it too.
  const compoundCtx: CompoundWindowContext | undefined = windowContext
    ? { windowStart: board.startDate, eventsByTaskId: windowContext.eventsByTaskId }
    : undefined;

  /** Resolve a primitive (normal / counting) square, windowed or lifetime. */
  const resolvePrimitive = (t: Task): boolean => {
    if (!windowContext) return t.isCompleted;
    // Derived-task carve-out: shared-counter-linked counting squares keep their
    // propagation-stamped lifetime cache (docs §Derived-task carve-out rule 4).
    if (!isEventOwningTask(t)) return t.isCompleted;
    const events = windowContext.eventsByTaskId[t.id] ?? [];
    return resolveTaskWindowState(t, events, board.startDate).isCompleted;
  };

  // Phase 6.3: index all non-deleted boards by id (specific-board mode)
  // and by spawnedFromTemplateId (recurring-template mode). Built lazily —
  // only allocated if at least one boardTask uses one of the new modes —
  // so non-recurring boards pay no cost. `allBoards.length === 0` paths
  // (no cross-board context supplied) skip both maps entirely.
  let boardById: Map<string, Board> | null = null;
  let boardsByTemplateId: Map<string, Board[]> | null = null;
  const buildBoardIndexes = (): void => {
    if (boardById !== null) return;
    boardById = new Map();
    boardsByTemplateId = new Map();
    for (const b of allBoards) {
      if (b.isDeleted) continue;
      boardById.set(b.id, b);
      if (b.spawnedFromTemplateId) {
        const list = boardsByTemplateId.get(b.spawnedFromTemplateId) ?? [];
        list.push(b);
        boardsByTemplateId.set(b.spawnedFromTemplateId, list);
      }
    }
  };

  for (const bt of boardTasksOnBoard) {
    // Defense-in-depth: a tombstoned BoardTask placement (Board-integrity
    // PR-1, docs/BOARD_INTEGRITY.md) must never render/count as a placed
    // cell. Every known caller already pre-filters `!isDeleted` before
    // building `boardTasksOnBoard`, but this kernel is the single point
    // every cascade on both platforms funnels through — mirroring the same
    // belt-and-suspenders posture `findTransitiveParentCompounds` and the
    // `allBoards` index above already use for their own tombstoned inputs.
    if (bt.isDeleted) continue;
    const t = taskById[bt.taskId];
    if (!t || t.isDeleted) continue;

    // Bounds guard: `BoardTaskSchema` only enforces `min(0)` on row/col, so a
    // malformed placement (e.g. `row=0, col=7` on a 5×5) would otherwise alias
    // into a WRONG cell via `row * size + col`. Skip out-of-range placements
    // entirely; the flat-index guard below stays as defense-in-depth.
    if (bt.row >= size || bt.col >= size) continue;

    const idx = bt.row * size + bt.col;
    if (idx < 0 || idx >= totalSquares) continue;

    // Duplicate-placement guard: `completedTasks` counts per CELL, not per
    // placement row. Two placements on one cell (possible via offline sync
    // union — there is no (board,row,col) uniqueness constraint) must not
    // double-count toward the greenlog predicate (`completedTasks >= size²`).
    // Skipping an already-true cell is also order-independent: the cell is
    // green iff ANY of its placements resolves complete, counted once.
    if (grid[idx]) continue;

    // Phase 6.3 — ACHIEVEMENT-typed Tasks are cross-board watchers. The
    // backing Task carries the reference fields (board XOR template); the
    // BoardTask is a pure placement record. Dispatching on `t.type` here
    // is the only point where derivation cares about the task type vs the
    // simple-completion branch below.
    if (t.type === TaskType.ACHIEVEMENT) {
      // Trigger selects what "done" means for the watched target.
      // Default GREENLOG matches the pre-trigger shipped behavior so
      // older payloads decode safely (the Zod schema also defaults).
      const trigger = t.achievementTrigger ?? AchievementTrigger.GREENLOG;
      const meets = (b: Board): boolean =>
        trigger === AchievementTrigger.BINGO
          ? (b.linesCompleted ?? 0) > 0
          : b.status === BoardStatus.COMPLETED;

      // Precedence: `referencedBoardId` wins when both fields are set.
      // The Zod refinement rejects rows that set both, but a malicious
      // remote payload or older client could still produce one — pick
      // the more specific reference deterministically so derivation is
      // predictable.
      if (t.referencedBoardId) {
        // Specific-board mode: square completes when the referenced
        // board meets the trigger AND is non-deleted. Soft-deleted ⇒
        // incomplete (not crash; not silently ignore — UI can surface
        // a "needs attention" badge separately). `requiredCount` is
        // ignored in this mode (the named board is either done or not).
        buildBoardIndexes();
        const ref = boardById!.get(t.referencedBoardId);
        const refCompleted = ref ? meets(ref) : false;
        if (refCompleted) {
          grid[idx] = true;
          completedTasks += 1;
        }
        cells.push({
          boardTaskId: bt.id,
          taskId: t.id,
          row: bt.row,
          col: bt.col,
          idx,
          isCompleted: refCompleted,
          achievement: {
            mode: 'specificBoard',
            referencedBoardId: t.referencedBoardId,
            referencedBoardCompleted: refCompleted,
          },
        });
        continue;
      }

      if (t.referencedTemplateId) {
        // Recurring-template mode: count how many in-window spawns
        // meet the trigger, then compare against `requiredCount`.
        // The cell completes when:
        //   - the in-window non-deleted spawn set is non-empty
        //     (matches the locked "empty window = incomplete, NOT
        //     vacuously true" rule), AND
        //   - the number of in-window spawns meeting the trigger is
        //     >= `requiredCount`.
        // When fewer in-window spawns exist than `requiredCount`
        // requires, the cell stays incomplete and waits for future
        // spawns. Window membership is inclusive on both ends.
        buildBoardIndexes();
        const spawns = boardsByTemplateId!.get(t.referencedTemplateId) ?? [];
        // Parse to timestamps via the shared helper rather than
        // lexicographic string compare — `Board.startDate`/`endDate`
        // may be either local-ISO (no zone) or UTC-with-`Z` (sync
        // round-trips Firestore Timestamps), and the two encodings
        // don't compare correctly as strings.
        const inWindow = spawns.filter((b) =>
          isWithinTimeframe(b.startDate, board.startDate, board.endDate),
        );
        // `metCount` is computed regardless of whether inWindow is empty
        // (naturally 0 in that case) so the badge always carries an
        // honest "M/N" pair — matches the pre-PR-3 UI memos, which never
        // skipped assembling the badge just because the window was empty.
        const metCount = inWindow.filter(meets).length;
        const required = t.requiredCount ?? 0;
        const templateDone = inWindow.length > 0 && required > 0 && metCount >= required;
        if (templateDone) {
          grid[idx] = true;
          completedTasks += 1;
        }
        cells.push({
          boardTaskId: bt.id,
          taskId: t.id,
          row: bt.row,
          col: bt.col,
          idx,
          isCompleted: templateDone,
          achievement: {
            mode: 'recurringTemplate',
            referencedTemplateId: t.referencedTemplateId,
            templateInWindowMet: metCount,
            templateRequiredCount: required,
          },
        });
        continue;
      }

      // No reference set → incomplete (achievement Task lacking the XOR
      // value should have been rejected at write time; degrade safely).
      cells.push({
        boardTaskId: bt.id,
        taskId: t.id,
        row: bt.row,
        col: bt.col,
        idx,
        isCompleted: false,
      });
      continue;
    }

    const isDone =
      t.type === TaskType.COMPOUND
        ? evaluateCompound(t, childrenByCompound, taskById, compoundCtx)
        : resolvePrimitive(t);
    if (isDone) {
      grid[idx] = true;
      completedTasks += 1;
    }
    cells.push({ boardTaskId: bt.id, taskId: t.id, row: bt.row, col: bt.col, idx, isCompleted: isDone });
  }

  // Center auto-fill for odd-sized boards with a FREE center.
  if (size % 2 === 1) {
    const centerRow = Math.floor(size / 2);
    const centerCol = Math.floor(size / 2);
    const centerIdx = centerRow * size + centerCol;
    const hasCenterTask = boardTasksOnBoard.some(
      (bt) => bt.row === centerRow && bt.col === centerCol,
    );
    if (
      !hasCenterTask &&
      board.centerSquareType === CenterSquareType.FREE &&
      !grid[centerIdx]
    ) {
      grid[centerIdx] = true;
      completedTasks += 1;
    }
  }

  return { grid, completedTasks, cells };
}
