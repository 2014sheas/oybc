import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  OperatorType,
  TaskType,
  Timeframe,
  countsTowardEventId,
  type Board,
  type BoardTask,
  type CompoundChild,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import { db } from '../../internal';
import { commitSquareEdits, type CommitSquareEditsInput } from '../boardEditCommit';
import { saveTaskEdit } from '../compoundStructureEdit';
import { compoundLinkProblemForPatch, countsTowardLoopForPatch } from '../compoundStructureEdit';
import { removeUnitTaskLineage, setCountsToward } from '../countsToward';
import { computeTaskDeletionImpact } from '../tasks.deletion';
import { deleteCounterWithUnlink } from '../tasks.counter';
import { findNewBoardCredit, loadCountsTowardSection, snapshotLiveCreditIds } from '../countsTowardSection';
import { handleTaskCompletion } from '../orchestration';
import { createTaskCountingToward, toggleCompoundChildFallback } from '../tasks.crud';
import type { SquareDraftCell } from '../../../hooks/squareEditCount';
import type { BoardEditTaskOverride } from '../../../hooks/squaresEditReducer';
import { onBoardContributors, revertUpdatesFor, writtenLineage } from '../../../hooks/useBoardPlay';
import { countsTowardProblemLabel } from '../../../components/counters/countsTowardLabels';
import type { TaskEditPatch } from '../../taskEditPatch';
import { createWithPreset } from '../../../pages/createPage/useCreateFormState';

/**
 * "Counts toward" PR 4 — the UI's data seams (docs/SHARED_COUNTER_SETTINGS.md
 * §3d / §5): the Counter Detail section's read model, the Board Edit commit
 * flagging the FORK through `setCountsTowardInTransaction`, `saveTaskEdit`'s
 * set-first / clear-last order, the credited-toast board set and the
 * completion-moment preview. iOS twins: `CountsTowardSectionTests` /
 * `CountsTowardBoardEditTests`.
 */

const USER = 'user-1';
const T0 = '2026-10-01T00:00:00.000Z';
const NOW = '2026-10-08T12:00:00.000Z';
const ROOT = '90000000-0000-4000-8000-0000000000a1';
const ROOT2 = '90000000-0000-4000-8000-0000000000a2';
const COPY = '90000000-0000-4000-8000-0000000000a3';
const DUNE = '90000000-0000-4000-8000-0000000000b1';
const PAGES = '90000000-0000-4000-8000-0000000000b2';
const LOOSE = '90000000-0000-4000-8000-0000000000b3';
const B1 = '90000000-0000-4000-8000-0000000000e1'; // weekly, being edited
const B2 = '90000000-0000-4000-8000-0000000000e2'; // monthly
const B1_START = '2026-10-05T00:00:00.000Z';
const B1_END = '2026-10-11T23:59:59.999Z';
const B2_START = '2026-10-01T00:00:00.000Z';
const B2_END = '2026-10-31T23:59:59.999Z';

function task(id: string, over: Partial<Task> = {}): Task {
  return {
    id, userId: USER, title: id, type: TaskType.NORMAL, isCompleted: false,
    totalCompletions: 0, totalInstances: 1, createdAt: T0, updatedAt: T0, version: 1, isDeleted: false, ...over,
  };
}
const rootTask = (id = ROOT, over: Partial<Task> = {}): Task =>
  task(id, { title: 'Read 12 books', type: TaskType.COUNTING, action: 'Read', unit: 'books', maxCount: 12, currentCount: 0, isCounter: true, counterName: 'Books', ...over });

function board(id: string, startDate: string, endDate: string, over: Partial<Board> = {}): Board {
  return {
    id, userId: USER, name: id, status: BoardStatus.ACTIVE, boardSize: 3, timeframe: Timeframe.WEEKLY,
    startDate, endDate, centerSquareType: CenterSquareType.NONE, isRandomized: false, totalTasks: 9,
    completedTasks: 0, linesCompleted: 0, createdAt: T0, updatedAt: T0, version: 1, isDeleted: false, ...over,
  } as Board;
}
function placement(id: string, boardId: string, taskId: string, col = 0): BoardTask {
  return { id, boardId, taskId, row: 0, col, isCenter: false, createdAt: T0, updatedAt: T0, version: 1, isDeleted: false };
}
function event(id: string, taskId: string, kind: 'completion' | 'increment', occurredAt: string, delta?: number): TaskEvent {
  return { id, userId: USER, taskId, kind, occurredAt, ...(delta !== undefined ? { delta } : {}), createdAt: T0, updatedAt: T0, version: 1, isDeleted: false };
}
function cell(o: Partial<SquareDraftCell> & Pick<SquareDraftCell, 'cellId' | 'taskId'>): SquareDraftCell {
  return { row: 0, col: 0, isLocked: false, originalTaskId: o.taskId, originalRow: o.row ?? 0, originalCol: o.col ?? 0, originalLocked: false, ...o };
}
function commitInput(cells: SquareDraftCell[], overrides: Array<[string, BoardEditTaskOverride]>): CommitSquareEditsInput {
  return { boardId: B1, cells, removedBoardTaskIds: [], taskOverrides: new Map(overrides), isLegacyChosenOnDisk: false, centerCellKeepLocked: false };
}
const liveCredits = async (rootId = ROOT): Promise<TaskEvent[]> =>
  (await db.taskEvents.where('taskId').equals(rootId).toArray()).filter((e) => !e.isDeleted && e.kind === 'increment');

beforeEach(async () => {
  vi.useFakeTimers({ toFake: ['Date'] });
  vi.setSystemTime(new Date(NOW));
  await db.boards.bulkAdd([board(B1, B1_START, B1_END, { name: 'Reading week' }), board(B2, B2_START, B2_END, { timeframe: Timeframe.MONTHLY, name: 'October' })]);
});

afterEach(async () => {
  vi.useRealTimers();
  await Promise.all([db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue].map((t) => t.clear()));
});

describe('loadCountsTowardSection', () => {
  it('lists one row per contributor with its primary board, state and live credit count', async () => {
    await db.tasks.bulkAdd([
      rootTask(),
      task(DUNE, { title: 'Finish Dune', countsTowardCounterId: ROOT, countsTowardSince: T0 }),
      task(PAGES, { title: 'Read 250 pages', type: TaskType.COUNTING, action: 'Read', unit: 'pages', maxCount: 250, countsTowardCounterId: ROOT, countsTowardAmount: 2, countsTowardSince: T0 }),
      task(LOOSE, { title: 'Audiobook', countsTowardCounterId: ROOT, countsTowardSince: T0 }),
      task('unrelated', { title: 'Stretch' }),
    ]);
    await db.boardTasks.bulkAdd([placement('bt-dune', B1, DUNE), placement('bt-pages', B1, PAGES, 1)]);
    await db.taskEvents.bulkAdd([
      event('c1', DUNE, 'completion', '2026-10-06T09:00:00.000Z'),
      event('c-old', DUNE, 'completion', '2026-09-29T09:00:00.000Z'),
      event('p1', PAGES, 'increment', '2026-10-06T10:00:00.000Z', 100),
      event(countsTowardEventId(ROOT, DUNE, { kind: 'event', eventId: 'c1' }), ROOT, 'increment', '2026-10-06T09:00:00.000Z', 1),
      event(countsTowardEventId(ROOT, DUNE, { kind: 'event', eventId: 'c-old' }), ROOT, 'increment', '2026-09-29T09:00:00.000Z', 1),
    ]);

    const data = await loadCountsTowardSection(ROOT);
    // In progress → Not started → Done (unit-tasks handoff Decision 8).
    expect(data.rows).toEqual([
      { taskId: PAGES, memberIds: [PAGES], status: 'inProgress', boardId: B1, creditCount: 0, latestOccurredAt: null, progress: { current: 100, goal: 250, kind: 'discrete' }, childProgress: null },
      { taskId: LOOSE, memberIds: [LOOSE], status: 'notStarted', boardId: null, creditCount: 0, latestOccurredAt: null, progress: null, childProgress: null },
      { taskId: DUNE, memberIds: [DUNE], status: 'done', boardId: B1, creditCount: 2, latestOccurredAt: '2026-10-06T09:00:00.000Z', progress: null, childProgress: null },
    ]);
    expect(data.taskById[DUNE]?.title).toBe('Finish Dune');
    expect(data.boardById[B1]?.name).toBe('Reading week');
  });

  it('is empty with no contributors (no table scans beyond the contributor read)', async () => {
    await db.tasks.bulkAdd([rootTask(), task(DUNE, { title: 'Finish Dune' })]);
    expect(await loadCountsTowardSection(ROOT)).toEqual({ rows: [], taskById: {}, boardById: {} });
  });
});

describe('credit watch — snapshotLiveCreditIds + findNewBoardCredit (the credited toast rule)', () => {
  const PAGES_BT = 'bt-pages';
  const DUNE_BT = 'bt-dune';

  async function seedWithOtherBoardCopy(): Promise<void> {
    await db.tasks.bulkAdd([
      rootTask(),
      task(COPY, { type: TaskType.COUNTING, action: 'Read', unit: 'books', maxCount: 1, sharedCounterId: ROOT, baseline: 0, currentCount: 0 }),
      task(DUNE, { title: 'Finish Dune', countsTowardCounterId: ROOT, countsTowardSince: T0 }),
      task(PAGES, { title: 'Read 250 pages', type: TaskType.COUNTING, action: 'Read', unit: 'pages', maxCount: 250, countsTowardCounterId: ROOT, countsTowardSince: T0 }),
      task(LOOSE, { title: 'Stretch' }),
    ]);
    await db.boardTasks.bulkAdd([placement(DUNE_BT, B1, DUNE), placement(PAGES_BT, B1, PAGES, 1), placement('bt-loose', B1, LOOSE, 2), placement('bt-copy', B2, COPY)]);
  }
  const contributorsOn = async (): Promise<Task[]> => {
    const bts = await db.boardTasks.where('boardId').equals(B1).toArray();
    const ids = bts.map((bt) => bt.taskId);
    return (await db.tasks.bulkGet(ids)).filter((t): t is Task => !!t && t.countsTowardCounterId != null);
  };

  it('a Simple square checked off: one new credit for the on-board contributor, the other board (window contains the credit) listed', async () => {
    await seedWithOtherBoardCopy();
    const before = await snapshotLiveCreditIds([ROOT]);
    await handleTaskCompletion(B1, DUNE_BT, { isCompleted: true });
    const found = await findNewBoardCredit(B1, await contributorsOn(), before);
    expect(found?.contributor.id).toBe(DUNE);
    expect(found?.root.id).toBe(ROOT);
    expect(found?.credits).toHaveLength(1);
    expect(found?.credits[0]).toMatchObject({ taskId: ROOT, delta: 1, occurredAt: NOW });
    expect(found?.amount).toBe(1);
    expect(found?.otherBoards).toEqual([{ boardId: B2, boardName: 'October' }]);
    // The same snapshot taken AFTER sees nothing new.
    expect(await findNewBoardCredit(B1, await contributorsOn(), await snapshotLiveCreditIds([ROOT]))).toBeNull();
  });

  it('a Counting square reaching its goal credits once; stepping further does not', async () => {
    await seedWithOtherBoardCopy();
    let before = await snapshotLiveCreditIds([ROOT]);
    await handleTaskCompletion(B1, PAGES_BT, { currentCount: 100 });
    expect(await findNewBoardCredit(B1, await contributorsOn(), before)).toBeNull();
    before = await snapshotLiveCreditIds([ROOT]);
    await handleTaskCompletion(B1, PAGES_BT, { currentCount: 250 });
    expect((await findNewBoardCredit(B1, await contributorsOn(), before))?.contributor.id).toBe(PAGES);
    before = await snapshotLiveCreditIds([ROOT]);
    await handleTaskCompletion(B1, PAGES_BT, { currentCount: 300 });
    expect(await findNewBoardCredit(B1, await contributorsOn(), before)).toBeNull();
  });

  it('a Compound completed through a sub-task toggle credits once, attributed to the compound placed here', async () => {
    const BOX = '90000000-0000-4000-8000-0000000000c1';
    const KID = '90000000-0000-4000-8000-0000000000c2';
    await db.tasks.bulkAdd([
      rootTask(),
      task(COPY, { type: TaskType.COUNTING, action: 'Read', unit: 'books', maxCount: 1, sharedCounterId: ROOT, baseline: 0, currentCount: 0 }),
      task(BOX, { title: 'Book club', type: TaskType.COMPOUND, operator: OperatorType.AND, countsTowardCounterId: ROOT, countsTowardSince: T0 }),
      task(KID, { title: 'Read the book' }),
    ]);
    await db.compoundChildren.add({ id: 'l1', compoundTaskId: BOX, childTaskId: KID, childIndex: 0, createdAt: T0, updatedAt: T0, version: 1, isDeleted: false });
    await db.boardTasks.bulkAdd([placement('bt-box', B1, BOX), placement('bt-copy', B2, COPY)]);

    const before = await snapshotLiveCreditIds([ROOT]);
    await toggleCompoundChildFallback(KID, true, B1_START, B1_END, B1);
    const found = await findNewBoardCredit(B1, await contributorsOn(), before);
    expect(found?.contributor.id).toBe(BOX);
    expect(found?.otherBoards.map((b) => b.boardId)).toEqual([B2]);
    expect(await liveCredits()).toHaveLength(1);
  });

  it('nothing credited → null: a completion stamped before `since`, an unflagged square; no other board → empty trigger set', async () => {
    await seedWithOtherBoardCopy();
    await db.tasks.update(DUNE, { countsTowardSince: '2026-10-09T00:00:00.000Z' });
    let before = await snapshotLiveCreditIds([ROOT]);
    await handleTaskCompletion(B1, DUNE_BT, { isCompleted: true });
    expect(await liveCredits()).toHaveLength(0);
    expect(await findNewBoardCredit(B1, await contributorsOn(), before)).toBeNull();

    before = await snapshotLiveCreditIds([ROOT]);
    await handleTaskCompletion(B1, 'bt-loose', { isCompleted: true });
    expect(await findNewBoardCredit(B1, await contributorsOn(), before)).toBeNull();

    // Only this board places the counter → a credit is written but no other board counts it → no toast.
    await db.boardTasks.update('bt-copy', { boardId: B1 });
    before = await snapshotLiveCreditIds([ROOT]);
    await handleTaskCompletion(B1, PAGES_BT, { currentCount: 250 });
    expect(await liveCredits()).toHaveLength(1);
    expect(await findNewBoardCredit(B1, await contributorsOn(), before)).toBeNull();
  });

  it('attribution: a credit that lands for ANOTHER contributor between the snapshots is not pinned on the written task', async () => {
    await seedWithOtherBoardCopy();
    const before = await snapshotLiveCreditIds([ROOT]);
    // The written task (Read 250 pages) stays short of its goal; meanwhile Finish Dune's credit arrives (a pull).
    await handleTaskCompletion(B1, PAGES_BT, { currentCount: 100 });
    await db.taskEvents.add(event('c-dune', DUNE, 'completion', NOW));
    await db.taskEvents.add(event(countsTowardEventId(ROOT, DUNE, { kind: 'event', eventId: 'c-dune' }), ROOT, 'increment', NOW, 1));
    const written = (await contributorsOn()).filter((t) => t.id === PAGES);
    expect(await findNewBoardCredit(B1, written, before)).toBeNull();
    // Attributed to its own lineage only.
    const dune = (await contributorsOn()).filter((t) => t.id === DUNE);
    expect((await findNewBoardCredit(B1, dune, before))?.contributor.id).toBe(DUNE);
  });

  it('sums every new credit of the contributor on its root; a board sealed before the credit is not a trigger', async () => {
    const SEALED = '90000000-0000-4000-8000-0000000000e4';
    await seedWithOtherBoardCopy();
    await db.boards.add(board(SEALED, B2_START, B2_END, { name: 'Closed early', sealedAt: '2026-10-03T00:00:00.000Z', timeframe: Timeframe.MONTHLY }));
    await db.boardTasks.add(placement('bt-sealed', SEALED, ROOT));
    const before = await snapshotLiveCreditIds([ROOT]);
    await db.taskEvents.bulkAdd([
      event('c1', DUNE, 'completion', '2026-10-06T09:00:00.000Z'),
      event('c2', DUNE, 'completion', NOW),
      event(countsTowardEventId(ROOT, DUNE, { kind: 'event', eventId: 'c1' }), ROOT, 'increment', '2026-10-06T09:00:00.000Z', 2),
      event(countsTowardEventId(ROOT, DUNE, { kind: 'event', eventId: 'c2' }), ROOT, 'increment', NOW, 2),
    ]);
    const found = await findNewBoardCredit(B1, (await contributorsOn()).filter((t) => t.id === DUNE), before);
    expect(found?.credits).toHaveLength(2);
    expect(found?.amount).toBe(4);
    expect(found?.otherBoards.map((b) => b.boardId)).toEqual([B2]);
    // Sealed AFTER the credits → it counted them → listed.
    await db.boards.update(SEALED, { sealedAt: '2026-10-09T00:00:00.000Z' });
    const again = await findNewBoardCredit(B1, (await contributorsOn()).filter((t) => t.id === DUNE), before);
    expect(again?.otherBoards.map((b) => b.boardId).sort()).toEqual([B2, SEALED].sort());
  });
});

describe('useBoardPlay pure helpers', () => {
  it('writtenLineage is the task plus every compound deriving through it, transitively', () => {
    const links = (compound: string, child: string): CompoundChild => ({ id: `${compound}-${child}`, compoundTaskId: compound, childTaskId: child, childIndex: 0, createdAt: T0, updatedAt: T0, version: 1, isDeleted: false });
    const byCompound = { k1: [links('k1', 'a')], k2: [links('k2', 'k1')], k3: [{ ...links('k3', 'a'), isDeleted: true }], other: [links('other', 'z')] };
    expect([...writtenLineage('a', byCompound)].sort()).toEqual(['a', 'k1', 'k2']);
    expect([...writtenLineage('z', byCompound)].sort()).toEqual(['other', 'z']);
  });

  it('onBoardContributors keeps flagged, unlinked tasks in board order; revertUpdatesFor inverts the write', () => {
    const dune = task(DUNE, { countsTowardCounterId: ROOT });
    const pages = task(PAGES, { type: TaskType.COUNTING, maxCount: 250, countsTowardCounterId: ROOT });
    const linked = task(COPY, { type: TaskType.COUNTING, sharedCounterId: ROOT, countsTowardCounterId: ROOT });
    const bts = [placement('b1', B1, PAGES), placement('b2', B1, DUNE, 1), placement('b3', B1, COPY, 2), placement('b4', B1, LOOSE, 3)];
    const taskMap = { [DUNE]: dune, [PAGES]: pages, [COPY]: linked, [LOOSE]: task(LOOSE) };
    expect(onBoardContributors(bts, taskMap).map((t) => t.id)).toEqual([PAGES, DUNE]);

    const ctx = { windowStart: B1_START, windowEnd: B1_END, eventsByTaskId: { [PAGES]: [event('p1', PAGES, 'increment', '2026-10-06T10:00:00.000Z', 100)] } };
    expect(revertUpdatesFor(dune, { isCompleted: true }, ctx)).toEqual({ isCompleted: false });
    expect(revertUpdatesFor(pages, { currentCount: 250 }, ctx)).toEqual({ currentCount: 100 });
    expect(revertUpdatesFor(pages, { completedStepIds: [] } as never, ctx)).toBeNull();
  });
});

describe('fix round — guards', () => {
  it('a compound with no live sub-tasks may not stop counting (it would evaluate vacuously complete)', async () => {
    const BOX = '90000000-0000-4000-8000-0000000000c1';
    await db.tasks.bulkAdd([rootTask(), task(BOX, { title: 'Shell', type: TaskType.COMPOUND, operator: OperatorType.AND, countsTowardCounterId: ROOT, countsTowardSince: T0 })]);
    await expect(setCountsToward(BOX, null)).rejects.toMatchObject({ code: 'compound-needs-child' });
    expect((await db.tasks.get(BOX))!.countsTowardCounterId).toBe(ROOT);
    expect(countsTowardProblemLabel('compound-needs-child')).toBe('A compound task needs a sub-task.');
  });

  it('a sub-task that closes a counts-toward loop is refused on an already-flagged compound (both editors)', async () => {
    const BOX = '90000000-0000-4000-8000-0000000000c1';
    await db.tasks.bulkAdd([
      rootTask(),
      task(COPY, { type: TaskType.COUNTING, action: 'Read', unit: 'books', maxCount: 1, sharedCounterId: ROOT, baseline: 0, currentCount: 0 }),
      task(BOX, { title: 'Box', type: TaskType.COMPOUND, operator: OperatorType.AND }),
    ]);
    await db.boardTasks.add(placement('bt-box', B1, BOX));
    const withCopy: TaskEditPatch = {
      title: 'Box', action: '', goal: '', unit: '', operator: OperatorType.AND,
      children: [{ id: COPY, childTaskId: COPY, title: 'Read 1 book', isCounting: true, action: 'Read', goal: '1', unit: 'books', countKind: 'discrete', markedDeleted: false, childType: TaskType.COUNTING }],
    };
    // Already flagged: the structure edit alone is refused — Task Detail save, the Board Edit pre-check and its commit.
    await setCountsToward(BOX, ROOT);
    await expect(saveTaskEdit(BOX, { title: 'Box', compound: withCopy })).rejects.toMatchObject({ code: 'cycle' });
    // The Board Edit sheet's Done pre-check (the UI maps the code to its label).
    expect(await countsTowardLoopForPatch(BOX, withCopy)).toBe('cycle');
    expect(await compoundLinkProblemForPatch(BOX, withCopy)).toBeNull();
    await expect(commitSquareEdits(commitInput([cell({ cellId: 'bt-box', taskId: BOX })], [[BOX, { title: 'Box', compound: withCopy }]]))).rejects.toMatchObject({ code: 'cycle' });
    expect(await db.compoundChildren.where('compoundTaskId').equals(BOX).filter((l) => !l.isDeleted).count()).toBe(0);
  });

  it('createTaskCountingToward creates and flags in one transaction; a refused flag leaves no task behind', async () => {
    await db.tasks.bulkAdd([rootTask(), rootTask(ROOT2, { countKind: 'continuous', counterName: 'Miles' })]);
    const made = await createTaskCountingToward(USER, { title: 'Finish Dune', type: TaskType.NORMAL }, { counterId: ROOT, amount: 2 });
    expect(made).toMatchObject({ countsTowardCounterId: ROOT, countsTowardAmount: 2, countsTowardSince: NOW });
    const n = await db.tasks.count();
    await expect(createTaskCountingToward(USER, { title: 'Walk', type: TaskType.NORMAL }, { counterId: ROOT2 })).rejects.toMatchObject({ code: 'target-not-discrete' });
    expect(await db.tasks.count()).toBe(n);
    expect(await db.tasks.filter((t) => t.title === 'Walk').count()).toBe(0);
  });
});

describe('setCountsToward (the one write path) — sanity', () => {
  it('refuses a Continuous target with the target-not-discrete code', async () => {
    await db.tasks.bulkAdd([rootTask(ROOT2, { countKind: 'continuous' }), task(DUNE)]);
    await expect(setCountsToward(DUNE, ROOT2)).rejects.toMatchObject({ code: 'target-not-discrete' });
  });
});

describe('createWithPreset — the create form\'s silent "+ New" flag', () => {
  it('a preset writes the flag and no amount (always one); no preset writes none', async () => {
    await db.tasks.bulkAdd([rootTask()]);
    const flagged = await createWithPreset(USER, { title: 'Walk to work', type: TaskType.NORMAL }, ROOT);
    expect(flagged).toMatchObject({ countsTowardCounterId: ROOT, countsTowardSince: NOW });
    expect(flagged.countsTowardAmount).toBeUndefined();
    const plain = await createWithPreset(USER, { title: 'Stretch', type: TaskType.NORMAL }, null);
    expect(plain.countsTowardCounterId).toBeUndefined();
    expect(plain.countsTowardSince).toBeUndefined();
  });
});

describe('unit tasks — remove and counter delete', () => {
  it('remove = setCountsToward(null): the task stays, the row leaves, its credits are withdrawn', async () => {
    await db.tasks.bulkAdd([rootTask(), task(DUNE, { title: 'Finish Dune', countsTowardCounterId: ROOT, countsTowardSince: T0 })]);
    await db.boardTasks.bulkAdd([placement('bt-dune', B1, DUNE)]);
    await db.taskEvents.bulkAdd([
      event('c1', DUNE, 'completion', '2026-10-06T09:00:00.000Z'),
      event(countsTowardEventId(ROOT, DUNE, { kind: 'event', eventId: 'c1' }), ROOT, 'increment', '2026-10-06T09:00:00.000Z', 1),
    ]);
    expect((await loadCountsTowardSection(ROOT)).rows[0]?.creditCount).toBe(1);

    await setCountsToward(DUNE, null);

    expect((await loadCountsTowardSection(ROOT)).rows).toEqual([]);
    expect((await db.tasks.get(DUNE))?.isDeleted).toBe(false);
    expect((await db.tasks.get(DUNE))?.countsTowardCounterId ?? null).toBeNull();
    expect(await liveCredits()).toHaveLength(0);
  });

  it('remove clears EVERY lineage member in one transaction: a flagged board-scoped fork leaves with its original', async () => {
    const FORK = '90000000-0000-4000-8000-0000000000b9';
    await db.tasks.bulkAdd([
      rootTask(),
      task(DUNE, { title: 'Finish Dune', countsTowardCounterId: ROOT, countsTowardSince: T0 }),
      task(FORK, { title: 'Finish Dune', forkedFromTaskId: DUNE, countsTowardCounterId: ROOT, countsTowardSince: T0 }),
    ]);
    const before = await loadCountsTowardSection(ROOT);
    expect(before.rows).toHaveLength(1);
    expect(before.rows[0]?.memberIds).toEqual([DUNE, FORK].sort());

    // Clearing only the representative would leave the row (the fork keeps the flag).
    await removeUnitTaskLineage(before.rows[0]?.memberIds ?? []);

    expect((await loadCountsTowardSection(ROOT)).rows).toEqual([]);
    for (const id of [DUNE, FORK]) expect((await db.tasks.get(id))?.countsTowardCounterId ?? null).toBeNull();
  });

  it('the counter-delete impact counts the unit-task lineages (a fork shares its original\'s; deleted ones excluded); the delete keeps and decouples them', async () => {
    await db.tasks.bulkAdd([
      rootTask(),
      task(DUNE, { title: 'Finish Dune', countsTowardCounterId: ROOT, countsTowardSince: T0 }),
      task(LOOSE, { title: 'Audiobook', countsTowardCounterId: ROOT, countsTowardSince: T0 }),
      task('gone', { title: 'Gone', countsTowardCounterId: ROOT, countsTowardSince: T0, isDeleted: true }),
      task('fork', { title: 'Finish Dune', countsTowardCounterId: ROOT, countsTowardSince: T0, forkedFromTaskId: DUNE }),
    ]);
    expect((await computeTaskDeletionImpact(ROOT)).unitTaskCount).toBe(2);
    expect((await loadCountsTowardSection(ROOT)).rows).toHaveLength(2);
    expect((await computeTaskDeletionImpact(DUNE)).unitTaskCount).toBe(0);

    await deleteCounterWithUnlink(ROOT);

    for (const id of [DUNE, LOOSE]) {
      const t = await db.tasks.get(id);
      expect(t?.isDeleted).toBe(false);
      expect(t?.countsTowardCounterId ?? null).toBeNull();
    }
  });
});
