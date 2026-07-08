import {
  BoardStatus,
  CenterSquareType,
  SyncOperationType,
  type CompoundChild,
  type CreateBoardInput,
  type Task,
} from '@oybc/shared';
import { db } from '../internal';
import { activateBoard, createBoard, updateBoard } from './boards';
import { createBoardTask, deleteBoardTasksForBoard } from './boardTasks';
import { addToSyncQueue } from './syncQueue';

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
 *   status → `deleteBoardTasksForBoard` (hard delete + sync DELETE) →
 *   per-cell `createBoardTask`.
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
    [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.syncQueue],
    async () => {
      // ── Bug #85: write pending tasks first ──────────────────────────────
      // Only persist pending tasks that are actually placed on the board — a
      // stray pending payload must never be written as an orphan Task row.
      const placedTaskIds = new Set(
        placement.map((t) => t?.id).filter((id): id is string => id != null),
      );
      for (const payload of pendingTasks) {
        if (!placedTaskIds.has(payload.task.id)) continue;
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
        await updateBoard(boardId, {
          ...boardFields,
          status: status === 'active' ? BoardStatus.ACTIVE : BoardStatus.DRAFT,
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
    },
  );

  return boardId;
}
