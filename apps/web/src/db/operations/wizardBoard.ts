import {
  BoardStatus,
  CenterSquareType,
  SyncOperationType,
  TaskType,
  applyMemberRules,
  computeBoardStatsUpdate,
  isGoalLessCounter,
  poolSourceSupplyById,
  availableSupplyIds,
  resolveSourceAvailable,
  type BoardSource,
  type BoardSourceSupply,
  type BoardWindow,
  type CompoundChild,
  type CreateBoardInput,
  type Pool,
  type Task,
  type TaskEvent,
  type VaryLevel,
} from '@oybc/shared';
import { db } from '../internal';
import { currentTimestamp } from '../utils';
import { type TaskEditPatch, applyPatchToTask, validatePatch } from '../taskEditPatch';
import { activateBoard, createBoard, updateBoard } from './boards';
import { resolveBoardSourceSupply, resolveSourceBoard, supplyEventTaskIds } from './boardSources';
import { fetchCompoundChildrenByCompoundIds } from './compoundChildren';
import { candidateRootIds, planAndMintDerivedRows } from './derivedCounters';
import { buildWindowContext } from './windowContext';
import { createBoardTask, deleteBoardTasksForBoard } from './boardTasks';
import { runBoardCascadeForTask } from './orchestration';
import { addToSyncQueue } from './syncQueue';
import {
  applyCompoundStructureEditInTransaction,
  compoundLinkProblemForPatch,
} from './compoundStructureEdit';

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
  /**
   * Board Sources §Member rules (B2) — the wizard's pulled sources, forwarded
   * so the per-member rules on them can be resolved against THIS board's
   * window at persist time (`controller.sources`). Omitted/empty = a board
   * assembled entirely by hand, which has no rules to resolve.
   */
  sources?: BoardSource[];
  /**
   * The hand-added layer (`controller.manualTaskIds`). A hand-added id beats
   * any source copy of the same task in the member-rule plan, so the plan
   * needs to know which ids they are.
   */
  manualTaskIds?: string[];
  /**
   * §Member rules (B3, RC3) — dice levels for HAND-ADDED counters, keyed by
   * task id (`controller.manualTaskVary`). Source members carry theirs on
   * `BoardSource.memberRules`; this is the only channel the hand-added layer
   * has. Absent/empty = nothing varies on that layer.
   */
  manualTaskVary?: Record<string, VaryLevel>;
  /**
   * §Member rules — uniform `[0, 1)` source for the vary (dice) rolls. RB6:
   * unseeded `Math.random` in production; injected by tests so a roll can be
   * asserted exactly instead of only bounded by its range.
   */
  rng?: () => number;
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
 *   leaving the pool always purges its staged edit (`toggleTaskSelection`,
 *   or a source action via `purgeDroppedIds`), so every remaining key is
 *   still in `allowedTaskIds` — no extra filtering needed here, matching
 *   the one-off path.
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
 *     (`applyStagedCompoundChildEdits`, via the shared
 *     `applyCompoundStructureEditInTransaction` in `compoundStructureEdit.ts`),
 *     then ONE batched cascade covering
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
      // An ineligible newly linked existing task skips the whole edit
      // (never half-applied), exactly like an invalid patch.
      if ((await compoundLinkProblemForPatch(taskId, patch)) !== null) continue;
      await applyCompoundStructureEditInTransaction(task, patch, {}, now);
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
 * Board Sources §Member rules (B2) — resolve this board's per-member rules
 * and mint what they call for, inside the board-write transaction and BEFORE
 * the `board_tasks` rows that will point at the results.
 *
 * Rebuilds the supplies the same way the spawn path does — pool members via
 * `poolSourceSupplyById`, board members via `resolveSourceBoard` (series
 * binding) + `resolveBoardSourceSupply` (the done-filter) — then
 * exclude-filters and Split-up-expands them through `applyMemberRules`. An
 * unresolvable board source contributes an empty supply rather than failing
 * the save: the placement it fed was already decided upstairs, and a board
 * save must never be blocked by a source that has since been archived.
 *
 * Must run inside the caller's transaction (scoping `boards`, `boardTasks`,
 * `tasks`, `pools`, `compoundChildren`, `taskEvents`, `syncQueue`).
 *
 * @param boardId - The board being written (half of every derived id).
 * @param userId - Owner of the rows minted.
 * @param now - ISO8601 mint instant.
 * @param selectedIds - The placed task ids, in placement order.
 * @param sources - The wizard's pulled sources.
 * @param manualTaskIds - The hand-added layer.
 * @param window - The board's own window.
 * @param taskSnapshot - The caller's single `tasks` snapshot. Read here and
 *   MUTATED with the minted rows (read back from Dexie, since RB3 may skip a
 *   live one) so the caller's derivation pass needs no second full-table read.
 * @param manualTaskVary - Dice levels for the hand-added layer (B3, RC3).
 * @param rng - Vary-roll source; `undefined` = the platform rng (RB6).
 * @returns The ids to place, positionally 1:1 with `selectedIds`.
 */
async function mintWizardDerivedRows(
  boardId: string,
  userId: string,
  now: string,
  selectedIds: string[],
  sources: BoardSource[],
  manualTaskIds: string[],
  window: BoardWindow,
  taskSnapshot: Record<string, Task>,
  manualTaskVary: Record<string, VaryLevel>,
  rng: (() => number) | undefined,
): Promise<string[]> {
  // The planner gets LIVE rows only — a soft-deleted root reachable through a
  // member's `sharedCounterId` must not be mirrored into a new derived row.
  // (The caller's derivation pass keeps the unfiltered snapshot, which is what
  // it has always been given.)
  const tasksById: Record<string, Task> = {};
  for (const t of Object.values(taskSnapshot)) if (!t.isDeleted) tasksById[t.id] = t;

  const poolSourceIds = sources.filter((s) => s.kind === 'pool').map((s) => s.sourceId);
  const poolsById: Record<string, Pool> = {};
  if (poolSourceIds.length > 0) {
    for (const p of await db.pools.where('id').anyOf(poolSourceIds).toArray()) {
      poolsById[p.id] = p;
    }
  }

  const rawSupplies: BoardSourceSupply[] = [];
  const sourceBoardWindow: Record<string, BoardWindow> = {};
  for (const source of sources) {
    if (source.kind === 'pool') {
      rawSupplies.push({
        source,
        supplyTaskIds: poolSourceSupplyById(source.sourceId, poolsById, tasksById),
      });
      continue;
    }
    const board = await resolveSourceBoard(source.sourceId);
    if (board === null) {
      rawSupplies.push({ source, supplyTaskIds: [] });
      continue;
    }
    sourceBoardWindow[source.sourceId] = {
      timeframe: board.timeframe,
      startDate: board.startDate ?? null,
      endDate: board.endDate ?? null,
    };
    const rows = await db.boardTasks.where('boardId').equals(board.id).toArray();
    const liveIds = [...new Set(rows.filter((bt) => !bt.isDeleted).map((bt) => bt.taskId))];
    // Placed ids + the roots of window-stamped derived rows (their done-state
    // reads the root's events).
    const eventTaskIds = [
      ...new Set([
        ...liveIds,
        ...supplyEventTaskIds(liveIds.flatMap((id) => (tasksById[id] ? [tasksById[id]] : []))),
      ]),
    ];
    const eventsByTaskId: Record<string, TaskEvent[]> = {};
    if (eventTaskIds.length > 0) {
      for (const e of await db.taskEvents.where('taskId').anyOf(eventTaskIds).toArray()) {
        if (e.isDeleted) continue;
        (eventsByTaskId[e.taskId] ??= []).push(e);
      }
    }
    const info = resolveBoardSourceSupply(board, rows, tasksById, eventsByTaskId);
    rawSupplies.push({
      source,
      supplyTaskIds: availableSupplyIds(source, info.supplyTaskIds, info.doneTaskIds),
    });
  }

  // Compound children for every compound the plan can name — the placed ones
  // (a One-square compound re-targets its parts) and the supplied ones (a
  // Split-up member expands into its children).
  const compoundIds = new Set<string>();
  const noteCompound = (id: string): void => {
    if (tasksById[id]?.type === TaskType.COMPOUND) compoundIds.add(id);
  };
  for (const id of selectedIds) noteCompound(id);
  for (const supply of rawSupplies) for (const id of supply.supplyTaskIds) noteCompound(id);
  const childrenByCompoundId: Record<string, CompoundChild[]> = {};
  if (compoundIds.size > 0) {
    for (const c of await fetchCompoundChildrenByCompoundIds([...compoundIds])) {
      (childrenByCompoundId[c.compoundTaskId] ??= []).push(c);
    }
  }

  const supplies = applyMemberRules(
    rawSupplies.map((s) => ({ source: s.source, supplyTaskIds: resolveSourceAvailable(s) })),
    childrenByCompoundId,
    tasksById,
  );

  // Auto targets pro-rate by the SOURCE window, looked up per supplied id and
  // per child of a compound member (never by the compound's own id).
  const sourceWindowByTaskId: Record<string, BoardWindow | undefined> = {};
  for (const supply of supplies) {
    const w = sourceBoardWindow[supply.source.sourceId];
    if (w === undefined) continue;
    for (const id of supply.supplyTaskIds) {
      sourceWindowByTaskId[id] = w;
      for (const k of childrenByCompoundId[id] ?? []) sourceWindowByTaskId[k.childTaskId] = w;
    }
  }

  const roots = candidateRootIds(selectedIds, tasksById, childrenByCompoundId);
  const events =
    roots.length > 0 ? await db.taskEvents.where('taskId').anyOf(roots).toArray() : [];

  const { placementIds, minted } = await planAndMintDerivedRows({
    boardId,
    userId,
    now,
    selectedIds,
    supplies,
    manualTaskIds,
    // §Member rules (B3, RC3) — the wizard's hand-added dice, authored in the
    // Sources sheet's hand-added rows (RB9's `{}` placeholder is retired).
    manualTaskVary,
    window,
    // A repeating board never reaches here (its "Create Board" persists a
    // record and spawns through `spawnTemplateBoard`), so this path is always
    // the one-off mode. A board-pulled counting target still pro-rates by
    // window length here — mode no longer gates that — but 'oneOff' makes
    // this path prefill the pro-rated target explicitly rather than leaving
    // it to auto-target at spawn (owner ruling 2026-09-21:
    // docs/BOARD_SOURCES.md §Member rules).
    mode: 'oneOff',
    tasksById,
    childrenByCompoundId,
    sourceWindowByTaskId,
    events,
    rng,
  });

  // Read the minted rows BACK into the caller's snapshot rather than trusting
  // the built ones: RB3 skips an already-live row, so what is stored is the
  // authority for what the board then derives from.
  for (const row of minted.tasks) {
    const stored = await db.tasks.get(row.id);
    if (stored !== undefined) taskSnapshot[row.id] = stored;
  }
  return placementIds;
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
  sources,
  manualTaskIds,
  manualTaskVary,
  rng,
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
    // `pools` is read-only in scope: the member-rule mint below rebuilds each
    // pulled pool's supply the same way the spawn path does.
    [
      db.boards,
      db.boardTasks,
      db.tasks,
      db.pools,
      db.compoundChildren,
      db.taskEvents,
      db.syncQueue,
    ],
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

      // ONE `tasks` snapshot for both the member-rule mint and the derivation
      // pass at the bottom (it used to read the table again). Taken after the
      // pending-task drain + staged edits, which are the only other writers of
      // `tasks` in this transaction; the mint's own writes are read back into
      // it. Unfiltered, exactly as the derivation pass has always had it.
      const taskSnapshot: Record<string, Task> = {};
      for (const t of await db.tasks.toArray()) taskSnapshot[t.id] = t;

      // ── Board Sources §Member rules (B2): mint before placing ───────────
      // The placed ids are resolved against this board's window; a member
      // governed by a rule is replaced IN PLACE by its window-stamped derived
      // counter (or derived compound), so a pinned/centre square keeps its
      // cell. The rows are written here, before the `board_tasks` rows that
      // reference them, inside this transaction.
      //
      // ACTIVE SAVES ONLY. A derived id is `uuidv5(boardId, root)` — it does
      // NOT encode the window — while a DRAFT's window is still editable: save
      // a draft weekly, resume it, switch it to daily, save it active, and the
      // RB3 "live row → skip" rule would keep the first row's timeframe /
      // dates / target / baseline for a window the board no longer has. A
      // draft therefore places its original member ids and the activating save
      // derives the window once, from final values. (It also means an
      // abandoned draft leaves no derived rows behind at all.)
      const selectedIds = placement
        .map((t) => t?.id)
        .filter((id): id is string => id != null);
      const placementIds =
        status === 'active' && selectedIds.length > 0
          ? await mintWizardDerivedRows(
              boardId,
              userId,
              currentTimestamp(),
              selectedIds,
              sources ?? [],
              manualTaskIds ?? [],
              {
                timeframe: boardFields.timeframe,
                startDate: boardFields.startDate ?? null,
                endDate: boardFields.endDate ?? null,
              },
              taskSnapshot,
              manualTaskVary ?? {},
              rng,
            )
          : [];

      // A CHOSEN centre that resolved to a derived counter must have the
      // board's stored `centerTaskId` follow it, or a resumed draft would
      // stop recognising its own centre square.
      const centerIndex = boardFields.centerTaskId
        ? selectedIds.indexOf(boardFields.centerTaskId)
        : -1;
      const centerReplacement = centerIndex >= 0 ? placementIds[centerIndex] : undefined;
      const centerTaskIdOverride =
        centerReplacement !== undefined && centerReplacement !== boardFields.centerTaskId
          ? centerReplacement
          : undefined;

      let placedSoFar = 0;
      // Two members sharing a shared-counter root collapse onto ONE derived
      // counter. Counter-family exclusivity forbids that at selection time, so
      // this is belt-and-braces — but `createBoardTask` THROWS on a duplicate
      // `taskId`, which would abort the whole save, so the repeat cell is left
      // empty instead.
      const placedPlacementIds = new Set<string>();
      for (let i = 0; i < placement.length; i++) {
        const task = placement[i];
        if (task === null) continue;
        const taskId = placementIds[placedSoFar] ?? task.id;
        placedSoFar += 1;
        if (placedPlacementIds.has(taskId)) {
          console.warn(
            `persistWizardBoardRows: task ${taskId} resolved twice on board ${boardId}; leaving cell ${i} empty`,
          );
          continue;
        }
        placedPlacementIds.add(taskId);
        const row = Math.floor(i / size);
        const col = i % size;
        const isCenterPos = isOddBoard && row === centerRow && col === centerCol;
        await createBoardTask({
          boardId,
          taskId,
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
        // Reuses the snapshot taken above the mint (minted rows folded in).
        const taskById: Record<string, Task> = taskSnapshot;
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
          // Folded into the same write rather than issued as its own update —
          // one version bump, one coalesced push.
          ...(centerTaskIdOverride !== undefined
            ? { centerTaskId: centerTaskIdOverride }
            : {}),
        });
      }
    },
  );

  return boardId;
}
