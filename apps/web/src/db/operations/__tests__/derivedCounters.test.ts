import { afterEach, describe, expect, it } from 'vitest';
import {
  OperatorType,
  SyncOperationType,
  TaskType,
  Timeframe,
  applyMemberRules,
  derivedCompoundId,
  derivedLinkId,
  derivedTaskId,
  type BoardSource,
  type BoardWindow,
  type CompoundChild,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import { db } from '../../internal';
import {
  planAndMintDerivedRows,
  refreshDerivedBaselines,
  type PlanAndMintDerivedRowsArgs,
} from '../derivedCounters';

/**
 * Board Sources §Member rules B2 (web) — the mint + baseline-refresh writes.
 *
 * Covers the four rulings the pure algorithms can't: RB2 (the window
 * boundary), RB3 (idempotent mint / tombstone revive), the non-authored
 * baseline refresh, and RB10 (the derived-compound seam, which no UI can
 * author a rule for yet).
 */

const USER = 'user-1';
const BOARD = 'b0000000-0000-4000-8000-000000000001';
/** Local-ISO, exactly like a real `Board.startDate` (no trailing Z). */
const WINDOW_START = '2026-09-14T00:00:00.000';
const BEFORE_A = '2026-09-01T09:00:00.000Z';
const BEFORE_B = '2026-09-10T09:00:00.000Z';
const AFTER = '2026-09-15T09:00:00.000Z';
const NOW = '2026-09-14T08:00:00.000';

const WINDOW: BoardWindow = {
  timeframe: Timeframe.WEEKLY,
  startDate: WINDOW_START,
  endDate: '2026-09-20T23:59:59.999',
};

const ROOT = 'a0000000-0000-4000-8000-000000000001';

afterEach(async () => {
  await db.tasks.clear();
  await db.taskEvents.clear();
  await db.compoundChildren.clear();
  await db.boards.clear();
  await db.boardTasks.clear();
  await db.syncQueue.clear();
});

function countingTask(id: string, over: Partial<Task> = {}): Task {
  return {
    id,
    userId: USER,
    title: 'Run 35 km',
    type: TaskType.COUNTING,
    action: 'Run',
    unit: 'km',
    maxCount: 35,
    currentCount: 0,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: BEFORE_A,
    updatedAt: BEFORE_A,
    version: 1,
    isDeleted: false,
    ...over,
  } as Task;
}

function incrementEvent(id: string, taskId: string, delta: number, occurredAt: string): TaskEvent {
  return {
    id,
    userId: USER,
    taskId,
    kind: 'increment',
    delta,
    occurredAt,
    createdAt: occurredAt,
    updatedAt: occurredAt,
    version: 1,
    isDeleted: false,
  };
}

/**
 * A member rule whose target (20) differs from the root's goal (35), so the
 * mint is NOT collapsed by the no-identical-clone rule (owner ruling
 * 2026-09-22). `mintArgs`'s source window is weekly and so is `WINDOW`, so the
 * auto target would otherwise pro-rate to exactly 35 — an identical clone,
 * which `planDerivedTasks` now places as the root instead of minting. These
 * tests exercise the mint MACHINERY (baseline, idempotence, tombstone revive),
 * so they need a member that genuinely derives.
 */
const retargeted = (): Partial<BoardSource> => ({ memberRules: { [ROOT]: { target: 20 } } });

const boardSource = (over: Partial<BoardSource> = {}): BoardSource => ({
  sourceId: 'src-board',
  kind: 'board',
  min: 0,
  max: null,
  excludedTaskIds: [],
  filter: 'all',
  ...over,
});

/**
 * Build the mint args the way the production callers do: exclude-filtered,
 * Split-up-expanded supplies through `applyMemberRules`, and a
 * `sourceWindowByTaskId` keyed by every supplied id plus every child of a
 * compound member.
 */
function mintArgs(
  supplyTaskIds: string[],
  source: BoardSource,
  tasks: Task[],
  children: CompoundChild[],
  events: TaskEvent[],
  over: Partial<PlanAndMintDerivedRowsArgs> = {},
): PlanAndMintDerivedRowsArgs {
  const tasksById: Record<string, Task> = {};
  for (const t of tasks) tasksById[t.id] = t;
  const childrenByCompoundId: Record<string, CompoundChild[]> = {};
  for (const c of children) (childrenByCompoundId[c.compoundTaskId] ??= []).push(c);
  const supplies = applyMemberRules([{ source, supplyTaskIds }], childrenByCompoundId, tasksById);
  const sourceWindow: BoardWindow = {
    timeframe: Timeframe.WEEKLY,
    startDate: '2026-09-07T00:00:00.000',
    endDate: '2026-09-13T23:59:59.999',
  };
  const sourceWindowByTaskId: Record<string, BoardWindow | undefined> = {};
  for (const id of supplies[0].supplyTaskIds) {
    sourceWindowByTaskId[id] = sourceWindow;
    for (const k of childrenByCompoundId[id] ?? []) sourceWindowByTaskId[k.childTaskId] = sourceWindow;
  }
  return {
    boardId: BOARD,
    userId: USER,
    now: NOW,
    selectedIds: supplies[0].supplyTaskIds,
    supplies,
    manualTaskIds: [],
    manualTaskVary: {},
    window: WINDOW,
    mode: 'oneOff',
    tasksById,
    childrenByCompoundId,
    sourceWindowByTaskId,
    events,
    rng: () => 0,
    ...over,
  };
}

async function mint(args: PlanAndMintDerivedRowsArgs): Promise<string[]> {
  return db.transaction(
    'rw',
    [db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue],
    async () => (await planAndMintDerivedRows(args)).placementIds,
  );
}

describe('planAndMintDerivedRows — mint (RB2/RB3)', () => {
  it('writes one derived counter whose baseline is the pre-window event sum, and enqueues one CREATE', async () => {
    const root = countingTask(ROOT, { currentCount: 30 });
    await db.tasks.add(root);
    const events = [
      incrementEvent('ev-1', ROOT, 10, BEFORE_A),
      incrementEvent('ev-2', ROOT, 12, BEFORE_B),
      incrementEvent('ev-3', ROOT, 8, AFTER),
    ];
    await db.taskEvents.bulkAdd(events);

    const placementIds = await mint(
      mintArgs([ROOT], boardSource(retargeted()), [root], [], events),
    );

    const derivedId = derivedTaskId(BOARD, ROOT);
    expect(placementIds).toEqual([derivedId]);

    const derived = await db.tasks.get(derivedId);
    // 10 + 12 pre-window; the +8 landed AFTER the window opened and is this
    // window's progress, not baseline.
    expect(derived?.baseline).toBe(22);
    expect(derived?.currentCount).toBe(30); // mirrors the root's lifetime count
    expect(derived?.maxCount).toBe(20); // the member rule's explicit target
    expect(derived?.sharedCounterId).toBe(ROOT);
    expect(derived?.startDate).toBe(WINDOW_START);
    expect(derived?.createdInWizard).toBe(true);
    expect(derived?.isCompleted).toBe(false); // 30 − 22 = 8 of 20
    expect(derived?.version).toBe(1);

    const queued = await db.syncQueue.toArray();
    expect(queued.filter((q) => q.entityId === derivedId)).toHaveLength(1);
    expect(queued.find((q) => q.entityId === derivedId)?.entityType).toBe('tasks');
    expect(queued.find((q) => q.entityId === derivedId)?.operationType).toBe(
      SyncOperationType.CREATE,
    );
  });

  it('re-minting the same window is a true no-op — no rewrite, no second sync item', async () => {
    const root = countingTask(ROOT, { currentCount: 30 });
    await db.tasks.add(root);
    const events = [incrementEvent('ev-1', ROOT, 10, BEFORE_A)];
    await db.taskEvents.bulkAdd(events);

    await mint(mintArgs([ROOT], boardSource(retargeted()), [root], [], events));
    const derivedId = derivedTaskId(BOARD, ROOT);
    const first = await db.tasks.get(derivedId);
    const queueAfterFirst = await db.syncQueue.count();

    // Same args, a second save/spawn of the same window.
    const placementIds = await mint(
      mintArgs([ROOT], boardSource(retargeted()), [root], [], events),
    );

    expect(placementIds).toEqual([derivedId]);
    const second = await db.tasks.get(derivedId);
    expect(second?.version).toBe(1);
    expect(second?.updatedAt).toBe(first?.updatedAt);
    expect(await db.syncQueue.count()).toBe(queueAfterFirst);
  });

  it('a tombstoned derived row is revived with a version bump and an UPDATE enqueue', async () => {
    const root = countingTask(ROOT, { currentCount: 30 });
    await db.tasks.add(root);
    const events = [incrementEvent('ev-1', ROOT, 10, BEFORE_A)];
    await db.taskEvents.bulkAdd(events);

    const derivedId = derivedTaskId(BOARD, ROOT);
    await db.tasks.add(
      countingTask(derivedId, {
        sharedCounterId: ROOT,
        baseline: 0,
        createdInWizard: true,
        startDate: WINDOW_START,
        createdAt: BEFORE_B,
        isDeleted: true,
        deletedAt: BEFORE_B,
        version: 3,
      }),
    );

    await mint(mintArgs([ROOT], boardSource(retargeted()), [root], [], events));

    const revived = await db.tasks.get(derivedId);
    expect(revived?.isDeleted).toBe(false);
    expect(revived?.deletedAt).toBeUndefined();
    expect(revived?.version).toBe(4);
    expect(revived?.updatedAt).toBe(NOW);
    expect(revived?.createdAt).toBe(BEFORE_B); // birth preserved
    expect(revived?.baseline).toBe(10); // this window's freshly-computed value

    const queued = (await db.syncQueue.toArray()).filter((q) => q.entityId === derivedId);
    expect(queued).toHaveLength(1);
    expect(queued[0].operationType).toBe(SyncOperationType.UPDATE);
  });

  it('a recurring board pro-rates the auto target from the source window (weekly 35 → daily 5)', async () => {
    const root = countingTask(ROOT, { currentCount: 0 });
    await db.tasks.add(root);

    await mint(
      mintArgs([ROOT], boardSource(), [root], [], [], {
        mode: 'recurring',
        window: {
          timeframe: Timeframe.DAILY,
          startDate: WINDOW_START,
          endDate: '2026-09-14T23:59:59.999',
        },
      }),
    );

    const derived = await db.tasks.get(derivedTaskId(BOARD, ROOT));
    expect(derived?.maxCount).toBe(5); // ceil(35 × 1 / 7)
    expect(derived?.title).toBe('Run 5 km');
  });

  it('places the ROOT and mints nothing when the derived row would be identical', async () => {
    const root = countingTask(ROOT, { currentCount: 30 });
    await db.tasks.add(root);
    const events = [incrementEvent('ev-1', ROOT, 10, BEFORE_A)];
    await db.taskEvents.bulkAdd(events);

    // Weekly source → weekly board, vary off, no explicit target: the auto
    // target pro-rates to exactly the root's own goal (35), so a derived row
    // would be a byte-for-byte clone. Owner ruling 2026-09-22 — place the root.
    const placementIds = await mint(mintArgs([ROOT], boardSource(), [root], [], events));

    expect(placementIds).toEqual([ROOT]);
    expect(await db.tasks.get(derivedTaskId(BOARD, ROOT))).toBeUndefined();
    expect(await db.tasks.count()).toBe(1); // the root, and only the root
    expect(await db.syncQueue.count()).toBe(0);
  });
});

describe('planAndMintDerivedRows — derived compound (RB10)', () => {
  const COMPOUND = 'c0000000-0000-4000-8000-000000000001';
  const CHILD_COUNT = 'a0000000-0000-4000-8000-000000000002';
  const CHILD_NORMAL = 'a0000000-0000-4000-8000-000000000003';

  it('re-targets a One-square compound: derived compound + both links + one derived part', async () => {
    const compound = countingTask(COMPOUND, {
      title: 'Morning set',
      type: TaskType.COMPOUND,
      operator: OperatorType.AND,
      action: undefined,
      unit: undefined,
      maxCount: undefined,
    });
    const countingChild = countingTask(CHILD_COUNT, {
      title: 'Push-ups 10',
      action: 'Push-ups',
      unit: 'reps',
      maxCount: 10,
      currentCount: 6,
    });
    const normalChild = countingTask(CHILD_NORMAL, {
      title: 'Stretch',
      type: TaskType.NORMAL,
      action: undefined,
      unit: undefined,
      maxCount: undefined,
    });
    await db.tasks.bulkAdd([compound, countingChild, normalChild]);
    const links: CompoundChild[] = [
      {
        id: 'link-1',
        compoundTaskId: COMPOUND,
        childTaskId: CHILD_COUNT,
        childIndex: 0,
        createdAt: BEFORE_A,
        updatedAt: BEFORE_A,
        version: 1,
        isDeleted: false,
      },
      {
        id: 'link-2',
        compoundTaskId: COMPOUND,
        childTaskId: CHILD_NORMAL,
        childIndex: 1,
        createdAt: BEFORE_A,
        updatedAt: BEFORE_A,
        version: 1,
        isDeleted: false,
      },
    ];
    await db.compoundChildren.bulkAdd(links);
    const events = [incrementEvent('ev-1', CHILD_COUNT, 6, BEFORE_A)];
    await db.taskEvents.bulkAdd(events);

    const source = boardSource({
      memberRules: { [COMPOUND]: { parts: { [CHILD_COUNT]: { target: 4 } } } },
    });
    const placementIds = await mint(
      mintArgs([COMPOUND], source, [compound, countingChild, normalChild], links, events),
    );

    const compoundId = derivedCompoundId(BOARD, COMPOUND);
    const partId = derivedTaskId(BOARD, CHILD_COUNT);
    expect(placementIds).toEqual([compoundId]);

    const derivedCompound = await db.tasks.get(compoundId);
    expect(derivedCompound?.type).toBe(TaskType.COMPOUND);
    expect(derivedCompound?.operator).toBe(OperatorType.AND);
    expect(derivedCompound?.title).toBe('Morning set');
    expect(derivedCompound?.startDate).toBe(WINDOW_START);

    const derivedPart = await db.tasks.get(partId);
    expect(derivedPart?.maxCount).toBe(4);
    expect(derivedPart?.baseline).toBe(6); // the child's own pre-window log
    expect(derivedPart?.currentCount).toBe(6);

    const childLinks = (
      await db.compoundChildren.where('compoundTaskId').equals(compoundId).toArray()
    ).sort((a, b) => a.childIndex - b.childIndex);
    expect(childLinks.map((l) => l.childTaskId)).toEqual([partId, CHILD_NORMAL]);
    expect(childLinks.map((l) => l.id)).toEqual([
      derivedLinkId(compoundId, partId),
      derivedLinkId(compoundId, CHILD_NORMAL),
    ]);

    const queued = await db.syncQueue.toArray();
    const ids = new Set(queued.map((q) => q.entityId));
    expect(ids.has(compoundId)).toBe(true);
    expect(ids.has(partId)).toBe(true);
    for (const l of childLinks) {
      expect(queued.find((q) => q.entityId === l.id)?.entityType).toBe('compoundChildren');
    }
  });
});

describe('refreshDerivedBaselines — non-authored', () => {
  const DERIVED = derivedTaskId(BOARD, ROOT);

  async function seedDerived(baseline: number): Promise<void> {
    await db.tasks.add(countingTask(ROOT, { currentCount: 20 }));
    await db.tasks.add(
      countingTask(DERIVED, {
        sharedCounterId: ROOT,
        baseline,
        createdInWizard: true,
        startDate: WINDOW_START,
        version: 1,
      }),
    );
  }

  it('rewrites only `baseline` — version untouched, nothing enqueued — and no-ops when unchanged', async () => {
    await seedDerived(2);
    await db.taskEvents.add(incrementEvent('ev-1', ROOT, 2, BEFORE_A));

    const unchanged = await db.transaction(
      'rw',
      [db.tasks, db.taskEvents],
      async () => refreshDerivedBaselines(ROOT),
    );
    expect(unchanged).toBe(0);

    // A backdated (pre-window) increment lands — e.g. pulled from another
    // device — so the window baseline must move.
    await db.taskEvents.add(incrementEvent('ev-2', ROOT, 5, BEFORE_B));
    const before = await db.tasks.get(DERIVED);
    const touched = await db.transaction(
      'rw',
      [db.tasks, db.taskEvents],
      async () => refreshDerivedBaselines(ROOT),
    );

    expect(touched).toBe(1);
    const after = await db.tasks.get(DERIVED);
    expect(after?.baseline).toBe(7);
    expect(after?.version).toBe(before?.version);
    expect(after?.updatedAt).toBe(before?.updatedAt);
    expect(await db.syncQueue.count()).toBe(0);

    const again = await db.transaction(
      'rw',
      [db.tasks, db.taskEvents],
      async () => refreshDerivedBaselines(ROOT),
    );
    expect(again).toBe(0);
  });

  it('ignores a hand-made linked counter (no wizard provenance / no window stamp)', async () => {
    await db.tasks.add(countingTask(ROOT, { currentCount: 20 }));
    await db.tasks.add(
      countingTask('a0000000-0000-4000-8000-000000000009', {
        sharedCounterId: ROOT,
        baseline: 0,
        // no `createdInWizard`, no `startDate` — ordinary user data.
      }),
    );
    await db.taskEvents.add(incrementEvent('ev-1', ROOT, 9, BEFORE_A));

    const touched = await db.transaction(
      'rw',
      [db.tasks, db.taskEvents],
      async () => refreshDerivedBaselines(ROOT),
    );
    expect(touched).toBe(0);
    const linked = await db.tasks.get('a0000000-0000-4000-8000-000000000009');
    expect(linked?.baseline).toBe(0);
  });
});
