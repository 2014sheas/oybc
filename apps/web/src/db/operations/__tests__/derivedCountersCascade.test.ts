import { afterEach, describe, expect, it } from 'vitest';
import {
  BoardStatus,
  CenterSquareType,
  OperatorType,
  SyncOperationType,
  derivedTaskId,
  TaskType,
  Timeframe,
  type Board,
  type BoardTask,
  type CompoundChild,
  type Task,
} from '@oybc/shared';
import { db } from '../../internal';
import {
  softDeleteWindowStampedDerived,
  windowStampedDerivedIdsForRoot,
  windowStampedDerivedOrphanedByBoard,
} from '../derivedCounters';
import { deleteBoard } from '../boards';

/**
 * Board Sources §Member rules B2 (web) — the *Deletion* half.
 *
 * A window-stamped derived counter is a per-window artifact of the board it
 * was minted for: it is not library content the user authored, so when its
 * root is deleted (or the last board carrying it goes away) it must be
 * retired outright rather than unlinked and left behind as a mystery row.
 * These tests pin the three write rulings that the pure algorithms cannot
 * express: every tombstone bumps `version` AND enqueues its own sync item
 * (a soft-delete helper that forgets the enqueue resurrects the row on the
 * next pull), the placements/links go with the task, and RB5's "live
 * placement" definition (a live `board_tasks` row on a live board) decides
 * whether a derived row survives its board's deletion.
 */

const USER = 'user-1';
const NOW = '2026-09-18T10:00:00.000';
const WINDOW_START = '2026-09-14T00:00:00.000';
const EARLIER = '2026-09-14T08:00:00.000';

const ROOT = 'root-counter-1';

function uuid(n: number): string {
  return `70000000-0000-4000-8000-${String(n).padStart(12, '0')}`;
}

afterEach(async () => {
  await db.tasks.clear();
  await db.boards.clear();
  await db.boardTasks.clear();
  await db.compoundChildren.clear();
  await db.taskEvents.clear();
  await db.syncQueue.clear();
});

/** A stored row with all three `isWindowStampedDerived` marks. */
function derivedCounter(id: string, over: Partial<Task> = {}): Task {
  return {
    id,
    userId: USER,
    title: 'Run 5 km',
    type: TaskType.COUNTING,
    action: 'Run',
    unit: 'km',
    maxCount: 5,
    sharedCounterId: ROOT,
    baseline: 0,
    currentCount: 0,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdInWizard: true,
    timeframe: Timeframe.WEEKLY,
    startDate: WINDOW_START,
    createdAt: EARLIER,
    updatedAt: EARLIER,
    version: 1,
    isDeleted: false,
    ...over,
  } as Task;
}

/** A per-window derived COMPOUND (no `sharedCounterId`; the other two marks). */
function derivedCompound(id: string, over: Partial<Task> = {}): Task {
  return {
    id,
    userId: USER,
    title: 'Strength circuit',
    type: TaskType.COMPOUND,
    operator: OperatorType.AND,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdInWizard: true,
    timeframe: Timeframe.WEEKLY,
    startDate: WINDOW_START,
    createdAt: EARLIER,
    updatedAt: EARLIER,
    version: 1,
    isDeleted: false,
    ...over,
  } as Task;
}

function plainTask(id: string, over: Partial<Task> = {}): Task {
  return {
    id,
    userId: USER,
    title: 'Plain',
    type: TaskType.NORMAL,
    isCompleted: false,
    totalCompletions: 0,
    totalInstances: 0,
    createdAt: EARLIER,
    updatedAt: EARLIER,
    version: 1,
    isDeleted: false,
    ...over,
  } as Task;
}

async function seedBoard(id: string, over: Partial<Board> = {}): Promise<Board> {
  const board: Board = {
    id,
    userId: USER,
    name: 'Week board',
    status: BoardStatus.ACTIVE,
    boardSize: 3,
    timeframe: Timeframe.WEEKLY,
    startDate: WINDOW_START,
    centerSquareType: CenterSquareType.NONE,
    isRandomized: false,
    totalTasks: 9,
    completedTasks: 0,
    linesCompleted: 0,
    createdAt: EARLIER,
    updatedAt: EARLIER,
    version: 1,
    isDeleted: false,
    ...over,
  };
  await db.boards.add(board);
  return board;
}

async function seedPlacement(
  id: string,
  boardId: string,
  taskId: string,
  over: Partial<BoardTask> = {},
): Promise<void> {
  const bt: BoardTask = {
    id,
    boardId,
    taskId,
    row: 0,
    col: 0,
    isCenter: false,
    createdAt: EARLIER,
    updatedAt: EARLIER,
    version: 1,
    isDeleted: false,
    ...over,
  };
  await db.boardTasks.add(bt);
}

async function seedLink(id: string, compoundTaskId: string, childTaskId: string): Promise<void> {
  const link: CompoundChild = {
    id,
    compoundTaskId,
    childTaskId,
    childIndex: 0,
    createdAt: EARLIER,
    updatedAt: EARLIER,
    version: 1,
    isDeleted: false,
  };
  await db.compoundChildren.add(link);
}

async function queueFor(entityType: string, entityId: string) {
  return (await db.syncQueue.toArray()).filter(
    (i) => i.entityType === entityType && i.entityId === entityId,
  );
}

async function runCascade(ids: string[]): Promise<number> {
  return db.transaction(
    'rw',
    [db.tasks, db.boardTasks, db.compoundChildren, db.syncQueue],
    async () => softDeleteWindowStampedDerived(ids, NOW),
  );
}

describe('softDeleteWindowStampedDerived', () => {
  it('tombstones the task, its live placements and its links — each version+1 with its own sync row', async () => {
    const derived = derivedCounter(uuid(1), { version: 3 });
    await db.tasks.add(derived);
    await seedBoard(uuid(100));
    await seedPlacement(uuid(200), uuid(100), derived.id, { version: 2 });
    // The derived counter is also a part of a derived compound (the
    // One-square seam) — that link goes with it.
    await db.tasks.add(derivedCompound(uuid(2)));
    await seedLink(uuid(300), uuid(2), derived.id);

    const count = await runCascade([derived.id]);
    expect(count).toBe(1);

    const task = await db.tasks.get(derived.id);
    expect(task?.isDeleted).toBe(true);
    expect(task?.deletedAt).toBe(NOW);
    expect(task?.updatedAt).toBe(NOW);
    expect(task?.version).toBe(4);
    const taskQueue = await queueFor('tasks', derived.id);
    expect(taskQueue).toHaveLength(1);
    expect(taskQueue[0].operationType).toBe(SyncOperationType.DELETE);

    const placement = await db.boardTasks.get(uuid(200));
    expect(placement?.isDeleted).toBe(true);
    expect(placement?.version).toBe(3);
    expect(await queueFor('boardTasks', uuid(200))).toHaveLength(1);

    const link = await db.compoundChildren.get(uuid(300));
    expect(link?.isDeleted).toBe(true);
    expect(link?.version).toBe(2);
    expect(await queueFor('compoundChildren', uuid(300))).toHaveLength(1);
  });

  it('tombstones a derived compound’s own parent links too', async () => {
    const compound = derivedCompound(uuid(3));
    await db.tasks.add(compound);
    await db.tasks.add(derivedCounter(uuid(4)));
    await seedLink(uuid(301), compound.id, uuid(4));

    await runCascade([compound.id]);

    expect((await db.compoundChildren.get(uuid(301)))?.isDeleted).toBe(true);
    // The child row itself is NOT touched by the parent's retirement.
    expect((await db.tasks.get(uuid(4)))?.isDeleted).toBe(false);
  });

  it('is idempotent — a missing or already-tombstoned id writes nothing and is not counted', async () => {
    const derived = derivedCounter(uuid(5), { isDeleted: true, deletedAt: EARLIER, version: 9 });
    await db.tasks.add(derived);

    const count = await runCascade([derived.id, 'no-such-task']);

    expect(count).toBe(0);
    expect((await db.tasks.get(derived.id))?.version).toBe(9);
    expect(await db.syncQueue.toArray()).toHaveLength(0);
  });
});

describe('windowStampedDerivedIdsForRoot', () => {
  it('returns only the live rows carrying all three marks', async () => {
    await db.tasks.add(derivedCounter(uuid(6)));
    await db.tasks.add(derivedCounter(uuid(7), { isDeleted: true }));
    // A hand-made linked counter: shares the index, has no window stamp.
    await db.tasks.add(derivedCounter(uuid(8), { startDate: undefined, createdInWizard: undefined }));
    // A window-stamped derived counter of a DIFFERENT root.
    await db.tasks.add(derivedCounter(uuid(9), { sharedCounterId: 'other-root' }));

    expect(await windowStampedDerivedIdsForRoot(ROOT)).toEqual([uuid(6)]);
  });
});
describe('windowStampedDerivedOrphanedByBoard + deleteBoard (RB5)', () => {
  /**
   * A derived counter's id IS `derivedTaskId(boardId, root)` — that is what
   * makes it THIS board's artifact — so the fixtures mint real ids rather
   * than arbitrary ones. Anything else is another board's row that merely
   * left a placement behind here, and must survive this board's deletion.
   */
  function mintedCounter(boardId: string, rootId: string, over: Partial<Task> = {}): Task {
    return derivedCounter(derivedTaskId(boardId, rootId), { sharedCounterId: rootId, ...over });
  }

  it('soft-deletes a derived task placed only on the deleted board, with sync rows', async () => {
    const board = await seedBoard(uuid(101));
    const derived = mintedCounter(board.id, ROOT);
    await db.tasks.add(derived);
    await seedPlacement(uuid(201), board.id, derived.id);

    await deleteBoard(board.id);

    expect((await db.boards.get(board.id))?.isDeleted).toBe(true);
    const task = await db.tasks.get(derived.id);
    expect(task?.isDeleted).toBe(true);
    expect(task?.version).toBe(2);
    expect(await queueFor('tasks', derived.id)).toHaveLength(1);
    expect((await db.boardTasks.get(uuid(201)))?.isDeleted).toBe(true);
  });

  it('KEEPS a derived task that still has a live placement on another live board', async () => {
    const board = await seedBoard(uuid(102));
    const otherBoard = await seedBoard(uuid(103));
    const derived = mintedCounter(board.id, ROOT);
    await db.tasks.add(derived);
    await seedPlacement(uuid(202), board.id, derived.id);
    await seedPlacement(uuid(203), otherBoard.id, derived.id);

    await deleteBoard(board.id);

    const task = await db.tasks.get(derived.id);
    expect(task?.isDeleted).toBe(false);
    expect(task?.version).toBe(1);
    // The surviving placement is untouched too.
    expect((await db.boardTasks.get(uuid(203)))?.isDeleted).toBe(false);
  });

  it('cascades when the only other placement sits on an already-DELETED board (a tombstoned board holds nothing alive)', async () => {
    const board = await seedBoard(uuid(104));
    await seedBoard(uuid(105), { isDeleted: true, deletedAt: EARLIER });
    const derived = mintedCounter(board.id, ROOT);
    await db.tasks.add(derived);
    await seedPlacement(uuid(204), board.id, derived.id);
    await seedPlacement(uuid(205), uuid(105), derived.id);

    await deleteBoard(board.id);

    expect((await db.tasks.get(derived.id))?.isDeleted).toBe(true);
  });

  it('leaves ordinary library tasks (and hand-made linked counters) on the board alone', async () => {
    const board = await seedBoard(uuid(106));
    await db.tasks.add(plainTask(uuid(13)));
    await db.tasks.add(derivedCounter(uuid(14), { startDate: undefined, createdInWizard: undefined }));
    await seedPlacement(uuid(206), board.id, uuid(13));
    await seedPlacement(uuid(207), board.id, uuid(14));

    await deleteBoard(board.id);

    expect((await db.tasks.get(uuid(13)))?.isDeleted).toBe(false);
    expect((await db.tasks.get(uuid(14)))?.isDeleted).toBe(false);
    expect(await windowStampedDerivedOrphanedByBoard(board.id)).toEqual([]);
  });

  it('retires a per-window derived COMPOUND placed on the deleted board, its links, and its unplaced derived PARTS — but not an original child', async () => {
    // The One-square seam: a derived compound's parts have no placement of
    // their own, so nothing in `board_tasks` reaches them. Left behind, each
    // would be a per-window row with no board that keeps collecting baseline
    // refreshes — and the root-delete path retires them, so the two deletion
    // paths would disagree.
    const board = await seedBoard(uuid(107));
    const compound = derivedCompound(uuid(15));
    const part = mintedCounter(board.id, ROOT);
    await db.tasks.add(compound);
    await db.tasks.add(part);
    // An ORIGINAL child (the user's own task, no window stamp) — untouched.
    await db.tasks.add(plainTask(uuid(17)));
    await seedLink(uuid(302), compound.id, part.id);
    await seedLink(uuid(303), compound.id, uuid(17));
    await seedPlacement(uuid(208), board.id, compound.id);

    await deleteBoard(board.id);

    expect((await db.tasks.get(compound.id))?.isDeleted).toBe(true);
    expect((await db.compoundChildren.get(uuid(302)))?.isDeleted).toBe(true);
    expect((await db.compoundChildren.get(uuid(303)))?.isDeleted).toBe(true);

    const retiredPart = await db.tasks.get(part.id);
    expect(retiredPart?.isDeleted).toBe(true);
    expect(retiredPart?.version).toBe(2);
    expect(await queueFor('tasks', part.id)).toHaveLength(1);

    const original = await db.tasks.get(uuid(17));
    expect(original?.isDeleted).toBe(false);
    expect(original?.version).toBe(1);
    expect(await queueFor('tasks', uuid(17))).toHaveLength(0);
  });

  it('KEEPS a derived part that another live compound still holds, or that is placed on a live board', async () => {
    const board = await seedBoard(uuid(108));
    const otherBoard = await seedBoard(uuid(109));
    const compound = derivedCompound(uuid(18));
    await db.tasks.add(compound);
    // Part A is also a child of a plain compound that is not being retired.
    const partA = mintedCounter(board.id, ROOT);
    await db.tasks.add(partA);
    await db.tasks.add(derivedCompound(uuid(20), { startDate: undefined, createdInWizard: undefined }));
    await seedLink(uuid(304), compound.id, partA.id);
    await seedLink(uuid(305), uuid(20), partA.id);
    // Part B has its own live placement on another live board.
    const partB = mintedCounter(board.id, 'root-counter-2');
    await db.tasks.add(partB);
    await seedLink(uuid(306), compound.id, partB.id);
    await seedPlacement(uuid(209), otherBoard.id, partB.id);
    await seedPlacement(uuid(210), board.id, compound.id);

    await deleteBoard(board.id);

    expect((await db.tasks.get(compound.id))?.isDeleted).toBe(true);
    // Both parts survive; only the retired compound's own link to each goes.
    expect((await db.tasks.get(partA.id))?.isDeleted).toBe(false);
    expect((await db.compoundChildren.get(uuid(305)))?.isDeleted).toBe(false);
    expect((await db.tasks.get(partB.id))?.isDeleted).toBe(false);
    expect((await db.boardTasks.get(uuid(209)))?.isDeleted).toBe(false);
  });

  it('keeps a derived compound (and its parts) that is still placed on another live board', async () => {
    const board = await seedBoard(uuid(110));
    const otherBoard = await seedBoard(uuid(111));
    const compound = derivedCompound(uuid(22));
    const part = mintedCounter(board.id, ROOT);
    await db.tasks.add(compound);
    await db.tasks.add(part);
    await seedLink(uuid(307), compound.id, part.id);
    await seedPlacement(uuid(211), board.id, compound.id);
    await seedPlacement(uuid(212), otherBoard.id, compound.id);

    await deleteBoard(board.id);

    expect((await db.tasks.get(compound.id))?.isDeleted).toBe(false);
    expect((await db.tasks.get(part.id))?.isDeleted).toBe(false);
    expect((await db.compoundChildren.get(uuid(307)))?.isDeleted).toBe(false);
  });

  it('gives the same answer whether or not the board’s own placements are pre-tombstoned (RB5 ordering)', async () => {
    // `deleteBoard` does not tombstone its own placements today. If it ever
    // does, this sweep must not care where in the sequence it runs — a
    // live-only candidate query would quietly find nothing and retire
    // nothing, which no other test here would catch.
    const board = await seedBoard(uuid(112));
    const derived = mintedCounter(board.id, ROOT);
    const compound = derivedCompound(uuid(25));
    const part = mintedCounter(board.id, 'root-counter-3');
    await db.tasks.add(derived);
    await db.tasks.add(compound);
    await db.tasks.add(part);
    await seedLink(uuid(308), compound.id, part.id);
    await seedPlacement(uuid(213), board.id, derived.id);
    await seedPlacement(uuid(214), board.id, compound.id);

    const before = [...(await windowStampedDerivedOrphanedByBoard(board.id))].sort();

    // Now tombstone this board's own placements first, as a future
    // `deleteBoard` might, and ask again.
    await db.boardTasks.update(uuid(213), { isDeleted: true, deletedAt: NOW });
    await db.boardTasks.update(uuid(214), { isDeleted: true, deletedAt: NOW });
    const after = [...(await windowStampedDerivedOrphanedByBoard(board.id))].sort();

    expect(before).toEqual([derived.id, compound.id, part.id].sort());
    expect(after).toEqual(before);
  });

  it('does NOT cascade a row minted for ANOTHER board that only left a stale tombstoned placement here', async () => {
    // Board Edit's `removeBoardTaskFromBoard` tombstones a single cell. A
    // derived counter minted for board TWO that once passed through board ONE
    // is board TWO's artifact: its id encodes TWO, and ONE's deletion has no
    // claim on it — even though it is currently placed nowhere live.
    const one = await seedBoard(uuid(113));
    const two = await seedBoard(uuid(114));
    const foreign = mintedCounter(two.id, ROOT);
    await db.tasks.add(foreign);
    await seedPlacement(uuid(215), one.id, foreign.id, { isDeleted: true, deletedAt: EARLIER });

    expect(await windowStampedDerivedOrphanedByBoard(one.id)).toEqual([]);

    await deleteBoard(one.id);

    const task = await db.tasks.get(foreign.id);
    expect(task?.isDeleted).toBe(false);
    expect(task?.version).toBe(1);
    expect(await queueFor('tasks', foreign.id)).toHaveLength(0);
  });

  it('DOES cascade a row minted for THIS board that was swapped out of it (stale tombstoned placement, live nowhere)', async () => {
    // Same stale-placement shape, opposite provenance: this row was minted
    // for the board being deleted, so it can never legitimately belong to
    // another board — a swap-out left it dangling, and the deletion collects
    // it.
    const board = await seedBoard(uuid(115));
    const swappedOut = mintedCounter(board.id, ROOT);
    await db.tasks.add(swappedOut);
    await seedPlacement(uuid(216), board.id, swappedOut.id, { isDeleted: true, deletedAt: EARLIER });

    expect(await windowStampedDerivedOrphanedByBoard(board.id)).toEqual([swappedOut.id]);

    await deleteBoard(board.id);

    const task = await db.tasks.get(swappedOut.id);
    expect(task?.isDeleted).toBe(true);
    expect(task?.version).toBe(2);
    expect(await queueFor('tasks', swappedOut.id)).toHaveLength(1);
  });

  // ── The compound fallback branch, driven in BOTH directions ────────────
  //
  // `isMintedForBoard`'s compound half takes an early `true` only when a
  // CONFIRMING child is present — a child that IS this board's derived
  // counter. With no such child the answer falls through to "does the
  // compound itself have a live placement elsewhere?", and every other
  // compound test above takes the early path. These two pin the fallback.

  it('KEEPS a window-matching derived compound with only ORIGINAL children when the compound itself is placed on another live board', async () => {
    const board = await seedBoard(uuid(117));
    const otherBoard = await seedBoard(uuid(118));
    const compound = derivedCompound(uuid(28));
    // Original children only — no derived counter to confirm provenance, so
    // the decision is the fallback's alone.
    const original = plainTask('original-child-1');
    await db.tasks.add(compound);
    await db.tasks.add(original);
    await seedLink(uuid(310), compound.id, original.id);
    await seedPlacement(uuid(218), board.id, compound.id);
    await seedPlacement(uuid(219), otherBoard.id, compound.id);

    expect(await windowStampedDerivedOrphanedByBoard(board.id)).toEqual([]);

    await deleteBoard(board.id);

    expect((await db.tasks.get(compound.id))?.isDeleted).toBe(false);
    expect((await db.compoundChildren.get(uuid(310)))?.isDeleted).toBe(false);
  });

  it('retires that same compound when only a CHILD is placed elsewhere — a child placement is not the compound’s', async () => {
    // The opposite direction, and the distinction that matters: the fallback
    // reads the COMPOUND's own placements. A child of it living on another
    // live board says nothing about whose artifact the compound is, so the
    // window-matching compound is still this board's and still retires.
    const board = await seedBoard(uuid(119));
    const otherBoard = await seedBoard(uuid(120));
    const compound = derivedCompound(uuid(29));
    const original = plainTask('original-child-2');
    await db.tasks.add(compound);
    await db.tasks.add(original);
    await seedLink(uuid(311), compound.id, original.id);
    await seedPlacement(uuid(220), board.id, compound.id);
    await seedPlacement(uuid(221), otherBoard.id, original.id);

    expect(await windowStampedDerivedOrphanedByBoard(board.id)).toEqual([compound.id]);

    await deleteBoard(board.id);

    expect((await db.tasks.get(compound.id))?.isDeleted).toBe(true);
    // The ORIGINAL child is library content and survives untouched.
    expect((await db.tasks.get(original.id))?.isDeleted).toBe(false);
  });

  it('does NOT cascade a derived compound stamped for a different window', async () => {
    const board = await seedBoard(uuid(116));
    // Same board, different window — last window's compound, whatever left
    // the stale placement behind.
    const stale = derivedCompound(uuid(27), { startDate: '2026-09-07T00:00:00.000' });
    await db.tasks.add(stale);
    await db.tasks.add(mintedCounter(board.id, ROOT));
    await seedLink(uuid(309), stale.id, derivedTaskId(board.id, ROOT));
    await seedPlacement(uuid(217), board.id, stale.id, { isDeleted: true, deletedAt: EARLIER });

    await deleteBoard(board.id);

    expect((await db.tasks.get(stale.id))?.isDeleted).toBe(false);
  });
});
