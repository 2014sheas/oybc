import { afterEach, describe, expect, it } from 'vitest';
import {
  CenterSquareType,
  Timeframe,
  TaskType,
  computeBoardStatsUpdate,
  type CompoundChild,
  type RecurringBoardTemplate,
  type Task,
  type TaskEvent,
} from '@oybc/shared';
import { db } from '../../internal';
import { spawnTemplateBoard } from '../recurringBoardSpawn';
import { runBoardCascadeForTask } from '../orchestration';
import { taskToSquareState } from '../../adapters';

/**
 * Windowed Completion (docs/WINDOWED_COMPLETION.md §What this closes — respawn
 * bleed) — THE original bug's regression test. `spawnTemplateBoard` places the
 * SAME task ids from the template's pool (no clone, no reset). Before windowed
 * completion, a "daily workout" completed Monday would spawn Tuesday's board
 * pre-greenlogged because the tasks' lifetime `isCompleted` was still true.
 *
 * With events, the new window's board starts EMPTY because no event has
 * `occurredAt >= newWindow.startDate` — the previous window's completion
 * events fall before it.
 */

// A 3×3 FREE-center board needs 8 pool tasks.
const POOL_SIZE = 8;
const PREV_WINDOW_COMPLETE = '2026-05-05T12:00:00.000Z'; // Monday
const NEW_WINDOW_START = '2026-05-06T00:00:00.000Z'; // Tuesday
const NEW_WINDOW_END = '2026-05-06T23:59:59.999Z';

async function seedPoolTaskWithPriorCompletion(i: number): Promise<string> {
  const id = `pool-task-${i}`;
  const task: Task = {
    id,
    userId: 'user-1',
    title: `Workout ${i}`,
    type: TaskType.NORMAL,
    // Lifetime cache says COMPLETE (Monday's greenlog) — this is exactly the
    // stale bit the bleed bug read.
    isCompleted: true,
    completedAt: PREV_WINDOW_COMPLETE,
    totalCompletions: 1,
    totalInstances: 1,
    createdAt: '2026-05-01T00:00:00.000Z',
    updatedAt: PREV_WINDOW_COMPLETE,
    version: 2,
    isDeleted: false,
  };
  await db.tasks.add(task);
  const event: TaskEvent = {
    id: `evt-${id}`,
    userId: 'user-1',
    taskId: id,
    kind: 'completion',
    occurredAt: PREV_WINDOW_COMPLETE, // BEFORE the new window
    createdAt: PREV_WINDOW_COMPLETE,
    updatedAt: PREV_WINDOW_COMPLETE,
    version: 1,
    isDeleted: false,
  };
  await db.taskEvents.add(event);
  return id;
}

afterEach(async () => {
  await db.tasks.clear();
  await db.boards.clear();
  await db.boardTasks.clear();
  await db.recurringBoardTemplates.clear();
  await db.taskEvents.clear();
  await db.syncQueue.clear();
});

describe('Windowed Completion — respawn bleed regression', () => {
  it('a template board spawned into a NEW window starts empty even though its tasks are lifetime-complete', async () => {
    const seedTaskIds: string[] = [];
    for (let i = 0; i < POOL_SIZE; i += 1) {
      seedTaskIds.push(await seedPoolTaskWithPriorCompletion(i));
    }

    const template: RecurringBoardTemplate = {
      id: 'tmpl-1',
      userId: 'user-1',
      name: 'Daily Workout',
      timeframe: Timeframe.DAILY,
      boardSize: 3,
      centerSquareType: CenterSquareType.FREE,
      isRandomized: false,
      seedTaskIds,
      lastSpawnedWindowKey: null,
      isActive: true,
      createdAt: '2026-05-01T00:00:00.000Z',
      updatedAt: '2026-05-01T00:00:00.000Z',
      version: 1,
      isDeleted: false,
    };
    await db.recurringBoardTemplates.add(template);

    const result = await spawnTemplateBoard({
      template,
      windowStart: NEW_WINDOW_START,
      windowEnd: NEW_WINDOW_END,
      suggestedName: 'Daily Workout — May 6',
    });
    expect(result.ok).toBe(true);
    if (!result.ok) return;

    // Run the derivation pass for a placed task — the board must stay empty:
    // every completion event is BEFORE the new window's start.
    await db.transaction(
      'rw',
      [db.boards, db.boardTasks, db.tasks, db.compoundChildren, db.taskEvents, db.syncQueue],
      async () => {
        await runBoardCascadeForTask(seedTaskIds[0]);
      },
    );

    const board = await db.boards.get(result.boardId);
    // Only the FREE center auto-fills (1), NOT the 8 bled-green task squares.
    expect(board?.completedTasks).toBe(1);

    // The grid read (taskToSquareState) also renders each placed task grey,
    // despite its lifetime `isCompleted === true`.
    const events = (await db.taskEvents.toArray()).filter((e) => !e.isDeleted);
    const eventsByTaskId: Record<string, TaskEvent[]> = {};
    for (const e of events) (eventsByTaskId[e.taskId] ??= []).push(e);
    const windowContext = { windowStart: NEW_WINDOW_START, eventsByTaskId };

    for (const id of seedTaskIds) {
      const task = await db.tasks.get(id);
      expect(task?.isCompleted).toBe(true); // lifetime cache still complete
      const state = taskToSquareState(task!, undefined, {}, {}, windowContext);
      expect(state.isCompleted).toBe(false); // windowed square is EMPTY
    }
  });

  it('spawn-time derivation pass — stored board stats equal derivation output (no separate cascade needed)', async () => {
    const seedTaskIds: string[] = [];
    for (let i = 0; i < POOL_SIZE; i += 1) {
      seedTaskIds.push(await seedPoolTaskWithPriorCompletion(i));
    }

    const template: RecurringBoardTemplate = {
      id: 'tmpl-2',
      userId: 'user-1',
      name: 'Daily Workout',
      timeframe: Timeframe.DAILY,
      boardSize: 3,
      centerSquareType: CenterSquareType.FREE,
      isRandomized: false,
      seedTaskIds,
      lastSpawnedWindowKey: null,
      isActive: true,
      createdAt: '2026-05-01T00:00:00.000Z',
      updatedAt: '2026-05-01T00:00:00.000Z',
      version: 1,
      isDeleted: false,
    };
    await db.recurringBoardTemplates.add(template);

    const result = await spawnTemplateBoard({
      template,
      windowStart: NEW_WINDOW_START,
      windowEnd: NEW_WINDOW_END,
      suggestedName: 'Daily Workout — May 6',
    });
    expect(result.ok).toBe(true);
    if (!result.ok) return;

    // Read the persisted board + its placements straight out of the DB — NO
    // cascade run in between. The invariant under test: the spawn path itself
    // wrote derivation output, so a fresh recomputation matches byte-for-byte.
    const board = await db.boards.get(result.boardId);
    expect(board).toBeDefined();
    const boardTasks = await db.boardTasks.where('boardId').equals(result.boardId).toArray();
    const allChildren = (await db.compoundChildren.toArray()).filter((c) => !c.isDeleted);
    const childrenByCompound: Record<string, CompoundChild[]> = {};
    for (const c of allChildren) (childrenByCompound[c.compoundTaskId] ??= []).push(c);
    const taskById: Record<string, Task> = {};
    for (const t of await db.tasks.toArray()) taskById[t.id] = t;
    const events = (await db.taskEvents.toArray()).filter((e) => !e.isDeleted);
    const eventsByTaskId: Record<string, TaskEvent[]> = {};
    for (const e of events) (eventsByTaskId[e.taskId] ??= []).push(e);
    const allBoards = await db.boards.toArray();

    const derived = computeBoardStatsUpdate(
      board!,
      boardTasks,
      childrenByCompound,
      taskById,
      allBoards,
      { eventsByTaskId },
    );

    expect(board!.completedTasks).toBe(derived.completedTasks);
    expect(board!.linesCompleted).toBe(derived.linesCompleted);
    expect(board!.completedLineIds ?? []).toEqual(derived.completedLineIds);
    // Fresh window: only the FREE center, no bled task squares.
    expect(board!.completedTasks).toBe(1);
    expect(board!.linesCompleted).toBe(0);
  });
});
