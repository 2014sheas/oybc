import { db } from '../internal';
import type {
  Task,
  CreateTaskInput,
  CreateCompoundTaskInput,
  CompoundChild,
  CycleCheckCandidate,
  CycleCheckContext,
} from '@oybc/shared';
import { AchievementTrigger, SyncOperationType, TaskType, OperatorType, hasCycle, isEventOwningTask, isGoalLessCounter } from '@oybc/shared';
import { generateUUID, currentTimestamp } from '../utils';
import { addToSyncQueue } from './syncQueue';
import { runBoardCascadeForTask } from './orchestration';
import { appendCompletionEvent, tombstoneLatestCompletion } from './taskEvents';

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
 * Fetch every non-deleted task for a user, unsorted.
 *
 * Distinct from `fetchTasks`, which sorts by title. Library surfaces that
 * partition the result by type in memory (and don't rely on title order)
 * use this so the DB read stays a plain scan.
 *
 * @param userId - Owning user.
 * @returns The user's non-deleted Task rows (unsorted).
 */
export async function fetchTasksForUser(userId: string): Promise<Task[]> {
  return db.tasks.filter((t) => t.userId === userId && !t.isDeleted).toArray();
}

/**
 * Fetch non-deleted tasks by an explicit set of ids.
 *
 * @param ids - Task ids to fetch.
 * @returns The matching non-deleted Task rows.
 */
export async function fetchTasksByIds(ids: string[]): Promise<Task[]> {
  return db.tasks.where('id').anyOf(ids).filter((t) => !t.isDeleted).toArray();
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
  // ACHIEVEMENT). Compound tasks (which include former Progress) route
  // through createCompound. The legacy 'progress' string check is
  // defensive — old call sites or remote payloads that still emit
  // type='progress' should surface here loudly instead of silently
  // writing an invalid Task row.
  if (input.type === TaskType.COMPOUND || (input.type as string) === 'progress') {
    throw new Error(
      `createTask received type='${input.type}'. Compound (and former progress) tasks must call createCompound.`
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
 *   - One `tasks` row with `type='compound'` + operator/threshold.
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
          // R1 counters refresh — auto-link (docs/SHARED_COUNTERS.md). When the
          // caller resolved an exact (action, unit) match and the user hasn't
          // opted out via the "Don't link" hint, the child is born already
          // linked to that counter with a "start fresh" baseline.
          sharedCounterId: entry.autoCreate.sharedCounterId ?? undefined,
          baseline: entry.autoCreate.baseline ?? undefined,
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

      if (!inlineCreatedTask) {
        // P5 guard: this entry references an EXISTING task (not an inline
        // autoCreate) — reject a goal-less counter (`isGoalLessCounter`):
        // a hub-born counter with no `maxCount` has nothing evaluable to
        // contribute to a compound's AND/OR/M_OF_N logic
        // (docs/SHARED_COUNTERS.md §P5). Inline-autoCreate children always
        // carry a `maxCount` (COUNTING autoCreate requires a goal), so they
        // can't be goal-less and need no check.
        const existingChild = await db.tasks.get(childTaskId);
        if (existingChild && isGoalLessCounter(existingChild)) {
          throw new Error(
            'createCompound: goal-less counter tasks cannot be compound children',
          );
        }
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
    await addToSyncQueue('tasks', id, SyncOperationType.UPDATE, updated, 0);
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
  const placements = await db.boardTasks.where('taskId').equals(id).filter((bt) => !bt.isDeleted).toArray();
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
 * Toggle a Task's `isCompleted` flag and run the board derivation cascade,
 * writing the Task update + sync-queue enqueue + cascade in a SINGLE Dexie
 * transaction.
 *
 * Relocated verbatim (issue #270, B2-W2) from the inline `db.transaction`
 * fallback that used to live in `BoardPlaySurface.handleCompoundChildToggle`
 * — reached when a compound child Task isn't placed as a `BoardTask` on any
 * board, so there's no `boardTaskId` to route through `handleTaskCompletion`.
 * The parent compound (on the board whose detail sheet is open) still
 * derives through this child, so the board cascade must still run to
 * recompute bingo state and denormalised board stats even though the child
 * itself has no square to update.
 *
 * DELIBERATELY DIFFERENT from `updateTaskAndCascade` above — this is not a
 * redundant duplicate of it:
 *   - `updateTaskAndCascade` is a general task-field-patch op split across
 *     TWO transactions (`updateTask`'s write, then a separate cascade
 *     transaction) and only touches `completedAt` when the caller's patch
 *     explicitly sets it.
 *   - This op is completion-toggle-only: it always derives `completedAt` as
 *     a latch — set to `now` when completing, cleared to `undefined` when
 *     un-completing — and does the Task write + sync enqueue + cascade in
 *     ONE transaction, so a crash between the Task write and the cascade
 *     can't leave the Task flipped with stale board stats forever (the
 *     failure mode the original inline fallback was written to close off).
 *   - It also skips `updateTask`'s ACHIEVEMENT-reference validation rules,
 *     which don't apply to a plain completion toggle.
 * A future unification of the two is possible but out of scope here — this
 * is a code-motion refactor (issue #270), not a behavior change.
 *
 * No-op (no writes at all) if the Task doesn't exist.
 *
 * @param taskId - The Task whose `isCompleted` flag should be toggled.
 */
export async function toggleTaskCompletionAndCascade(taskId: string): Promise<void> {
  const task = await db.tasks.get(taskId);
  if (!task) return;

  const now = currentTimestamp();
  await db.transaction(
    'rw',
    [db.tasks, db.taskEvents, db.boards, db.boardTasks, db.compoundChildren, db.syncQueue],
    async () => {
      // Windowed Completion (docs §Write paths). This is the library-context
      // completion toggle for an unplaced compound child (no board window):
      // toggling off the lifetime state tombstones the latest completion
      // event; toggling on appends a fresh one. Both restamp the lifetime
      // caches + enqueue the Task sync entry inside this transaction. A
      // non-event-owning task (defensive — an unplaced child should be a plain
      // normal task) falls back to the legacy direct toggle.
      if (isEventOwningTask(task)) {
        if (task.isCompleted) {
          await tombstoneLatestCompletion(taskId, now);
        } else {
          await appendCompletionEvent(taskId, undefined, now);
        }
      } else {
        await db.tasks.update(taskId, {
          isCompleted: !task.isCompleted,
          completedAt: !task.isCompleted ? now : undefined,
          updatedAt: now,
          version: task.version + 1,
        });
        const updated = await db.tasks.get(taskId);
        if (updated) {
          await addToSyncQueue('tasks', taskId, SyncOperationType.UPDATE, updated);
        }
      }
      await runBoardCascadeForTask(taskId);
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
  const placements = await db.boardTasks.where('taskId').equals(taskId).filter((bt) => !bt.isDeleted).toArray();
  const parentBoardIds = Array.from(new Set(placements.map((bt) => bt.boardId)));

  const allBoardTasks = await db.boardTasks.filter((bt) => !bt.isDeleted).toArray();
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
