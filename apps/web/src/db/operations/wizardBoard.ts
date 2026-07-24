import {
  BoardStatus,
  CenterSquareType,
  SyncOperationType,
  computeBoardStatsUpdate,
  isGoalLessCounter,
  type CompoundChild,
  type CreateBoardInput,
  type Task,
} from '@oybc/shared';
import { db } from '../internal';
import { activateBoard, createBoard, updateBoard } from './boards';
import { buildWindowContext } from './windowContext';
import { createBoardTask, deleteBoardTasksForBoard } from './boardTasks';
import { addToSyncQueue } from './syncQueue';
import { currentTimestamp } from '../utils';

/**
 * One not-yet-persisted task created inside the wizard's New Task sheet
 * (Bug #85), to be written atomically before the board_tasks that reference
 * it: the parent task, its child tasks, and the compound_children links.
 */
export interface WizardPendingTaskWrite {
  task: Task;
  childTasks: Task[];
  childLinks: CompoundChild[];
}

/** Inputs for {@link persistWizardBoardRows}. All wizard/UI policy (placement
 *  computation, date resolution, pending-task selection) is resolved by the
 *  caller; this operation only performs the atomic DB write. */
export interface PersistWizardBoardRowsInput {
  userId: string;
  /** Non-null when re-saving an existing draft; null for a fresh create. */
  draftBoardId: string | null;
  /** Phase 6.1 provenance marker; only used on the fresh-create path. */
  isCore: boolean;
  status: 'active' | 'draft';
  /** Board record fields (name, size, timeframe, dates, center, …). */
  boardFields: CreateBoardInput;
  /** Per-cell placement; `null` slots (reserved centre) are skipped. */
  placement: (Task | null)[];
  size: number;
  centerType: CenterSquareType;
  /** In-memory pending tasks; only those actually placed are written. */
  pendingTasks: WizardPendingTaskWrite[];
}

/**
 * Atomically persist the wizard's board, its placements, and any pending
 * tasks in a single Dexie transaction (moved out of `wizardPersist.ts` for
 * B3, issue #284 — the transaction previously lived in a component-tree
 * helper that reached the raw Dexie instance).
 *
 * The board record + its BoardTask rows + any Bug-#85 pending tasks commit or
 * roll back together; `syncQueue` is in scope because the inner helpers
 * enqueue sync entries inline after their row writes.
 *
 * - **Fresh create** (`draftBoardId === null`): `createBoard` (status=DRAFT)
 *   → per-cell `createBoardTask` → if `status === 'active'`, flip to ACTIVE
 *   via `activateBoard`.
 * - **Draft update** (`draftBoardId` set): `updateBoard` with the target
 *   status → `deleteBoardTasksForBoard` (soft delete/tombstone + sync
 *   DELETE, docs/BOARD_INTEGRITY.md) → per-cell `createBoardTask`.
 *
 * @param input - Resolved board fields, placement, and pending tasks.
 * @returns The resulting board id.
 */
export async function persistWizardBoardRows({
  userId,
  draftBoardId,
  isCore,
  status,
  boardFields,
  placement,
  size,
  centerType,
  pendingTasks,
}: PersistWizardBoardRowsInput): Promise<string> {
  const isOddBoard = size % 2 !== 0;
  const centerRow = Math.floor(size / 2);
  const centerCol = Math.floor(size / 2);

  let boardId = '';
  await db.transaction(
    'rw',
    // `taskEvents` is read-only here — the post-write derivation pass below
    // resolves the just-written placements against the board's window.
    [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue],
    async () => {
      // ── Bug #85: write pending tasks first ──────────────────────────────
      // Only persist pending tasks that are actually placed on the board — a
      // stray pending payload must never be written as an orphan Task row.
      const placedTaskIds = new Set(
        placement.map((t) => t?.id).filter((id): id is string => id != null),
      );
      for (const payload of pendingTasks) {
        if (!placedTaskIds.has(payload.task.id)) continue;

        // P5 guard: a `childLinks` row may reference either one of this
        // payload's own `childTasks` (a brand-new inline child — always
        // carries a `maxCount` if COUNTING, so never goal-less) or an
        // EXISTING task elsewhere in the library. No live caller currently
        // builds the latter (web's compound wizard writes immediately via
        // `createCompound`, already guarded, rather than deferring through
        // this pending-task shape) — but the shape permits it, and iOS's
        // analogous `createTaskWithPairedChildrenAndEnqueue` guards the same
        // case, so this mirrors that defensively for any future deferred
        // web compound-authoring path.
        const newChildIds = new Set(payload.childTasks.map((t) => t.id));
        for (const link of payload.childLinks) {
          if (newChildIds.has(link.childTaskId)) continue;
          const existingChild = await db.tasks.get(link.childTaskId);
          if (existingChild && isGoalLessCounter(existingChild)) {
            throw new Error(
              'persistWizardBoardRows: goal-less counter tasks cannot be compound children',
            );
          }
        }

        await db.tasks.add(payload.task);
        await addToSyncQueue(
          'tasks',
          payload.task.id,
          SyncOperationType.CREATE,
          payload.task,
        );
        for (const childTask of payload.childTasks) {
          await db.tasks.add(childTask);
          await addToSyncQueue(
            'tasks',
            childTask.id,
            SyncOperationType.CREATE,
            childTask,
          );
        }
        for (const link of payload.childLinks) {
          await db.compoundChildren.add(link);
          await addToSyncQueue(
            'compoundChildren',
            link.id,
            SyncOperationType.CREATE,
            link,
          );
        }
      }

      // ── Board + BoardTask rows ──────────────────────────────────────────
      if (draftBoardId !== null) {
        boardId = draftBoardId;
        // Windowed Completion — when a resumed draft is saved active, stamp the
        // activation instant (only if not already set) so the auto-seal
        // backstop keys off max(endDate, activatedAt) (docs §Sealing → backstop).
        const existingDraft = await db.boards.get(boardId);
        await updateBoard(boardId, {
          ...boardFields,
          status: status === 'active' ? BoardStatus.ACTIVE : BoardStatus.DRAFT,
          ...(status === 'active' && !existingDraft?.activatedAt
            ? { activatedAt: currentTimestamp() }
            : {}),
        });
        await deleteBoardTasksForBoard(boardId);
      } else {
        const board = await createBoard(userId, boardFields, { isCore });
        boardId = board.id;
      }

      for (let i = 0; i < placement.length; i++) {
        const task = placement[i];
        if (task === null) continue;
        const row = Math.floor(i / size);
        const col = i % size;
        const isCenterPos = isOddBoard && row === centerRow && col === centerCol;
        await createBoardTask({
          boardId,
          taskId: task.id,
          row,
          col,
          // Mark centre only for CHOSEN (a real task pinned at centre).
          isCenter: isCenterPos && centerType === CenterSquareType.CHOSEN,
        });
      }

      if (draftBoardId === null && status === 'active') {
        await activateBoard(boardId);
      }

      // ── Windowed derivation pass over the just-written placements ───────
      // Stored stats are derivation output, never a hand-init (mirrors the
      // recurring-spawn path — recurringBoardSpawn.ts). Without this, a board
      // placing a task that is ALREADY complete in this board's window (or a
      // FREE/CUSTOM_FREE center) would persist + sync `completedTasks: 0`
      // until the next app-open self-heal. Runs after activation so the final
      // row is derived exactly once, same-transaction as the board write.
      // Status logic is deliberately NOT touched here — a fresh board with a
      // bingo from shared tasks legitimately shows those lines; status
      // transitions stay the live-cascade's job.
      const freshBoard = await db.boards.get(boardId);
      if (freshBoard && !freshBoard.isDeleted) {
        const boardTasksOnBoard = await db.boardTasks
          .where('boardId')
          .equals(boardId)
          .filter((bt) => !bt.isDeleted)
          .toArray();
        const allChildren = (await db.compoundChildren.toArray()).filter((c) => !c.isDeleted);
        const childrenByCompound: Record<string, CompoundChild[]> = {};
        for (const c of allChildren) (childrenByCompound[c.compoundTaskId] ??= []).push(c);
        const allTasks = await db.tasks.toArray();
        const taskById: Record<string, Task> = {};
        for (const t of allTasks) taskById[t.id] = t;
        // `db.taskEvents` is in this transaction's scope, so the shared helper
        // reads inside the txn (reuse-before-creating; same map shape).
        const windowContext = await buildWindowContext();
        const allBoards = await db.boards.toArray();
        const stats = computeBoardStatsUpdate(
          freshBoard,
          boardTasksOnBoard,
          childrenByCompound,
          taskById,
          allBoards,
          windowContext,
        );
        // `updateBoard` bumps version + updatedAt and enqueues an UPDATE; the
        // D3 coalescer folds it into the pending CREATE/UPDATE for this board
        // with the refreshed (derived) payload, so the row that reaches
        // Firestore carries derivation output from the very first push.
        await updateBoard(boardId, {
          completedTasks: stats.completedTasks,
          linesCompleted: stats.linesCompleted,
          completedLineIds: stats.completedLineIds,
        });
      }
    },
  );

  return boardId;
}
