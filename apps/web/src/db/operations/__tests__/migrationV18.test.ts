import { afterEach, describe, expect, it } from 'vitest';
import type { Transaction } from 'dexie';
import { db } from '../../internal';
import { runMigrationV18 } from '../migrationV18';
import { runMigrationV20 } from '../migrationV20';
import { JUNE, USER, boardRow, clearAll, hubLinked, placement, queued, rootTask } from './linkedCounterFixtures';

/**
 * Dexie v18 / v20 — the windowed-linked-counter heal is RETIRED
 * (TASK_WINDOW_REWORK slice 3a): both migrations stay registered at their
 * version as no-ops (the slice-4 sweep repoints stamped rows), so a hub-linked
 * row placed on a board is left exactly as it is.
 */

afterEach(clearAll);

describe('migrationV18 / V20 — retired heal', () => {
  it('leaves a hub-linked placed row untouched and enqueues nothing', async () => {
    await db.users.put(
      { id: USER, email: 'a@b.c', createdAt: JUNE.startDate, updatedAt: JUNE.startDate, version: 1, isDeleted: false } as never,
    );
    await db.tasks.bulkPut([rootTask(), hubLinked('H')]);
    await db.boards.put(boardRow(JUNE));
    await db.boardTasks.put(placement('bt-j', JUNE.id, 'H'));
    const before = (await db.tasks.get('H'))!;

    await runMigrationV18({} as Transaction);
    await runMigrationV20({} as Transaction);

    expect(await db.tasks.get('H')).toEqual(before);
    expect(await queued('tasks')).toEqual([]);
  });

  it('is a no-op on an empty database', async () => {
    await expect(runMigrationV18({} as Transaction)).resolves.toBeUndefined();
    await expect(runMigrationV20({} as Transaction)).resolves.toBeUndefined();
  });
});
