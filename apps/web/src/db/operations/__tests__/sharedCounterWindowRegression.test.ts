import { afterEach, beforeEach, describe, expect, it, vi } from 'vitest';
import {
  Timeframe,
  boardWindowEnd,
  resolveLinkedCounterDisplay,
  type TaskEvent,
} from '@oybc/shared';
import { db } from '../../internal';
import { incrementSharedCounter } from '../tasks.sharedCounter';
import { buildSquareWindowContext, taskToSquareState } from '../../adapters';
import {
  JUNE,
  ROOT,
  SEPT,
  boardRow,
  clearAll,
  hubLinked,
  incEvent,
  placement,
  rootTask,
} from './linkedCounterFixtures';
import { legacyDerivedTaskId } from './legacyDerivedIds';

/**
 * The owner's scenario (2026-10-01): a +5 logged from an ENDED, unsealed
 * September core board's "run 30 miles" credited his CLOSED June board.
 *
 * Owner rule: a counting square on a board accounts ONLY for the counter's
 * logs inside that board's window. "Hub-linked" = a task with
 * `sharedCounterId` that is not window-stamped — June's row was one (made by
 * the retired "From a board…" picker), which is why the root's lifetime latch
 * moved it.
 */

const NOW = '2026-10-01T00:00:00.000Z';
const SEPT_ROW = legacyDerivedTaskId(SEPT.id, ROOT);
const SEALED_AT = '2026-07-01T00:00:00.000Z';

async function seedScenario(): Promise<void> {
  await db.tasks.put(rootTask({ currentCount: 2 }));
  await db.taskEvents.put(incEvent('e-june', ROOT, 2, '2026-06-10T00:00:00.000Z'));
  // June: SEALED, still `.active`, placing a pre-rule hub-linked copy (target 5).
  await db.tasks.put(hubLinked('H-june', { maxCount: 5, currentCount: 2 }));
  await db.boards.put(boardRow(JUNE, { sealedAt: SEALED_AT, sealedCompletedCells: [] }));
  await db.boardTasks.put(placement('bt-june', JUNE.id, 'H-june'));
  // September: ended NOW, NOT sealed, placing its own window-stamped member.
  await db.tasks.put(
    hubLinked(SEPT_ROW, {
      maxCount: 30,
      baseline: 2,
      currentCount: 2,
      createdInWizard: true,
      timeframe: Timeframe.MONTHLY,
      startDate: SEPT.startDate,
      endDate: SEPT.endDate,
    }),
  );
  await db.boards.put(boardRow(SEPT));
  await db.boardTasks.put(placement('bt-sept', SEPT.id, SEPT_ROW));
}

async function eventsByTask(): Promise<Record<string, TaskEvent[]>> {
  const out: Record<string, TaskEvent[]> = {};
  for (const e of await db.taskEvents.toArray()) (out[e.taskId] ??= []).push(e);
  return out;
}

beforeEach(async () => {
  vi.useFakeTimers({ toFake: ['Date'] });
  vi.setSystemTime(new Date(NOW));
  await seedScenario();
});

afterEach(async () => {
  vi.useRealTimers();
  await clearAll();
});

describe('a late log on an ended September board never moves the closed June board', () => {
  it('stamps at September\'s endDate, leaves June untouched, and credits no closed board', async () => {
    const juneBoardBefore = (await db.boards.get(JUNE.id))!;

    const { affectedBoards } = await incrementSharedCounter(ROOT, 5, SEPT.id);

    // The event is stamped at September's endDate (ended-board late stamp).
    const logged = (await db.taskEvents.toArray()).find((e) => e.delta === 5)!;
    expect(logged.occurredAt).toBe(SEPT.endDate);

    // Lifetime root count moved by +5.
    expect((await db.tasks.get(ROOT))!.currentCount).toBe(7);

    // June's row is a plain linked row: its lifetime cache may move (retired
    // with the propagation machinery, slice 5) but nothing reads it for June.
    const juneRow = (await db.tasks.get('H-june'))!;

    // June's DISPLAY is the in-window sum (2), bounded at its seal.
    const june = (await db.boards.get(JUNE.id))!;
    const shown = resolveLinkedCounterDisplay(juneRow, await eventsByTask(), june.sealedAt, {
      startDate: JUNE.startDate,
      endDate: JUNE.endDate,
    });
    expect(shown).toEqual({ displayed: 2, isCompleted: false });

    // June's sealed snapshot / stats are unchanged.
    expect(june.sealedCompletedCells).toEqual([]);
    expect(june.completedTasks).toBe(juneBoardBefore.completedTasks);
    expect(june.version).toBe(juneBoardBefore.version);

    // September's own square took the log.
    const sept = resolveLinkedCounterDisplay((await db.tasks.get(SEPT_ROW))!, await eventsByTask(), null, {
      startDate: SEPT.startDate,
      endDate: SEPT.endDate,
    });
    expect(sept.displayed).toBe(5);

    // Credit toast: the closed June board is never named.
    expect(affectedBoards.map((b) => b.boardId)).not.toContain(JUNE.id);
  });

  it('credit set excludes a sealed (Closed) board even when its row is not frozen', async () => {
    // An open-ended window-stamped row never freezes (`endDate` absent), so
    // only the board predicate can keep a CLOSED board out of the toast.
    const OPEN = 'board-open-sealed';
    const openRow = legacyDerivedTaskId(OPEN, ROOT);
    await db.tasks.put(
      hubLinked(openRow, {
        createdInWizard: true,
        timeframe: Timeframe.INDEFINITE,
        startDate: '2026-01-01T00:00:00.000Z',
        endDate: undefined,
      }),
    );
    await db.boards.put(
      boardRow(
        { id: OPEN, startDate: '2026-01-01T00:00:00.000Z', endDate: '' },
        { endDate: undefined, timeframe: Timeframe.INDEFINITE, sealedAt: SEALED_AT, sealedCompletedCells: [] },
      ),
    );
    await db.boardTasks.put(placement('bt-open', OPEN, openRow));

    const { affectedBoards } = await incrementSharedCounter(ROOT, 1);
    expect(affectedBoards.map((b) => b.boardId)).not.toContain(OPEN);
  });

  it('the kernel alone keeps June\'s UNSTAMPED row at 2 through the real grid path', async () => {
    // June's row is hub-linked (unstamped) with the latch the owner's device has.
    await db.tasks.put(hubLinked('H-june', { maxCount: 5, currentCount: 2, isCompleted: false }));
    await incrementSharedCounter(ROOT, 5, SEPT.id);

    const june = (await db.boards.get(JUNE.id))!;
    expect(june.sealedAt).toBe(SEALED_AT);
    const events = await db.taskEvents.toArray();
    const ctx = buildSquareWindowContext(events, june.startDate, boardWindowEnd(june));
    const tasks = await db.tasks.toArray();
    const taskMap = Object.fromEntries(tasks.map((t) => [t.id, t]));
    const state = taskToSquareState(taskMap['H-june'], [], taskMap, {}, ctx);

    expect(state.currentCount).toBe(2);
    expect(state.isCompleted).toBe(false);
  });
});
