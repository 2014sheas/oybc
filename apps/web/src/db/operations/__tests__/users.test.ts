import { afterEach, describe, expect, it } from 'vitest';
import { DEFAULT_USER_PREFERENCES, type User } from '@oybc/shared';
import { db } from '../../internal';
import { updateUserPreferences } from '../users';

/**
 * `updateUserPreferences` — the 3×3 new-user default (Track L, 2026-10-18).
 * A stored `defaultBoardSize` is the user's explicit value and survives any
 * unrelated preference write; only a record MISSING the field (no
 * `preferences` at all, or a payload from before the field existed) picks
 * up the new 3×3 default.
 */

const USER_ID = 'user-1';
const TS = '2026-10-18T12:00:00.000Z';

/**
 * Seed one user row.
 *
 * @param preferences - The stored preferences payload; omitted = a
 *   pre-preferences record with no `preferences` field at all.
 */
async function seedUser(preferences?: Record<string, unknown>): Promise<void> {
  const user = {
    id: USER_ID,
    email: 'u@example.com',
    createdAt: TS,
    updatedAt: TS,
    version: 1,
    ...(preferences ? { preferences } : {}),
  } as User;
  await db.users.put(user);
}

afterEach(async () => {
  await db.users.clear();
  await db.syncQueue.clear();
});

describe('updateUserPreferences — defaultBoardSize', () => {
  it('gives a record with no preferences the 3×3 default', async () => {
    await seedUser();
    const updated = await updateUserPreferences(USER_ID, { weekStartDay: 'sunday' });
    expect(updated?.preferences?.defaultBoardSize).toBe(3);
  });

  it('gives a payload missing the field the 3×3 default', async () => {
    const legacy: Record<string, unknown> = { ...DEFAULT_USER_PREFERENCES };
    delete legacy.defaultBoardSize;
    await seedUser(legacy);
    const updated = await updateUserPreferences(USER_ID, { theme: 'dark' });
    expect(updated?.preferences?.defaultBoardSize).toBe(3);
  });

  it('keeps a stored 5×5 through an unrelated write', async () => {
    await seedUser({ ...DEFAULT_USER_PREFERENCES, defaultBoardSize: 5 });
    const updated = await updateUserPreferences(USER_ID, { theme: 'dark' });
    expect(updated?.preferences?.defaultBoardSize).toBe(5);
    expect((await db.users.get(USER_ID))?.preferences?.defaultBoardSize).toBe(5);
  });
});
