import { afterEach, describe, expect, it } from 'vitest';
import { DEFAULT_USER_PREFERENCES, mergeUserPreferences, type TutorialProgress, type User } from '@oybc/shared';
import { db } from '../../internal';
import { fetchUser, updateUserPreferences } from '../users';

/**
 * The iOS tutorial board stores its progress inside the user's synced
 * `preferences` (`tutorialProgress`). Web has no tutorial UI, so the contract is
 * a clean round trip: no preference write on web may drop or corrupt it.
 */

const USER_ID = 'user-1';
const PROGRESS: TutorialProgress = {
  lessons: {
    createTask: { status: 'done' },
    createBoard: { status: 'inProgress', step: 3 },
    someFutureLesson: { status: 'done' },
  },
  cardDismissed: true,
};

async function seedUser(tutorialProgress?: TutorialProgress): Promise<void> {
  const user: User = {
    id: USER_ID,
    email: 'a@example.com',
    preferences: { ...DEFAULT_USER_PREFERENCES, ...(tutorialProgress ? { tutorialProgress } : {}) },
    createdAt: '2026-01-01T00:00:00.000Z',
    updatedAt: '2026-01-01T00:00:00.000Z',
    version: 1,
  };
  await db.users.put(user);
}

afterEach(async () => {
  await db.users.clear();
  await db.syncQueue.clear();
});

describe('tutorialProgress round trip through preference writes', () => {
  it('survives an unrelated preference update untouched', async () => {
    await seedUser(PROGRESS);
    await updateUserPreferences(USER_ID, { theme: 'dark' });
    const stored = (await fetchUser(USER_ID))?.preferences;
    expect(stored?.theme).toBe('dark');
    expect(stored?.tutorialProgress).toEqual(PROGRESS);
  });

  it('is queued for sync with the user document', async () => {
    await seedUser(PROGRESS);
    await updateUserPreferences(USER_ID, { theme: 'light' });
    const queued = await db.syncQueue.toArray();
    expect(queued).toHaveLength(1);
    expect(queued[0].entityType).toBe('users');
    const payload = JSON.parse(queued[0].payload as unknown as string) as {
      preferences: { tutorialProgress: TutorialProgress };
    };
    expect(payload.preferences.tutorialProgress).toEqual(PROGRESS);
  });

  it('a user row without the field gets the empty default', async () => {
    await seedUser();
    await updateUserPreferences(USER_ID, { theme: 'dark' });
    expect((await fetchUser(USER_ID))?.preferences?.tutorialProgress).toEqual({ lessons: {}, cardDismissed: false });
  });

  it('a pulled document with a malformed lesson keeps the good ones', () => {
    const merged = mergeUserPreferences({
      ...DEFAULT_USER_PREFERENCES,
      tutorialProgress: {
        lessons: { good: { status: 'done' }, bad: { status: 'inProgress' } },
        cardDismissed: false,
      } as unknown as TutorialProgress,
    });
    expect(merged.tutorialProgress.lessons).toEqual({ good: { status: 'done' } });
  });
});
