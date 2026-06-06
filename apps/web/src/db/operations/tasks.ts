import { db } from '../database';
import type {
  Board,
  Task,
  TaskStep,
  CreateTaskInput,
  CreateCompoundTaskInput,
  CompoundChild,
  CycleCheckCandidate,
  CycleCheckContext,
} from '@oybc/shared';
import { AchievementTrigger, SyncOperationType, SyncStatus, TaskType, OperatorType, hasCycle, propagateIncrement } from '@oybc/shared';
import { generateUUID, currentTimestamp } from '../utils';
import { addToSyncQueue } from './syncQueue';
import { runBoardCascadeForTask } from './orchestration';

/**
 * Task CRUD Operations
 */

/**
 * Fetch all tasks for a user (excluding deleted)
 */
export async function fetchTasks(userId: string): Promise<Task[]> {
  return db.tasks
    .filter((t) => t.userId === userId && !t.isDeleted)
    .sortBy('title');
}

/**
 * Fetch a single task by ID
 */
export async function fetchTask(id: string): Promise<Task | undefined> {
  return db.tasks.get(id);
}

/**
 * Create a new task.
 *
 * Phase 6.3 — Accepts `referencedBoardId` XOR `referencedTemplateId` for
 * ACHIEVEMENT tasks. Mutual-exclusion + XOR + type-match rules are enforced
 * by `CreateTaskInputSchema` upstream; the helper below also re-checks
 * defensively so a programmer error in a non-schema-validating call site
 * (e.g., a test) surfaces immediately.
 */
export async function createTask(
  userId: string,
  input: CreateTaskInput
): Promise<Task> {
  // Defensive guards mirroring the Zod refines on CreateTaskInputSchema —
  // upstream validation should have caught these, but a programmatic
  // call site (test, agent script) might skip Zod.
  if (input.referencedBoardId && input.referencedTemplateId) {
    throw new Error(
      'Task.referencedBoardId and referencedTemplateId are mutually exclusive',
    );
  }
  if (input.type === TaskType.ACHIEVEMENT) {
    if (!input.referencedBoardId && !input.referencedTemplateId) {
      throw new Error(
        'Achievement tasks must set exactly one of referencedBoardId or referencedTemplateId',
      );
    }
    // Recurring-template mode demands a positive requiredCount.
    // Specific-board mode ignores it.
    if (input.referencedTemplateId) {
      if (input.requiredCount === undefined || input.requiredCount <= 0) {
        throw new Error(
          'Achievement tasks in recurring-template mode require a positive requiredCount',
        );
      }
    } else if (input.requiredCount !== undefined) {
      throw new Error(
        'requiredCount is only meaningful in recurring-template mode',
      );
    }
  } else {
    if (input.referencedBoardId || input.referencedTemplateId) {
      throw new Error(
        'Only ACHIEVEMENT tasks may set referencedBoardId or referencedTemplateId',
      );
    }
    if (input.achievementTrigger !== undefined) {
      throw new Error(
        'Only ACHIEVEMENT tasks may set achievementTrigger',
      );
    }
    if (input.requiredCount !== undefined) {
      throw new Error(
        'Only ACHIEVEMENT tasks may set requiredCount',
      );
    }
  }

  const task: Task = {
    id: generateUUID(),
    userId,
    title: input.title,
    description: input.description,
    type: input.type,
    action: input.action,
    unit: input.unit,
    maxCount: input.maxCount,
    currentCount: input.type === TaskType.COUNTING ? 0 : undefined,
    referencedBoardId: input.referencedBoardId,
    referencedTemplateId: input.referencedTemplateId,
    // Default ACHIEVEMENT tasks to GREENLOG when the caller doesn't
    // specify — matches both the schema's defensive decode behavior
    // and derivation's read-time default.
    achievementTrigger:
      input.type === TaskType.ACHIEVEMENT
        ? input.achievementTrigger ?? AchievementTrigger.GREENLOG
        : undefined,
    requiredCount: input.requiredCount,
    // Phase 6.Y — Timeboxed Tasks. Optional triple. Wizard-initiated
    // creates pass these from the board being built; standalone
    // quick-add creates leave them undefined (indefinite).
    timeframe: input.timeframe,
    startDate: input.startDate,
    endDate: input.endDate,
    // Phase 2 — Shared Counters. Both null for non-linked tasks (default).
    // The Zod refinement on CreateTaskInputSchema ensures co-presence.
    // Use `|| null` (not `?? null`) so empty strings collapse to null — the
    // schema's z.string().uuid() constraint should already reject them, but
    // this is an extra belt-and-suspenders guard at the write layer.
    // `baseline` is written as-is (the refinement guarantees it is present
    // and >= 0 when sharedCounterId is set); we do NOT default it to 0 here
    // so that a misconfigured call site surfaces a type error rather than
    // silently writing an inconsistent row.
    sharedCounterId: input.sharedCounterId || null,
    baseline: input.sharedCounterId ? (input.baseline ?? null) : null,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: currentTimestamp(),
    updatedAt: currentTimestamp(),
    version: 1,
    isDeleted: false,
  };

  // Post-unification: createTask is for primitives only (NORMAL / COUNTING /
  // ACHIEVEMENT). Compound tasks (which include former Progress as
  // `compound + isOrdered=true`) route through createCompound. The legacy
  // 'progress' string check is defensive — old call sites or remote
  // payloads that still emit type='progress' should surface here loudly
  // instead of silently writing an invalid Task row.
  if (input.type === TaskType.COMPOUND || (input.type as string) === 'progress') {
    throw new Error(
      `createTask received type='${input.type}'. Compound (and former progress) tasks must call createCompound (with isOrdered=true for progress).`
    );
  }

  await db.transaction('rw', [db.tasks], async () => {
    await db.tasks.add(task);
  });

  await addToSyncQueue('tasks', task.id, SyncOperationType.CREATE, task);

  return task;
}

/**
 * Create a new compound task (unifies former progress + composite create paths).
 *
 * Writes:
 *   - One `tasks` row with `type='compound'` + operator/threshold/isOrdered.
 *   - For each child entry: either references the provided `childTaskId`, or
 *     auto-creates a new primitive Task (if `autoCreate` is provided).
 *   - One `compoundChildren` row per child link.
 *
 * All writes run in a single Dexie transaction so partial failures don't
 * leave dangling rows. Sync entries are enqueued after the transaction
 * commits (matches the pattern in createTask).
 *
 * Caller is responsible for validating `input` against
 * `CreateCompoundTaskInputSchema` from @oybc/shared before calling.
 *
 * @param userId - The owning user's ID
 * @param input - Validated compound task creation input
 * @returns The newly created compound Task row
 */
export async function createCompound(
  userId: string,
  input: CreateCompoundTaskInput,
): Promise<Task> {
  const now = currentTimestamp();
  const compound: Task = {
    id: generateUUID(),
    userId,
    title: input.title,
    description: input.description,
    type: TaskType.COMPOUND,
    operator: input.operator,
    threshold: input.operator === OperatorType.M_OF_N ? input.threshold : undefined,
    isOrdered: input.isOrdered,
    isCompleted: false, // Field exists for column uniformity; never read on compound rows.
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: now,
    updatedAt: now,
    version: 1,
    isDeleted: false,
    // Phase 6.Y — Timeboxed Tasks. The parent compound + every inline
    // child below inherit this triple. Out-of-band: later edits to
    // the parent compound's timeframe do NOT propagate to children
    // (per the plan's out-of-scope note).
    timeframe: input.timeframe,
    startDate: input.startDate,
    endDate: input.endDate,
  };

  const childRowsToSync: { task?: Task; child: CompoundChild }[] = [];

  await db.transaction('rw', [db.tasks, db.compoundChildren], async () => {
    await db.tasks.add(compound);

    for (let i = 0; i < input.children.length; i++) {
      const entry = input.children[i];

      let childTaskId = entry.childTaskId;
      let inlineCreatedTask: Task | undefined;

      if (!childTaskId && entry.autoCreate) {
        // Inline-create a primitive child Task in the same transaction.
        inlineCreatedTask = {
          id: generateUUID(),
          userId,
          title: entry.autoCreate.title,
          description: entry.autoCreate.description,
          type: entry.autoCreate.type,
          action: entry.autoCreate.action,
          unit: entry.autoCreate.unit,
          maxCount: entry.autoCreate.maxCount,
          currentCount: entry.autoCreate.type === TaskType.COUNTING ? 0 : undefined,
          isCompleted: false,
          totalCompletions: 0,
          totalInstances: 0,
          createdAt: now,
          updatedAt: now,
          version: 1,
          isDeleted: false,
          // Inherit the parent compound's timeframe at creation time.
          timeframe: input.timeframe,
          startDate: input.startDate,
          endDate: input.endDate,
        };
        await db.tasks.add(inlineCreatedTask);
        childTaskId = inlineCreatedTask.id;
      }

      if (!childTaskId) {
        // Should be impossible given Zod validation, but defensive: skip
        // an entry that has neither childTaskId nor autoCreate.
        continue;
      }

      const childRow: CompoundChild = {
        id: generateUUID(),
        compoundTaskId: compound.id,
        childTaskId,
        childIndex: i,
        createdAt: now,
        updatedAt: now,
        version: 1,
        isDeleted: false,
      };
      await db.compoundChildren.add(childRow);
      childRowsToSync.push({ task: inlineCreatedTask, child: childRow });
    }
  });

  // Enqueue sync entries OUTSIDE the transaction (matches createTask pattern).
  await addToSyncQueue('tasks', compound.id, SyncOperationType.CREATE, compound);
  for (const { task: inlineTask, child: childRow } of childRowsToSync) {
    if (inlineTask) {
      await addToSyncQueue('tasks', inlineTask.id, SyncOperationType.CREATE, inlineTask);
    }
    await addToSyncQueue('compoundChildren', childRow.id, SyncOperationType.CREATE, childRow);
  }

  return compound;
}

/**
 * Patch type for task updates that carries null sentinels for clearable
 * fields. Used by `updateTask` and `updateTaskAndCascade`.
 *
 * `null` clears the field; `undefined` leaves it unchanged;
 * a value replaces it.
 */
export type UpdateTaskPatch = Omit<
  Partial<Task>,
  | 'referencedBoardId'
  | 'referencedTemplateId'
  | 'achievementTrigger'
  | 'requiredCount'
  | 'timeframe'
  | 'startDate'
  | 'endDate'
> & {
  referencedBoardId?: string | null;
  referencedTemplateId?: string | null;
  achievementTrigger?: AchievementTrigger | null;
  requiredCount?: number | null;
  timeframe?: string | null;
  startDate?: string | null;
  endDate?: string | null;
};

/**
 * Update a task.
 *
 * Phase 6.3 — Pass the `null` sentinel as the patch value to explicitly
 * clear a reference field (Dexie treats `undefined` in a `Partial` as
 * "don't change", so a separate clear path is needed); `undefined`
 * leaves the existing value untouched.
 *
 * Defensive re-validation of the merged state happens here rather than
 * relying on `UpdateTaskInputSchema` alone — the schema's type-match
 * refines only fire when `type` is in the patch, but callers usually
 * omit it (type is immutable post-creation). To prevent a partial
 * update from sneaking an invalid shape into the local DB, we compute
 * the post-merge {type, refs} and re-check all three Phase 6.3 rules
 * before writing. The atomic update + sync-queue write keeps the local
 * DB consistent under a mid-write crash.
 */
export async function updateTask(
  id: string,
  updates: UpdateTaskPatch,
): Promise<void> {
  const existing = await db.tasks.get(id);
  if (!existing) return;

  // `type` is immutable post-creation (the public `UpdateTaskInput`
  // type doesn't expose it). An internal `Partial<Task>`-typed caller
  // could still pass `updates.type` — reject loudly rather than
  // silently writing the change.
  if (updates.type !== undefined && updates.type !== existing.type) {
    throw new Error(
      `Task.type is immutable after creation (got '${updates.type}', existing '${existing.type}')`,
    );
  }

  // Resolve the post-patch values for the rules below.
  const nextType = existing.type;
  const nextRefBoard =
    updates.referencedBoardId === null
      ? undefined
      : updates.referencedBoardId ?? existing.referencedBoardId;
  const nextRefTpl =
    updates.referencedTemplateId === null
      ? undefined
      : updates.referencedTemplateId ?? existing.referencedTemplateId;
  const nextTrigger =
    updates.achievementTrigger === null
      ? undefined
      : updates.achievementTrigger ?? existing.achievementTrigger;
  const nextRequiredCount =
    updates.requiredCount === null
      ? undefined
      : updates.requiredCount ?? existing.requiredCount;

  // Rule 1: mutual exclusion.
  if (nextRefBoard && nextRefTpl) {
    throw new Error(
      'Task.referencedBoardId and referencedTemplateId are mutually exclusive',
    );
  }
  // Rule 2: ACHIEVEMENT tasks must keep exactly one reference.
  if (nextType === TaskType.ACHIEVEMENT && !nextRefBoard && !nextRefTpl) {
    throw new Error(
      'Achievement tasks must keep exactly one of referencedBoardId or referencedTemplateId',
    );
  }
  // Rule 3: non-ACHIEVEMENT tasks may not have references.
  if (nextType !== TaskType.ACHIEVEMENT && (nextRefBoard || nextRefTpl)) {
    throw new Error(
      'Only ACHIEVEMENT tasks may have referencedBoardId or referencedTemplateId',
    );
  }
  // Rule 4: trigger only on ACHIEVEMENT.
  if (nextType !== TaskType.ACHIEVEMENT && nextTrigger !== undefined) {
    throw new Error(
      'Only ACHIEVEMENT tasks may have achievementTrigger',
    );
  }
  // Rule 5: requiredCount required for template mode, forbidden otherwise.
  if (nextType === TaskType.ACHIEVEMENT && nextRefTpl) {
    if (nextRequiredCount === undefined || nextRequiredCount <= 0) {
      throw new Error(
        'Recurring-template ACHIEVEMENT tasks must keep a positive requiredCount',
      );
    }
  } else if (nextRequiredCount !== undefined) {
    throw new Error(
      'requiredCount is only meaningful for recurring-template ACHIEVEMENT tasks',
    );
  }

  const patch: Partial<Task> = {
    ...(updates as Partial<Task>),
    updatedAt: currentTimestamp(),
    version: (existing.version ?? 0) + 1,
  };
  // Translate `null` sentinel → `undefined` (Dexie stores absence).
  if (updates.referencedBoardId === null) patch.referencedBoardId = undefined;
  if (updates.referencedTemplateId === null) patch.referencedTemplateId = undefined;
  if (updates.achievementTrigger === null) patch.achievementTrigger = undefined;
  if (updates.requiredCount === null) patch.requiredCount = undefined;
  if (updates.timeframe === null) patch.timeframe = undefined;
  if (updates.startDate === null) patch.startDate = undefined;
  if (updates.endDate === null) patch.endDate = undefined;

  await db.transaction('rw', [db.tasks, db.syncQueue], async () => {
    await db.tasks.update(id, patch);
    const updated = await db.tasks.get(id);
    if (!updated) return;
    // Dev-mode short-circuit: skip syncing playground writes (mirrors the
    // pattern in updateAchievementSquareConfig from the pre-refactor
    // Phase 6.3 helper — see CLAUDE.md for the bypass-user convention).
    if (import.meta.env.DEV) {
      const playgroundUser = (updated as unknown as { userId?: string }).userId;
      if (playgroundUser === 'playground-user-1') return;
    }
    await db.syncQueue.add({
      id: generateUUID(),
      entityType: 'tasks',
      entityId: id,
      operationType: SyncOperationType.UPDATE,
      payload: JSON.stringify(updated),
      status: SyncStatus.PENDING,
      retryCount: 0,
      createdAt: currentTimestamp(),
      priority: 0,
    });
  });
}

/**
 * Update a task and run the board derivation cascade for every board that
 * places the task.
 *
 * For UI-initiated edits (TaskEditSheet save path) ONLY. Sync-pull callers
 * keep using `updateTask` directly — the pull path already has its own
 * cascade via `runBoardCascadeForTask` inside the pull transaction.
 *
 * Sequence:
 *   1. Write the patch via `updateTask` (validates rules, bumps version,
 *      enqueues task sync entry).
 *   2. Fetch every BoardTask that places this task.
 *   3. Run `runBoardCascadeForTask` inside a transaction covering all the
 *      required tables. One cascade call covers all affected boards — it
 *      resolves the full affected-board set internally.
 *
 * For Achievement re-target edits, the caller is responsible for running
 * `checkAchievementRetargetCycle` BEFORE calling this wrapper and surfacing
 * any cycle error to the user. This function does NOT repeat the check.
 *
 * @param id - Task id to update.
 * @param updates - Patch to apply (same type as `updateTask`).
 */
export async function updateTaskAndCascade(
  id: string,
  updates: UpdateTaskPatch,
): Promise<void> {
  // 1. Write the task patch (validates business rules + enqueues sync).
  await updateTask(id, updates);

  // 2. Check if any board places this task.
  const placements = await db.boardTasks.where('taskId').equals(id).toArray();
  if (placements.length === 0) return;

  // 3. Run the derivation cascade in a single transaction. One call to
  //    `runBoardCascadeForTask` covers all affected boards for this task —
  //    the function resolves the full affected-board set internally.
  await db.transaction(
    'rw',
    [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.syncQueue],
    async () => {
      await runBoardCascadeForTask(id);
    },
  );
}

/**
 * Phase 3 — Shared Counters increment hot-path.
 *
 * Increments the source task's `currentCount` by `by` (default 1), then
 * re-derives every linked task (tasks where `sharedCounterId === sourceTaskId`
 * and `!isDeleted`) and runs the board derivation cascade for the source AND
 * every linked task — all inside one Dexie transaction.
 *
 * Invariants enforced:
 *   - NO HIGH-END CLAMP on the source's `currentCount`. Overshoot is intentional.
 *   - ONE-WAY LATCH on each linked task's `isCompleted`: once `true`, stays
 *     `true` regardless of the re-derived value.
 *   - All writes (task rows + board cascade + sync entries) are atomic. A
 *     partial failure rolls back everything.
 *
 * Callers must NOT call this for a linked (derived) task — pass the source
 * task's id. A linked task's `sharedCounterId` points at the source; tapping
 * a linked task on a board should call `incrementSharedCounter` with the
 * source id, not the linked id.
 *
 * @param sourceTaskId - The id of the source (template) task whose `currentCount`
 *   is the shared accumulator.
 * @param by - Amount to increment (default 1). Must be a positive integer.
 */
export async function incrementSharedCounter(
  sourceTaskId: string,
  by = 1,
): Promise<void> {
  if (by <= 0) throw new Error('incrementSharedCounter: `by` must be a positive integer');

  await db.transaction(
    'rw',
    [db.tasks, db.boards, db.boardTasks, db.compoundChildren, db.syncQueue],
    async () => {
      const now = currentTimestamp();

      // 1. Fetch and validate the source task.
      const source = await db.tasks.get(sourceTaskId);
      if (!source || source.isDeleted) return;
      if (source.type !== TaskType.COUNTING) {
        throw new Error(
          `incrementSharedCounter: source task ${sourceTaskId} is not a COUNTING task`,
        );
      }
      // Source must NOT be a linked task itself (it must be the accumulator).
      if (source.sharedCounterId != null) {
        throw new Error(
          `incrementSharedCounter: task ${sourceTaskId} is a linked derived counter; pass the source (template) task id instead`,
        );
      }

      // 2. Compute new source count — NO high-end clamp (overshoot is intentional).
      const newSourceCount = (source.currentCount ?? 0) + by;
      const sourceMaxCount = source.maxCount ?? 0;

      // isCompleted: one-way latch. Source uses a simpler logic than derived tasks:
      // the source tracks its own maxCount independently. We apply the latch here too.
      const sourceWasCompleted = source.isCompleted;
      const sourceNowCompleted = sourceWasCompleted || newSourceCount >= sourceMaxCount;

      const updatedSource: Partial<Task> = {
        currentCount: newSourceCount,
        isCompleted: sourceNowCompleted,
        completedAt: !sourceWasCompleted && sourceNowCompleted ? now : source.completedAt,
        updatedAt: now,
        version: (source.version ?? 0) + 1,
      };
      await db.tasks.update(sourceTaskId, updatedSource);
      // Enqueue sync for the source task.
      const savedSource = await db.tasks.get(sourceTaskId);
      if (savedSource) {
        await db.syncQueue.add({
          id: generateUUID(),
          entityType: 'tasks',
          entityId: sourceTaskId,
          operationType: SyncOperationType.UPDATE,
          payload: JSON.stringify(savedSource),
          status: SyncStatus.PENDING,
          retryCount: 0,
          createdAt: now,
          priority: 0,
        });
      }

      // 3. Find all linked (derived) tasks for this source.
      const linkedTasks = await db.tasks
        .filter((t) => !t.isDeleted && t.sharedCounterId === sourceTaskId)
        .toArray();

      // 4. Compute propagation results using the pure shared helper.
      const propagationResults = propagateIncrement(
        { currentCount: newSourceCount },
        linkedTasks.map((t) => ({
          id: t.id,
          baseline: t.baseline,
          maxCount: t.maxCount,
          isCompleted: t.isCompleted,
        })),
      );

      // 5. Write each linked task's new state + enqueue its sync entry.
      for (const result of propagationResults) {
        const linkedTask = linkedTasks.find((t) => t.id === result.taskId);
        if (!linkedTask) continue;

        const wasCompleted = linkedTask.isCompleted;
        const nowCompleted = result.newIsCompleted;

        const linkedPatch: Partial<Task> = {
          currentCount: result.newCurrentCount,
          isCompleted: nowCompleted,
          completedAt: !wasCompleted && nowCompleted ? now : linkedTask.completedAt,
          updatedAt: now,
          version: (linkedTask.version ?? 0) + 1,
        };
        await db.tasks.update(result.taskId, linkedPatch);
        const savedLinked = await db.tasks.get(result.taskId);
        if (savedLinked) {
          await db.syncQueue.add({
            id: generateUUID(),
            entityType: 'tasks',
            entityId: result.taskId,
            operationType: SyncOperationType.UPDATE,
            payload: JSON.stringify(savedLinked),
            status: SyncStatus.PENDING,
            retryCount: 0,
            createdAt: now,
            priority: 0,
          });
        }
      }

      // 6. Run the board derivation cascade for the source AND each linked task.
      // The cascade reads from the already-updated task rows (same transaction),
      // so board stats, bingo lines, and completion flags are all recomputed
      // with the fresh counts in one pass.
      const allChangedTaskIds = [sourceTaskId, ...linkedTasks.map((t) => t.id)];
      for (const taskId of allChangedTaskIds) {
        await runBoardCascadeForTask(taskId);
      }
    },
  );
}

/**
 * For Achievement re-target: build the cycle-check context from current
 * workspace state and run `hasCycle` from @oybc/shared. Returns `null` if
 * no cycle, or an error string the caller can surface in the UI.
 *
 * @param taskId - The Achievement task being re-targeted.
 * @param candidate - The proposed new reference (referencedBoardId XOR referencedTemplateId).
 */
export async function checkAchievementRetargetCycle(
  taskId: string,
  candidate: Pick<CycleCheckCandidate, 'referencedBoardId' | 'referencedTemplateId'>,
): Promise<string | null> {
  const placements = await db.boardTasks.where('taskId').equals(taskId).toArray();
  const parentBoardIds = Array.from(new Set(placements.map((bt) => bt.boardId)));

  const allBoardTasks = await db.boardTasks.toArray();
  const allTasks = await db.tasks.filter((t) => !t.isDeleted).toArray();
  const allBoards = await db.boards.filter((b) => !b.isDeleted).toArray();

  const context: CycleCheckContext = { allBoardTasks, allTasks, allBoards };
  const cycleCandidate: CycleCheckCandidate = {
    parentBoardIds,
    referencedBoardId: candidate.referencedBoardId,
    referencedTemplateId: candidate.referencedTemplateId,
  };

  const result = hasCycle(cycleCandidate, context);
  if (!result.ok) {
    // Map raw board ids in the cycle path to display names so the error
    // is readable in the edit sheet. Fall back to the id when the board
    // can't be resolved (deleted, or a template id that lives on a
    // different collection).
    const nameById = new Map(allBoards.map((b) => [b.id, b.name]));
    const friendly = result.cyclePath
      ?.map((id) => nameById.get(id) ?? id)
      .join(' → ') ?? 'cycle detected';
    return `This reference would create a cycle: ${friendly}`;
  }
  return null;
}

/**
 * Soft delete a task.
 *
 * Increments `version` so LWW conflict resolution treats the deletion as
 * a later-wins operation against any concurrent update on another device.
 * A soft delete without a version bump could be overwritten by a stale
 * edit that happens to have a newer `updatedAt` timestamp.
 */
export async function deleteTask(id: string): Promise<void> {
  const existing = await db.tasks.get(id);
  if (!existing) return;
  await db.tasks.update(id, {
    isDeleted: true,
    deletedAt: currentTimestamp(),
    updatedAt: currentTimestamp(),
    version: (existing.version ?? 0) + 1,
  });
  const task = await db.tasks.get(id);
  if (task) await addToSyncQueue('tasks', id, SyncOperationType.DELETE, task);
}

/**
 * Summary of what `deleteTaskWithCascade` (or a dry-run) would remove.
 * Lets the UI surface affected counts in a confirm dialog before the
 * user commits.
 */
export interface TaskDeletionImpact {
  /** Count of `BoardTask` rows that reference this task as a placement. */
  boardTaskCount: number;
  /** Count of distinct boards the placements span (cells on the same
   *  board count once). */
  affectedBoardIds: string[];
  /** The live (non-deleted) board records the placements live on. Same
   *  set as `affectedBoardIds` — the rows are included so the confirm
   *  dialog can surface board name + status without a second fetch. */
  affectedBoards: Board[];
  /** Count of `CompoundChild` rows where the task is the CHILD. The
   *  parent compound loses this child; sibling children remain. */
  childLinkCount: number;
  /** Count of `CompoundChild` rows where the task IS the parent
   *  compound. Each parent link is severed; the child Tasks remain. */
  parentLinkCount: number;
}

/**
 * Compute the cascade impact for a candidate deletion. Pure read; does
 * not mutate anything. Designed to feed the confirm dialog so the user
 * sees what's about to happen.
 */
export async function computeTaskDeletionImpact(
  id: string,
): Promise<TaskDeletionImpact> {
  const allPlacements = await db.boardTasks.where('taskId').equals(id).toArray();
  // Filter to placements on non-deleted boards. `BoardTask` has no
  // `isDeleted` column (deletes are hard) so an orphan placement on a
  // soft-deleted board persists in the table forever — those rows
  // shouldn't inflate the user-facing impact count. The actual cascade
  // still hard-deletes ALL matching `BoardTask` rows (storage cleanup),
  // but the dialog only reports on cells the user can still see.
  const boardIdsAll = Array.from(new Set(allPlacements.map((bt) => bt.boardId)));
  const liveBoards =
    boardIdsAll.length === 0
      ? []
      : await db.boards
          .where('id')
          .anyOf(boardIdsAll)
          .filter((b) => !b.isDeleted)
          .toArray();
  const liveBoardIdSet = new Set(liveBoards.map((b) => b.id));
  const visiblePlacements = allPlacements.filter((bt) =>
    liveBoardIdSet.has(bt.boardId),
  );
  const childLinks = await db.compoundChildren
    .filter((c: CompoundChild) => !c.isDeleted && c.childTaskId === id)
    .toArray();
  const parentLinks = await db.compoundChildren
    .filter((c: CompoundChild) => !c.isDeleted && c.compoundTaskId === id)
    .toArray();
  return {
    boardTaskCount: visiblePlacements.length,
    affectedBoardIds: Array.from(liveBoardIdSet),
    affectedBoards: liveBoards,
    childLinkCount: childLinks.length,
    parentLinkCount: parentLinks.length,
  };
}

/**
 * Cascade-delete a task. Performs three operations atomically in one
 * Dexie transaction so a partial cascade can't leave the database in a
 * half-deleted state:
 *
 * 1. **BoardTask placements** referencing this task — *hard-deleted*.
 *    `BoardTask` has no `isDeleted` field (`deleteBoardTasksForBoard`
 *    uses the same hard-delete pattern when a draft is re-saved). Each
 *    removal also gets a sync-queue DELETE so other devices drop the
 *    placement on their next pull.
 * 2. **`CompoundChild` rows where the task IS the parent compound** —
 *    soft-deleted (version bump + isDeleted=true + deletedAt). The
 *    child Tasks themselves stay alive — they may still be useful as
 *    standalone library entries.
 * 3. **`CompoundChild` rows where the task IS a child** — soft-
 *    deleted. The parent compound loses this child; sibling links and
 *    the parent Task itself are untouched.
 * 4. **The Task itself** — soft-deleted (version bump + isDeleted=true
 *    + deletedAt), matching `deleteTask`'s LWW semantics.
 *
 * All sync-queue entries are enqueued inside the same transaction so a
 * crash mid-cascade leaves the queue consistent with the local-DB
 * state.
 *
 * **Achievement tasks** that reference a *board* or *template* are NOT
 * affected by this cascade — those refs are board/template IDs, not
 * task IDs. The reverse cascade (deleting a referenced board) is a
 * separate concern handled elsewhere.
 */
export async function deleteTaskWithCascade(id: string): Promise<void> {
  await db.transaction(
    'rw',
    [db.tasks, db.boardTasks, db.compoundChildren, db.syncQueue],
    async () => {
      const existing = await db.tasks.get(id);
      if (!existing) return;

      // 1. Hard-delete BoardTask placements.
      const placements = await db.boardTasks.where('taskId').equals(id).toArray();
      for (const bt of placements) {
        await db.boardTasks.delete(bt.id);
        await addToSyncQueue('boardTasks', bt.id, SyncOperationType.DELETE, bt);
      }

      // 2 + 3. Soft-delete compound-child links — both as-parent and
      //        as-child. Same loop, different filter.
      const linkPredicate = (c: CompoundChild) =>
        !c.isDeleted && (c.compoundTaskId === id || c.childTaskId === id);
      const linksToDelete = await db.compoundChildren.filter(linkPredicate).toArray();
      const now = currentTimestamp();
      for (const link of linksToDelete) {
        const patch: Partial<CompoundChild> = {
          isDeleted: true,
          deletedAt: now,
          updatedAt: now,
          version: (link.version ?? 0) + 1,
        };
        await db.compoundChildren.update(link.id, patch);
        const updated = await db.compoundChildren.get(link.id);
        if (updated) {
          await addToSyncQueue(
            'compoundChildren',
            link.id,
            SyncOperationType.DELETE,
            updated,
          );
        }
      }

      // 4. Soft-delete the Task itself.
      await db.tasks.update(id, {
        isDeleted: true,
        deletedAt: now,
        updatedAt: now,
        version: (existing.version ?? 0) + 1,
      });
      const updatedTask = await db.tasks.get(id);
      if (updatedTask) {
        await addToSyncQueue('tasks', id, SyncOperationType.DELETE, updatedTask);
      }
    },
  );
}

/**
 * Fetch task steps for a task
 */
export async function fetchTaskSteps(taskId: string): Promise<TaskStep[]> {
  return db.taskSteps
    .where('[taskId+stepIndex]')
    .between([taskId, 0], [taskId, Infinity])
    .filter((s) => !s.isDeleted)
    .toArray();
}

/**
 * Add a step to a progress task
 */
export async function addTaskStep(
  taskId: string,
  stepInput: {
    title: string;
    type: 'normal' | 'counting';
    action?: string;
    unit?: string;
    maxCount?: number;
    linkedTaskId?: string;
  }
): Promise<TaskStep> {
  // Get current max step index
  const steps = await fetchTaskSteps(taskId);
  const maxIndex = steps.length > 0 ? Math.max(...steps.map((s) => s.stepIndex)) : -1;

  const step: TaskStep = {
    id: generateUUID(),
    taskId,
    stepIndex: maxIndex + 1,
    title: stepInput.title,
    // `stepInput.type` is the narrower `'normal' | 'counting'` literal
    // union; cast through `TaskType` since TaskStep accepts the full enum.
    type: stepInput.type as TaskType,
    action: stepInput.action,
    unit: stepInput.unit,
    maxCount: stepInput.maxCount,
    linkedTaskId: stepInput.linkedTaskId,
    createdAt: currentTimestamp(),
    updatedAt: currentTimestamp(),
    version: 1,
    isDeleted: false,
  };

  await db.taskSteps.add(step);
  return step;
}

/**
 * Atomically link a TaskStep to a standalone Task (via `linkedTaskId`),
 * bumping version + updatedAt and enqueueing the sync update. Runs in a
 * single transaction so the link and the sync-queue entry are consistent.
 *
 * @param stepId - ID of the TaskStep to update
 * @param linkedTaskId - ID of the standalone Task to link
 */
export async function linkTaskStep(stepId: string, linkedTaskId: string): Promise<void> {
  await db.transaction('rw', [db.taskSteps, db.syncQueue], async () => {
    const existing = await db.taskSteps.get(stepId);
    if (!existing) return;
    const updated = {
      ...existing,
      linkedTaskId,
      version: (existing.version ?? 0) + 1,
      updatedAt: currentTimestamp(),
    };
    await db.taskSteps.put(updated);
    await addToSyncQueue('taskSteps', stepId, SyncOperationType.UPDATE, updated);
  });
}

/**
 * Soft delete a task step.
 *
 * Increments `version` for LWW correctness and enqueues the delete so
 * peers learn about it. Previously neither was done, meaning a
 * concurrent edit on another device would silently resurrect the step.
 */
export async function deleteTaskStep(id: string): Promise<void> {
  const existing = await db.taskSteps.get(id);
  if (!existing) return;
  await db.taskSteps.update(id, {
    isDeleted: true,
    deletedAt: currentTimestamp(),
    updatedAt: currentTimestamp(),
    version: (existing.version ?? 0) + 1,
  });
  const step = await db.taskSteps.get(id);
  if (step) await addToSyncQueue('taskSteps', id, SyncOperationType.DELETE, step);
}

/**
 * Fetch the compound Task(s) that list the given task as a child.
 *
 * Queries `compoundChildren` for non-deleted rows where `childTaskId` matches,
 * then resolves the parent Task for each link (also filtered to non-deleted).
 * De-duplicates in case a task is linked more than once to the same parent
 * (should not occur under normal constraints, but defensive).
 *
 * @param taskId - ID of the child task to look up parents for
 * @returns de-duplicated array of parent compound Tasks
 */
export async function fetchCompoundParentsForTask(taskId: string): Promise<Task[]> {
  const links = await db.compoundChildren
    .filter((c: CompoundChild) => !c.isDeleted && c.childTaskId === taskId)
    .toArray();

  if (links.length === 0) return [];

  const parentIds = Array.from(new Set(links.map((l) => l.compoundTaskId)));
  const parents = await db.tasks
    .where('id')
    .anyOf(parentIds)
    .filter((t) => !t.isDeleted)
    .toArray();

  return parents;
}

/**
 * Find tasks that are linked to a step (for propagation)
 */
export async function findTasksByParentStep(stepId: string): Promise<Task[]> {
  return db.tasks
    .where('parentStepId')
    .equals(stepId)
    .filter((t) => !t.isDeleted)
    .toArray();
}

// ─── Copy-from-source helpers ────────────────────────────────────────────────
//
// The wizard's `From a board…` filter long-press menu exposes
// `⎘ Add a copy of this task…`. The Copy modal collects per-type
// editable fields, pre-filled from the source. These helpers translate
// the (source, overrides) pair into the appropriate `createTask` /
// `createCompound` call so the Copy commit path goes through the same
// validation + sync-queue write as a brand-new task. See
// docs/ARCHITECTURE.md § "Wizard 'From a board' picker" for the
// product-level invariants (shallow compound copy; Achievement copies
// inherit the existing Phase 6.3 cycle-detection gate at wizard-commit
// time — copy itself is unguarded because the new Task has no
// placements yet and `hasCycle` would trivially return ok).

/**
 * Editable fields the Copy modal may override when copying a primitive
 * (NORMAL / COUNTING / ACHIEVEMENT) task. Any field left `undefined`
 * inherits from the source.
 *
 * For Achievement: if EITHER `referencedBoardId` or `referencedTemplateId`
 * is provided, BOTH override values are used as-is (treating the other's
 * `undefined` as "clear"). This is how the modal switches between
 * specific-board and recurring-template modes. If neither is provided,
 * both inherit from the source.
 */
export interface CopyTaskOverrides {
  title?: string;
  description?: string;
  // Counting overrides
  action?: string;
  unit?: string;
  maxCount?: number;
  // Achievement overrides
  achievementTrigger?: AchievementTrigger;
  referencedBoardId?: string;
  referencedTemplateId?: string;
  requiredCount?: number;
}

/**
 * Copy a primitive task (NORMAL / COUNTING / ACHIEVEMENT) under the
 * given user, applying the modal's overrides. Routes through the
 * existing `createTask`, so all schema refinements + sync writes
 * fire identically to a brand-new create.
 *
 * Throws if the source is a compound — call `copyCompound` for those.
 */
export async function copyTask(
  userId: string,
  source: Task,
  overrides: CopyTaskOverrides = {},
): Promise<Task> {
  if (source.type === TaskType.COMPOUND) {
    throw new Error(
      'copyTask cannot copy a compound source — use copyCompound instead',
    );
  }

  const input: CreateTaskInput = {
    title: overrides.title ?? source.title,
    description: overrides.description ?? source.description,
    type: source.type,
    timeframe: source.timeframe,
    startDate: source.startDate,
    endDate: source.endDate,
  };

  if (source.type === TaskType.COUNTING) {
    input.action = overrides.action ?? source.action;
    input.unit = overrides.unit ?? source.unit;
    input.maxCount = overrides.maxCount ?? source.maxCount;
  }

  if (source.type === TaskType.ACHIEVEMENT) {
    input.achievementTrigger =
      overrides.achievementTrigger ?? source.achievementTrigger;

    // If the modal touched either reference field, both come from
    // overrides (undefined-as-clear so a switch from board → template
    // doesn't leave both set and trip the XOR refinement).
    const overrodeRef =
      overrides.referencedBoardId !== undefined ||
      overrides.referencedTemplateId !== undefined;
    input.referencedBoardId = overrodeRef
      ? overrides.referencedBoardId
      : source.referencedBoardId;
    input.referencedTemplateId = overrodeRef
      ? overrides.referencedTemplateId
      : source.referencedTemplateId;

    input.requiredCount = overrides.requiredCount ?? source.requiredCount;
  }

  return createTask(userId, input);
}

/**
 * Copy a compound task. Shallow by default: the new compound parent
 * has a fresh id but its `compoundChildren` rows reference the SAME
 * primitive child Tasks the source had. This matches the unified
 * model where children are first-class Tasks with global completion —
 * deep-cloning would create a second set of independent counters,
 * which the brainstorm explicitly ruled out.
 *
 * Throws if the source is not a compound, or if the source's required
 * operator/isOrdered fields are missing (defensive: the schema enforces
 * them but a programmatic call site could in theory pass a malformed
 * source).
 */
export async function copyCompound(
  userId: string,
  source: Task,
  overrides: { title?: string; description?: string } = {},
): Promise<Task> {
  if (source.type !== TaskType.COMPOUND) {
    throw new Error('copyCompound requires a compound source task');
  }
  if (source.operator === undefined) {
    throw new Error('compound source missing operator field');
  }
  if (source.isOrdered === undefined) {
    throw new Error('compound source missing isOrdered field');
  }

  // Fetch live children, ordered. `compoundChildren` has no boolean
  // `isDeleted` index for the same IndexedDB reasons described in
  // the other Dexie helpers — JS filter is intentional.
  const sourceChildren = await db.compoundChildren
    .filter(
      (c: CompoundChild) => !c.isDeleted && c.compoundTaskId === source.id,
    )
    .toArray();
  sourceChildren.sort((a, b) => a.childIndex - b.childIndex);

  return createCompound(userId, {
    title: overrides.title ?? source.title,
    description: overrides.description ?? source.description,
    operator: source.operator,
    threshold: source.threshold,
    isOrdered: source.isOrdered,
    timeframe: source.timeframe,
    startDate: source.startDate,
    endDate: source.endDate,
    children: sourceChildren.map((c) => ({ childTaskId: c.childTaskId })),
  });
}
