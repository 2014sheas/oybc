import { afterEach, beforeEach, describe, expect, it } from 'vitest';
import type { Board, Pool, RecurringBoardTemplate, Task } from '@oybc/shared';
import { BoardStatus, OperatorType, TaskType, derivedCompoundId, derivedTaskId } from '@oybc/shared';
import { db } from '../../internal';
import { runPlacementSweep } from '../placementSweep';
import { decodeRecurringDraftMix, encodeRecurringDraftMix } from '../../recurringDraftMix';
import { JUNE, ROOT, T0, USER, boardRow, clearAll, incEvent, placement, queued, rootTask } from './linkedCounterFixtures';

const NOW = '2026-10-18T12:00:00.000Z';

function derived(id: string, over: Partial<Task> = {}): Task {
  return {
    ...rootTask({ id, title: 'Run 5 miles', maxCount: 5, sharedCounterId: ROOT, baseline: 0, version: 2 }),
    timeframe: 'monthly',
    startDate: JUNE.startDate,
    endDate: JUNE.endDate,
    createdInWizard: true,
    ...over,
  } as Task;
}

async function seed(): Promise<void> {
  await db.tasks.bulkPut([rootTask(), derived('D1')]);
  await db.boards.put(boardRow(JUNE));
  await db.boardTasks.put(placement('bt1', JUNE.id, 'D1'));
  await db.taskEvents.put(incEvent('e1', ROOT, 5, '2026-06-10T10:00:00.000Z'));
}

beforeEach(async () => {
  await clearAll();
  await Promise.all([db.recurringBoardTemplates.clear(), db.pools.clear()]);
});
afterEach(async () => {
  await clearAll();
  await Promise.all([db.recurringBoardTemplates.clear(), db.pools.clear()]);
});

describe('runPlacementSweep', () => {
  it('writes nothing for an empty workspace', async () => {
    const s = await runPlacementSweep(USER, NOW);
    expect(s.repoints + s.strips + s.orphans).toBe(0);
    expect(await db.syncQueue.count()).toBe(0);
  });

  it('repoints a live placement at the root with the frozen goal, enqueues and re-derives', async () => {
    await seed();
    const s = await runPlacementSweep(USER, NOW);
    expect(s.repoints).toBe(1);
    const bt = (await db.boardTasks.get('bt1'))!;
    expect(bt.taskId).toBe(ROOT);
    expect(bt.targetOverride).toBe(5);
    expect(bt.version).toBe(2);
    expect(await queued('boardTasks')).toContain('bt1');
    expect((await db.boards.get(JUNE.id))!.completedTasks).toBe(1);
  });

  it('repoints a sealed placement and leaves the snapshot unchanged', async () => {
    await seed();
    await db.boards.put(
      boardRow(JUNE, { sealedAt: '2026-07-31T00:00:00.000Z', sealedCompletedCells: [0], completedTasks: 1 }),
    );
    const s = await runPlacementSweep(USER, NOW);
    expect(s.repoints).toBe(1);
    expect((await db.boardTasks.get('bt1'))!.taskId).toBe(ROOT);
    const b = (await db.boards.get(JUNE.id))!;
    expect(b.sealedCompletedCells).toEqual([0]);
    expect(b.completedTasks).toBe(1);
  });

  it('strips a refused board, orphan-tombstones unplaced rows, and a second run is quiet', async () => {
    await seed();
    // Refused: root missing -> strip.
    await db.tasks.put(derived('D2', { sharedCounterId: 'gone' }));
    await db.boardTasks.put(placement('bt2', JUNE.id, 'D2', 0, 1));
    // Orphan: no placement, no link.
    await db.tasks.put(derived('D3'));
    const s = await runPlacementSweep(USER, NOW);
    expect(s.refused.length).toBe(1);
    expect(s.strips).toBeGreaterThanOrEqual(2);
    expect(s.orphans).toBe(1);
    const d3 = (await db.tasks.get('D3'))!;
    expect(d3.isDeleted).toBe(true);
    // The whole board is refused: no repoint, both marked rows stripped.
    expect((await db.boardTasks.get('bt1'))!.taskId).toBe('D1');
    expect('timeframe' in (await db.tasks.get('D1'))!).toBe(false);
  });

  it('strip clears the window fields (absent), resets baseline and enqueues', async () => {
    await db.tasks.bulkPut([rootTask(), derived('D2', { sharedCounterId: 'gone', baseline: 3 })]);
    await db.boards.put(boardRow(JUNE));
    await db.boardTasks.put(placement('bt2', JUNE.id, 'D2'));
    await runPlacementSweep(USER, NOW);
    const d = (await db.tasks.get('D2'))!;
    expect('timeframe' in d).toBe(false);
    expect('startDate' in d).toBe(false);
    expect('endDate' in d).toBe(false);
    expect(d.baseline).toBe(0);
    expect(d.version).toBe(3);
    expect(await queued('tasks')).toContain('D2');
  });

  it('re-keys templates (with the manualTaskTargets carry), pools and draft blobs', async () => {
    await seed();
    const tpl = {
      id: 'tpl1', userId: USER, name: 'T', timeframe: 'monthly', seedTaskIds: ['D1'], manualTaskIds: ['D1'],
      removedTaskIds: [], sources: [{ sourceId: 'p', kind: 'pool', min: 0, max: null, excludedTaskIds: ['D1'], filter: 'all',
        memberRules: { D1: { target: 3, parts: { D1: { vary: 1 } } } } }],
      manualTaskVary: { D1: 1 }, lastSpawnedWindowKey: null, isActive: true, createdAt: T0, updatedAt: T0, version: 1, isDeleted: false,
    } as unknown as RecurringBoardTemplate;
    const pool = { id: 'pool1', userId: USER, name: 'P', taskIds: ['D1', 'x'], memberVary: { D1: 2 }, createdAt: T0, updatedAt: T0, version: 1, isDeleted: false } as unknown as Pool;
    const draft = boardRow(JUNE, {
      id: 'draft1', status: BoardStatus.DRAFT,
      recurringDraftMix: encodeRecurringDraftMix({ poolIds: [], manualTaskIds: ['D1'], removedTaskIds: [], placementParams: { D1: { targetOverride: 4 } } }),
    });
    await db.recurringBoardTemplates.put(tpl);
    await db.pools.put(pool);
    await db.boards.put(draft as Board);

    const s = await runPlacementSweep(USER, NOW);
    expect([s.rekeyedTemplates, s.rekeyedPools, s.rekeyedDrafts]).toEqual([1, 1, 1]);

    const t = (await db.recurringBoardTemplates.get('tpl1'))!;
    expect(t.seedTaskIds).toEqual([ROOT]);
    expect(t.manualTaskIds).toEqual([ROOT]);
    expect(t.sources![0].excludedTaskIds).toEqual([ROOT]);
    expect(Object.keys(t.sources![0].memberRules!)).toEqual([ROOT]);
    expect(Object.keys(t.sources![0].memberRules![ROOT].parts!)).toEqual([ROOT]);
    expect(t.manualTaskVary).toEqual({ [ROOT]: 1 });
    expect(t.manualTaskTargets![ROOT].target).toBe(5);
    expect(t.version).toBe(2);
    const p = (await db.pools.get('pool1'))!;
    expect(p.taskIds).toEqual([ROOT, 'x']);
    expect(p.memberVary).toEqual({ [ROOT]: 2 });
    const mix = decodeRecurringDraftMix((await db.boards.get('draft1'))!.recurringDraftMix);
    expect(mix.manualTaskIds).toEqual([ROOT]);
    expect(Object.keys(mix.placementParams)).toEqual([ROOT]);
    expect(await queued('recurringBoardTemplates')).toContain('tpl1');
    expect(await queued('pools')).toContain('pool1');
  });

  it('a second run writes nothing new except retiring the rows the first repointed away from', async () => {
    await seed();
    await runPlacementSweep(USER, NOW);
    const queueAfterFirst = await db.syncQueue.count();
    const second = await runPlacementSweep(USER, NOW);
    expect(second.repoints).toBe(0);
    expect(second.orphans).toBe(1);
    expect((await db.tasks.get('D1'))!.isDeleted).toBe(true);
    expect(await db.syncQueue.count()).toBe(queueAfterFirst + 1);
    const third = await runPlacementSweep(USER, NOW);
    expect(third.repoints + third.strips + third.orphans).toBe(0);
    expect(await db.syncQueue.count()).toBe(queueAfterFirst + 1);
  });
});

describe('runPlacementSweep — derived compounds (slice 4b)', () => {
  const SRC = 'src-compound';
  const CHILD = 'child-run';

  async function seedCompound(): Promise<{ dc: string; part: string }> {
    const dc = derivedCompoundId(JUNE.id, SRC);
    const part = derivedTaskId(JUNE.id, ROOT);
    const source = {
      ...rootTask({ id: SRC, title: 'Fit', type: TaskType.COMPOUND, operator: OperatorType.AND, maxCount: undefined, unit: undefined, action: undefined }),
    } as unknown as Task;
    const child = rootTask({ id: CHILD, title: 'Run 100 miles', sharedCounterId: ROOT });
    const derivedC = { ...source, id: dc, startDate: JUNE.startDate, createdInWizard: true, version: 2 } as Task;
    const derivedPart = derived(part, { sharedCounterId: ROOT, maxCount: 5 });
    await db.tasks.bulkPut([rootTask(), child, source, derivedC, derivedPart]);
    await db.boards.put(boardRow(JUNE, { completedTasks: 1 }));
    await db.boardTasks.put(placement('btc', JUNE.id, dc));
    await db.compoundChildren.bulkPut([
      { id: 'l-src', compoundTaskId: SRC, childTaskId: CHILD, childIndex: 0, createdAt: T0, updatedAt: T0, version: 1, isDeleted: false },
      { id: 'l-der', compoundTaskId: dc, childTaskId: part, childIndex: 0, createdAt: T0, updatedAt: T0, version: 1, isDeleted: false },
    ] as never);
    await db.taskEvents.put(incEvent('e1', ROOT, 5, '2026-06-10T10:00:00.000Z'));
    return { dc, part };
  }

  it('repoints a derived compound at its source with childTargets and keeps the grid', async () => {
    const { dc } = await seedCompound();
    const gridBefore = 1;
    const s = await runPlacementSweep(USER, NOW);
    expect(s.repoints).toBe(1);
    const bt = (await db.boardTasks.get('btc'))!;
    expect(bt.taskId).toBe(SRC);
    expect(bt.childTargets).toEqual([{ childId: CHILD, target: 5 }]);
    expect(await queued('boardTasks')).toContain('btc');
    expect((await db.boards.get(JUNE.id))!.completedTasks).toBe(gridBefore);
    expect(dc).not.toBe(SRC);
  });

  it('refuses a mismatched compound and strips it', async () => {
    const { dc } = await seedCompound();
    await db.compoundChildren.put({ id: 'l-src2', compoundTaskId: SRC, childTaskId: 'extra', childIndex: 1, createdAt: T0, updatedAt: T0, version: 1, isDeleted: false } as never);
    await db.tasks.put(rootTask({ id: 'extra', title: 'Extra' }));
    const s = await runPlacementSweep(USER, NOW);
    expect(s.refused.length).toBe(1);
    expect((await db.boardTasks.get('btc'))!.taskId).toBe(dc);
    expect('startDate' in (await db.tasks.get(dc))!).toBe(false);
  });

  it('tombstones an orphan derived compound with its links, retires parts next run, then goes quiet', async () => {
    const { dc, part } = await seedCompound();
    await db.boardTasks.delete('btc');
    const first = await runPlacementSweep(USER, NOW);
    expect(first.orphans).toBeGreaterThanOrEqual(1);
    expect((await db.tasks.get(dc))!.isDeleted).toBe(true);
    expect((await db.compoundChildren.get('l-der'))!.isDeleted).toBe(true);
    const second = await runPlacementSweep(USER, NOW);
    expect((await db.tasks.get(part))!.isDeleted).toBe(true);
    expect(second.orphans).toBeGreaterThanOrEqual(0);
    const q = await db.syncQueue.count();
    const third = await runPlacementSweep(USER, NOW);
    expect(third.repoints + third.strips + third.orphans).toBe(0);
    expect(await db.syncQueue.count()).toBe(q);
  });
});
