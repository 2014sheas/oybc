import { afterEach, describe, expect, it } from 'vitest';
import type { Transaction } from 'dexie';
import { isWindowStampedDerived } from '@oybc/shared';
import { db } from '../../internal';
import { runMigrationV18 } from '../migrationV18';
import { JUNE, USER, boardRow, clearAll, hubLinked, placement, rootTask } from './linkedCounterFixtures';

/**
 * Dexie v18 — heals hub-linked counters placed on boards for every user on
 * the device. `runMigrationV18` operates on the raw Dexie singleton, so it is
 * driven directly with a passthrough transaction handle (same pattern as
 * `migrationV16.test.ts`).
 */

afterEach(clearAll);

describe('migrationV18 — windowed linked counters heal', () => {
  it('stamps hub-linked rows for every user present in db.users, and is idempotent', async () => {
    await db.users.bulkPut([
      { id: USER, email: 'a@b.c', createdAt: JUNE.startDate, updatedAt: JUNE.startDate, version: 1, isDeleted: false },
      { id: 'user-2', email: 'd@e.f', createdAt: JUNE.startDate, updatedAt: JUNE.startDate, version: 1, isDeleted: false },
    ] as never);
    await db.tasks.bulkPut([rootTask(), hubLinked('H')]);
    await db.boards.put(boardRow(JUNE));
    await db.boardTasks.put(placement('bt-j', JUNE.id, 'H'));

    await runMigrationV18({} as Transaction);
    const h = (await db.tasks.get('H'))!;
    expect(isWindowStampedDerived(h)).toBe(true);
    expect(h.startDate).toBe(JUNE.startDate);
    const version = h.version;

    await runMigrationV18({} as Transaction);
    expect((await db.tasks.get('H'))!.version).toBe(version);
  });

  it('is a no-op on an empty database', async () => {
    await expect(runMigrationV18({} as Transaction)).resolves.toBeUndefined();
  });
});
