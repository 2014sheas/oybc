import {
  BoardStatus,
  CenterSquareType,
  SyncOperationType,
  TaskType,
  computeBoardStatsUpdate,
  isGoalLessCounter,
  type CompoundChild,
  type CreateBoardInput,
  type Task,
} from '@oybc/shared';
import { db } from '../internal';
import { currentTimestamp, generateUUID } from '../utils';
import {
  type TaskEditPatch,
  applyPatchToTask,
  applyStepToChildTask,
  buildNewChildTask,
  isNewChild,
  validatePatch,
} from '../taskEditPatch';
import { activateBoard, createBoard, updateBoard } from './boards';
import { buildWindowContext } from './windowContext';
import { createBoardTask, deleteBoardTasksForBoard } from './boardTasks';
import { runBoardCascadeForTask, runBoardCascadeForTasks } from './orchestration';
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
  /**
   * Board Creation Split (web PR D) — discriminates a recurring draft from
   * a one-off draft on the shared `status === 'draft'` Board row. Derived
   * straight from `controller.isRecurring` by the caller (`wizardPersist.ts`'s
   * `persistWizardBoard`, which only ever runs with `status === 'active'`
   * for a ONE-OFF wizard — a recurring "Create Board" always goes through
   * `persistRecurringTemplate` instead — so this is safe for both the
   * create and the draft-update branch below).
   */
  isRecurringDraft: boolean;
  /**
   * The recurring wizard's CURRENT pool-mix snapshot (`poolIds` /
   * `manualTaskIds` / `removedTaskIds`, JSON-encoded), written fresh on
   * every save — never merged with a prior snapshot. Omitted entirely
   * (rather than passed as `undefined` explicitly) for a one-off save, so
   * the field is never written for a non-recurring draft.
   */
  recurringDraftMix?: string;
  status: 'active' | 'draft';
  /** Board record fields (name, size, timeframe, dates, center, …). */
  boardFields: CreateBoardInput;
  /** Per-cell placement; `null` slots (reserved centre) are skipped. */
  placement: (Task | null)[];
  size: number;
  centerType: CenterSquareType;
  /** In-memory pending tasks; only those actually placed are written. */
  pendingTasks: WizardPendingTaskWrite[];
  /**
   * Inline Task Editing (web PR-2) — staged inline task edits to apply.
   * Applied ONLY when `status === 'active'` — a draft must never carry a
   * task edit (invariant mirrored from iOS `saveWizardBoard`: "a draft
   * must never carry a task edit"). Defaults to an empty map.
   */
  stagedEdits?: Map<string, TaskEditPatch>;
}

/**
 * Atomically writes a set of Bug-#85 pending (in-memory, not-yet-persisted)
 * tasks — created inside the wizard's inline "New Task" sheet — into
 * `db.tasks` / `db.compoundChildren`, enqueuing sync for each row. Extracted
 * from {@link persistWizardBoardRows}'s inline loop (P4, Task Pools +
 * Recurring Boards Rework) so the recurring-template persist path
 * (`wizardPersist.ts`'s `persistRecurringTemplate`) can reuse the exact
 * same write instead of silently dropping pending tasks — the bug this
 * closes: the recurring path used to read `controller.selectedTaskIds`
 * straight into a `Pool`/template without ever writing the underlying Task
 * rows for any pending (inline-created) task, so `resolveMix`'s
 * resolvable-id filter silently and permanently dropped it from every
 * future spawn.
 *
 * Only pending payloads whose task id is in `allowedTaskIds` are written —
 * a stray pending payload the caller no longer wants placed/pooled must
 * never be written as an orphan Task row. Callers pass the FULL relevant
 * selection as `allowedTaskIds` (a one-off board's placed cells; a
 * repeating board's entire pool-mix selection, since future windows draw
 * from the whole pool, not just today's dealt cells).
 *
 * Opens its own `db.transaction(...)` when called standalone; when called
 * from inside an already-open transaction that already scopes
 * `[db.tasks, db.compoundChildren, db.syncQueue]` (as
 * {@link persistWizardBoardRows} does), Dexie nests it into that
 * transaction instead of opening a new one — so the pending-task write
 * still commits/rolls back atomically with the board write on that path.
 *
 * @param pendingTasks - In-memory payloads to write (task + any inline
 *   compound children + their link rows).
 * @param allowedTaskIds - Only payloads whose `task.id` is in this set are
 *   written; others are silently skipped.
 */
export async function persistWizardPendingTasks(
  pendingTasks: WizardPendingTaskWrite[],
  allowedTaskIds: ReadonlySet<string>,
): Promise<void> {
  await db.transaction('rw', [db.tasks, db.compoundChildren, db.syncQueue], async () => {
    for (const payload of pendingTasks) {
      if (!allowedTaskIds.has(payload.task.id)) continue;

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
            'persistWizardPendingTasks: goal-less counter tasks cannot be compound children',
          );
        }
      }

      await db.tasks.add(payload.task);
      await addToSyncQueue('tasks', payload.task.id, SyncOperationType.CREATE, payload.task);
      for (const childTask of payload.childTasks) {
        await db.tasks.add(childTask);
        await addToSyncQueue('tasks', childTask.id, SyncOperationType.CREATE, childTask);
      }
      for (const link of payload.childLinks) {
        await db.compoundChildren.add(link);
        await addToSyncQueue('compoundChildren', link.id, SyncOperationType.CREATE, link);
      }
    }
  });
}

/**
 * Standalone-transaction variant of the pending-task drain (Bug #85) PLUS
 * the Inline Task Editing (web PR-2) staged-edits apply, both in ONE
 * transaction — the recurring-template persist path's call site
 * (`wizardPersist.ts`'s `persistRecurringTemplate`). A repeating board has
 * no single Board row to share a transaction with (the spawn path resolves
 * the mix fresh from Dexie), so this drains pending tasks + applies staged
 * edits in its own transaction ahead of everything else that reads tasks
 * for mix resolution or persisted `seedTaskIds`. Web port of iOS
 * `AppDatabase.writeWizardPendingTasksAndEnqueue`.
 *
 * Unlike the one-off path (`persistWizardBoardRows`, gated on
 * `status === 'active'`), a `RecurringBoardTemplate` has no draft/active
 * distinction — the cancel dialog's "Save Draft" and the Preview step's
 * "Create" both persist a live template — so staged edits always apply
 * here; there's no gate to mirror.
 *
 * `wizardPersist.ts` cannot open a `db.transaction(...)` itself (the raw
 * Dexie instance is internal to the data layer — B3, issue #284), so this
 * wrapper is what lets that caller get one atomic write covering both
 * steps instead of two separate transactions (which would let a crash
 * between them leave pending tasks written but their staged edits lost).
 *
 * @param pendingTasks - The FULL set of pending payloads whose task is in
 *   the wizard's final `selectedTaskIds` (not a placement-based subset — a
 *   repeating board's future windows draw from the whole pool).
 * @param allowedTaskIds - Only pending payloads whose id is in this set are
 *   written (mirrors `persistWizardPendingTasks`).
 * @param stagedEdits - The wizard's full `stagedEdits` snapshot. A task
 *   leaving the pool always purges its staged edit (`toggleTaskSelection`/
 *   `untogglePool`), so every remaining key is still in `allowedTaskIds` —
 *   no extra filtering needed here, matching the one-off path.
 * @param now - ISO8601 timestamp for the sync-queue rows / version bumps.
 */
export async function persistWizardPendingTasksAndStagedEdits(
  pendingTasks: WizardPendingTaskWrite[],
  allowedTaskIds: ReadonlySet<string>,
  stagedEdits: Map<string, TaskEditPatch>,
  now: string,
): Promise<void> {
  // `skipIfPendingIds` for the staged-edits apply is the set of PENDING
  // task ids specifically (not `allowedTaskIds`, which also contains
  // ordinary library task ids that are merely selected) — a library task's
  // id must never be skipped just because it happens to share the
  // selection with a pending one.
  const pendingIds = new Set(pendingTasks.map((p) => p.task.id));
  await db.transaction(
    'rw',
    [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue],
    async () => {
      await persistWizardPendingTasks(pendingTasks, allowedTaskIds);
      await applyStagedTaskEditsForWizardPersist(stagedEdits, pendingIds, now);
    },
  );
}

/**
 * Applies a staged compound patch's child edits to its `compound_children`
 * links + child Task rows. Called by {@link applyStagedTaskEditsForWizardPersist}
 * for a staged compound edit (library or already-written pending compound).
 * The parent Task itself is saved by the caller AFTER this returns. Web
 * port of iOS `AppDatabase.applyStagedCompoundChildEdits`.
 *
 * Semantics: a kept new sub-task mints a child Task + link; a kept existing
 * sub-task edits its child Task GLOBALLY (reindexing its link to display
 * order); a removed sub-task (deleted or blank-titled) soft-deletes the
 * LINK only — the child Task survives (orphans acceptable). Sub-tasks
 * persist in `patch.children` order.
 *
 * Must run inside an active Dexie transaction covering `tasks` and
 * `compoundChildren` (plus `syncQueue` for the enqueues below).
 *
 * @returns The ids of existing child Tasks whose fields actually changed —
 *   the caller batches these into ONE cascade pass alongside the parent id
 *   (mirrors `orchestration.ts`'s "recompute each affected task's caches
 *   once" guidance) rather than cascading per-child inline.
 */
async function applyStagedCompoundChildEdits(
  parentId: string,
  parentUserId: string,
  patch: TaskEditPatch,
  now: string,
): Promise<string[]> {
  const existingLinks = (
    await db.compoundChildren.where('compoundTaskId').equals(parentId).toArray()
  ).filter((c) => !c.isDeleted);
  const linkByChildId = new Map(existingLinks.map((l) => [l.childTaskId, l]));

  const keptChildIds = new Set<string>();
  const touchedChildIds: string[] = [];
  let displayIndex = 0;

  for (const step of patch.children) {
    const title = step.title.trim();
    // Removed = explicitly deleted OR blank-titled ("dropped on save").
    if (step.markedDeleted || title.length === 0) continue;
    const index = displayIndex++;

    if (isNewChild(step)) {
      const childId = generateUUID();
      const child = buildNewChildTask(childId, step, title, parentUserId, now);
      await db.tasks.add(child);
      await addToSyncQueue('tasks', childId, SyncOperationType.CREATE, child);
      const link: CompoundChild = {
        id: generateUUID(),
        compoundTaskId: parentId,
        childTaskId: childId,
        childIndex: index,
        createdAt: now,
        updatedAt: now,
        version: 1,
        isDeleted: false,
      };
      await db.compoundChildren.add(link);
      await addToSyncQueue('compoundChildren', link.id, SyncOperationType.CREATE, link);
      keptChildIds.add(childId);
    } else if (step.childTaskId) {
      const childId = step.childTaskId;
      keptChildIds.add(childId);
      // Global child edit (rename / goal / unit).
      const existingChild = await db.tasks.get(childId);
      if (existingChild) {
        const updated = applyStepToChildTask(existingChild, step, title);
        const changed =
          updated.title !== existingChild.title ||
          updated.action !== existingChild.action ||
          updated.unit !== existingChild.unit ||
          updated.maxCount !== existingChild.maxCount;
        if (changed) {
          const saved: Task = { ...updated, version: (existingChild.version ?? 1) + 1, updatedAt: now };
          await db.tasks.update(childId, saved);
          await addToSyncQueue('tasks', childId, SyncOperationType.UPDATE, saved);
          touchedChildIds.push(childId);
        }
      }
      // Reindex the link to display order if it moved.
      const link = linkByChildId.get(childId);
      if (link && link.childIndex !== index) {
        const updatedLink: CompoundChild = { ...link, childIndex: index, version: link.version + 1, updatedAt: now };
        await db.compoundChildren.update(link.id, updatedLink);
        await addToSyncQueue('compoundChildren', link.id, SyncOperationType.UPDATE, updatedLink);
      }
    }
  }

  // Soft-delete links whose child is no longer kept (link only — the child
  // Task stays in the library; orphans are acceptable per product decision).
  for (const link of existingLinks) {
    if (keptChildIds.has(link.childTaskId)) continue;
    const updatedLink: CompoundChild = { ...link, isDeleted: true, deletedAt: now, version: link.version + 1, updatedAt: now };
    await db.compoundChildren.update(link.id, updatedLink);
    await addToSyncQueue('compoundChildren', link.id, SyncOperationType.UPDATE, updatedLink);
  }

  return touchedChildIds;
}

/**
 * Applies every staged inline task edit (Inline Task Editing, web PR-2) in
 * the SAME transaction as the wizard's pending-task drain — mirroring iOS
 * `AppDatabase.saveWizardBoard`'s staged-edits block / `writeWizardPendingTasksAndEnqueue`.
 * Edits are GLOBAL (same Task on every board), so each mutation runs the
 * board derivation cascade in this same transaction — a bare write with no
 * cascade would leave other boards / the parent compound stale until the
 * next app-open self-heal.
 *
 * Per-type handling:
 *   - **compound** (library OR pending) — the compound branch owns the full
 *     apply: parent fields (`applyPatchToTask`) + child/link CRUD
 *     (`applyStagedCompoundChildEdits`), then ONE batched cascade covering
 *     the parent + every child Task whose fields actually changed. Applies
 *     regardless of `skipIfPendingIds` — a pending compound's rows already
 *     exist by the time this runs (the pending-task drain loop runs
 *     first), so this is its one and only apply.
 *   - **normal/counting** — a PENDING one was already merged into its
 *     `PendingTaskPayload` in-memory by the caller (mirrors iOS's
 *     `pendingForSave` map), so it's skipped here via `skipIfPendingIds`;
 *     a LIBRARY one is applied + cascaded.
 *
 * Defensive: an invalid patch (should never happen — the editor blocks
 * Save on validation failure) is silently skipped rather than corrupting
 * the row, and a patch whose target Task no longer exists is skipped too.
 *
 * Must run inside an active Dexie transaction covering `boards`,
 * `boardTasks`, `tasks`, `compoundChildren`, `taskEvents`, and `syncQueue`
 * (the contract `runBoardCascadeForTask(s)` requires).
 *
 * @param stagedEdits - The wizard's staged edits (`useBoardWizard.stagedEdits`).
 * @param skipIfPendingIds - Ids of pending (this-session, not-yet-existing-
 *   until-the-drain-above) NON-COMPOUND tasks whose edit was already merged
 *   into their `PendingTaskPayload` — skipped here to avoid double-apply.
 * @param now - ISO8601 timestamp for version bumps + sync-queue rows.
 */
export async function applyStagedTaskEditsForWizardPersist(
  stagedEdits: Map<string, TaskEditPatch>,
  skipIfPendingIds: ReadonlySet<string>,
  now: string,
): Promise<void> {
  if (stagedEdits.size === 0) return;

  for (const [taskId, patch] of stagedEdits) {
    const task = await db.tasks.get(taskId);
    if (!task) continue;
    if (validatePatch(patch, task.type) !== null) continue;

    if (task.type === TaskType.COMPOUND) {
      const updated = applyPatchToTask(patch, task);
      const touchedChildIds = await applyStagedCompoundChildEdits(taskId, task.userId, patch, now);
      const saved: Task = { ...updated, version: (task.version ?? 1) + 1, updatedAt: now };
      await db.tasks.update(taskId, saved);
      await addToSyncQueue('tasks', taskId, SyncOperationType.UPDATE, saved);
      await runBoardCascadeForTasks([taskId, ...touchedChildIds]);
    } else {
      if (skipIfPendingIds.has(taskId)) continue;
      const updated = applyPatchToTask(patch, task);
      const saved: Task = { ...updated, version: (task.version ?? 1) + 1, updatedAt: now };
      await db.tasks.update(taskId, saved);
      await addToSyncQueue('tasks', taskId, SyncOperationType.UPDATE, saved);
      await runBoardCascadeForTask(taskId);
    }
  }
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
  isRecurringDraft,
  recurringDraftMix,
  status,
  boardFields,
  placement,
  size,
  centerType,
  pendingTasks,
  stagedEdits,
}: PersistWizardBoardRowsInput): Promise<string> {
  const isOddBoard = size % 2 !== 0;
  const centerRow = Math.floor(size / 2);
  const centerCol = Math.floor(size / 2);

  let boardId = '';
  await db.transaction(
    'rw',
    // `taskEvents` is in scope for two reasons: the post-write derivation
    // pass below resolves the just-written placements against the board's
    // window, and a staged-edit cascade (below) may re-derive OTHER boards
    // that share an edited task.
    [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue],
    async () => {
      // ── Bug #85: write pending tasks first ──────────────────────────────
      // Only persist pending tasks that are actually placed on the board — a
      // stray pending payload must never be written as an orphan Task row.
      // Nests into THIS transaction (it already scopes db.tasks/
      // db.compoundChildren/db.syncQueue) rather than opening a separate one.
      const placedTaskIds = new Set(
        placement.map((t) => t?.id).filter((id): id is string => id != null),
      );
      await persistWizardPendingTasks(pendingTasks, placedTaskIds);

      // ── Staged inline edits (Inline Task Editing, web PR-2) ─────────────
      // ONLY on an active board create — a draft must never carry a task
      // edit (mirrors iOS `saveWizardBoard`'s exact gate). Runs BEFORE the
      // derivation pass below so a changed counting goal (or a compound's
      // sub-task edits) feed into the freshly-computed stored stats.
      if (status === 'active' && stagedEdits && stagedEdits.size > 0) {
        const pendingTaskIds = new Set(pendingTasks.map((p) => p.task.id));
        await applyStagedTaskEditsForWizardPersist(stagedEdits, pendingTaskIds, currentTimestamp());
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
          isRecurringDraft,
          ...(recurringDraftMix !== undefined ? { recurringDraftMix } : {}),
          ...(status === 'active' && !existingDraft?.activatedAt
            ? { activatedAt: currentTimestamp() }
            : {}),
        });
        await deleteBoardTasksForBoard(boardId);
      } else {
        const board = await createBoard(userId, boardFields, {
          isCore,
          isRecurringDraft,
          recurringDraftMix,
        });
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
      // FREE center) would persist + sync `completedTasks: 0`
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
