import {
  test,
  expect,
  seedBoard,
  seedTask,
  seedBoardTask,
  seedTaskEvent,
  readTask,
} from './_fixtures/bypass';

/**
 * E2E coverage for the Profile reorg PR2 web track — the new Profile home
 * (`design_handoff_profile_reorg/README.md` §Screens — Web `/profile` `#5a`,
 * ≤760px `#5c`; `.superpowers/sdd/2026-09-30-profile-reorg/owner-decisions.md`).
 *
 * Covers: the three tiles (Board settings / Streak / Getting started
 * placeholder) navigating (or, for Getting started, deliberately NOT
 * navigating), the Streak tile's computed number vs. its empty state, the
 * Shared counters block's most-recently-logged-first ordering + "+ Log"
 * writing to the real DB, its empty state, and the ≤760px collapse.
 */

// ─── Local date helpers (daily core-board windows) ─────────────────────────
// Mirrors `packages/shared/src/algorithms/calendarBoundaries.ts`'s
// `toLocalISO`/`getDayBoundaries` exactly (local, no `Z` suffix) — the seed
// helpers deliberately avoid importing `@oybc/shared` (see `SeedTemplate`'s
// doc comment), so this is a small self-contained mirror.
function localISO(d: Date): string {
  const y = d.getFullYear();
  const mo = String(d.getMonth() + 1).padStart(2, '0');
  const da = String(d.getDate()).padStart(2, '0');
  const h = String(d.getHours()).padStart(2, '0');
  const mi = String(d.getMinutes()).padStart(2, '0');
  const s = String(d.getSeconds()).padStart(2, '0');
  const ms = String(d.getMilliseconds()).padStart(3, '0');
  return `${y}-${mo}-${da}T${h}:${mi}:${s}.${ms}`;
}
function dailyWindow(offsetDays: number): { startDate: string; endDate: string } {
  const base = new Date();
  base.setDate(base.getDate() + offsetDays);
  const start = new Date(base.getFullYear(), base.getMonth(), base.getDate(), 0, 0, 0, 0);
  const end = new Date(base.getFullYear(), base.getMonth(), base.getDate(), 23, 59, 59, 999);
  return { startDate: localISO(start), endDate: localISO(end) };
}

// A far-future weekly window so seeded counter boards never read as expired.
const TODAY = new Date().toISOString().slice(0, 10);
const NEXT_MONTH = new Date(Date.now() + 30 * 24 * 60 * 60 * 1000).toISOString().slice(0, 10);

test.describe('Profile home — tiles', () => {
  test('Board settings tile links to /profile/board-settings', async ({ page }) => {
    await page.goto('/profile?__oybc_test_bypass=1');
    await page.getByRole('link', { name: /Board settings/ }).click();
    await expect(page).toHaveURL(/\/profile\/board-settings/);
  });

  test('Streak tile shows the empty state with no bingo streak', async ({ page }) => {
    await page.goto('/profile?__oybc_test_bypass=1');
    await expect(page.getByText('No streak yet')).toBeVisible();
    await expect(page.getByText('Clear a board to start one.')).toBeVisible();

    await page.getByRole('link', { name: /No streak yet/ }).click();
    await expect(page).toHaveURL(/\/profile\/streaks/);
  });

  test('Streak tile shows the computed bingo streak for seeded core boards', async ({ page }) => {
    const today = dailyWindow(0);
    const yesterday = dailyWindow(-1);

    await seedBoard(page, {
      id: 'aaaaaaaa-1111-0000-0000-000000000001',
      name: 'Daily today',
      boardSize: 3,
      timeframe: 'daily',
      status: 'active',
      startDate: today.startDate,
      endDate: today.endDate,
      isCore: true,
      linesCompleted: 1,
    });
    await seedBoard(page, {
      id: 'aaaaaaaa-1111-0000-0000-000000000002',
      name: 'Daily yesterday',
      boardSize: 3,
      timeframe: 'daily',
      status: 'completed',
      startDate: yesterday.startDate,
      endDate: yesterday.endDate,
      isCore: true,
      linesCompleted: 1,
    });

    await page.goto('/profile?__oybc_test_bypass=1');

    const streakTile = page.getByRole('link', { name: /day streak/ });
    await expect(streakTile).toBeVisible();
    await expect(streakTile).toContainText('2');
    await expect(streakTile).toContainText('day streak');
    await expect(streakTile).toContainText('Longest 1');
    await expect(streakTile).toContainText('1 GREENLOGs');

    await streakTile.click();
    await expect(page).toHaveURL(/\/profile\/streaks/);
  });

  test('Getting started tile is a non-navigating placeholder', async ({ page }) => {
    await page.goto('/profile?__oybc_test_bypass=1');

    await expect(page.getByText('Getting started')).toBeVisible();
    await expect(page.getByText('Coming soon')).toBeVisible();

    // It must not be reachable as a link or button (owner decision 1: no
    // web tutorial yet — the tile is decorative, `aria-disabled`).
    await expect(page.getByRole('link', { name: /Getting started/ })).toHaveCount(0);
    await expect(page.getByRole('button', { name: /Getting started/ })).toHaveCount(0);
  });
});

test.describe('Profile home — Shared counters', () => {
  test('empty state shows the "New counter" CTA', async ({ page }) => {
    await page.goto('/profile?__oybc_test_bypass=1');

    await expect(page.getByText('One tally, many squares')).toBeVisible();
    await expect(page.getByRole('button', { name: 'New counter' })).toBeVisible();
    // No "All N ›" header link when there are zero counters.
    await expect(page.getByRole('link', { name: /^All \d/ })).toHaveCount(0);
  });

  test('shows the two most recently logged counters first, and "+ Log" writes to the DB', async ({
    page,
  }) => {
    const BOARD_ID = 'bbbbbbbb-2222-0000-0000-000000000000';
    const ROOT_A = 'cccccccc-3333-0000-0000-00000000000a'; // oldest log
    const ROOT_B = 'cccccccc-3333-0000-0000-00000000000b'; // middle
    const ROOT_C = 'cccccccc-3333-0000-0000-00000000000c'; // most recent

    await seedBoard(page, {
      id: BOARD_ID,
      name: 'Fitness board',
      boardSize: 3,
      timeframe: 'weekly',
      status: 'active',
      startDate: TODAY,
      endDate: NEXT_MONTH,
    });

    await seedTask(page, {
      id: ROOT_A,
      title: 'Push-ups fallback',
      type: 'counting',
      action: 'Do',
      unit: 'push-ups',
      maxCount: 1000,
      currentCount: 500,
      isCounter: true,
    });
    await seedTask(page, {
      id: ROOT_B,
      title: 'Pages fallback',
      type: 'counting',
      action: 'Do',
      unit: 'pages',
      maxCount: 5000,
      currentCount: 1240,
      isCounter: true,
    });
    await seedTask(page, {
      id: ROOT_C,
      title: 'Miles fallback',
      type: 'counting',
      action: 'Do',
      unit: 'miles',
      maxCount: 120,
      currentCount: 86,
      isCounter: true,
    });

    await seedBoardTask(page, { id: 'dddddddd-0-a', boardId: BOARD_ID, taskId: ROOT_A, row: 0, col: 0 });
    await seedBoardTask(page, { id: 'dddddddd-0-b', boardId: BOARD_ID, taskId: ROOT_B, row: 0, col: 1 });
    await seedBoardTask(page, { id: 'dddddddd-0-c', boardId: BOARD_ID, taskId: ROOT_C, row: 0, col: 2 });

    // Distinct write-times ("logged" recency is `createdAt`, not
    // `occurredAt` — see `lastLoggedTimestamp`'s doc comment). C is most
    // recent, B middle, A oldest.
    await seedTaskEvent(page, {
      id: 'eeeeeeee-0-a',
      taskId: ROOT_A,
      kind: 'increment',
      delta: 10,
      occurredAt: '2026-01-01T00:00:00.000Z',
      createdAt: '2026-01-01T00:00:00.000Z',
    });
    await seedTaskEvent(page, {
      id: 'eeeeeeee-0-b',
      taskId: ROOT_B,
      kind: 'increment',
      delta: 20,
      occurredAt: '2026-01-02T00:00:00.000Z',
      createdAt: '2026-01-02T00:00:00.000Z',
    });
    await seedTaskEvent(page, {
      id: 'eeeeeeee-0-c',
      taskId: ROOT_C,
      kind: 'increment',
      delta: 5,
      occurredAt: '2026-01-03T00:00:00.000Z',
      createdAt: '2026-01-03T00:00:00.000Z',
    });

    await page.goto('/profile?__oybc_test_bypass=1');

    // Header shows the full count even though only 2 rows render.
    await expect(page.getByRole('link', { name: /^All 3/ })).toBeVisible();

    const rows = page.getByRole('listitem');
    await expect(rows).toHaveCount(2);
    const rowNames = await rows.allTextContents();
    // Most-recently-logged first: Miles (C), then Pages (B). Push-ups (A)
    // is excluded — only the top 2 show on the home surface.
    expect(rowNames[0]).toContain('Miles');
    expect(rowNames[1]).toContain('Pages');
    await expect(page.getByText('Push-ups', { exact: true })).toHaveCount(0);

    // "+ Log" on the top (Miles) row increments the DB via the same write
    // path the Counters Hub uses (`incrementSharedCounter`).
    const milesRow = rows.first();
    // The button's `aria-label` ("Log N {unit} for {name}") overrides its
    // visible "+ Log" text as the accessible name — it's the row's only
    // button, so select on role alone.
    await milesRow.getByRole('button').click();

    await expect
      .poll(async () => {
        const task = await readTask(page, ROOT_C);
        return task?.currentCount;
      })
      .toBe(87); // 86 + 1 (no `defaultLogAmount` seeded → the "+ Log" fallback of 1)
  });
});

test.describe('Profile home — mobile (≤760px)', () => {
  test('tiles collapse to 2-up and the settings button becomes icon-only', async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
    await page.goto('/profile?__oybc_test_bypass=1');

    await expect(page.getByRole('link', { name: /Board settings/ })).toBeVisible();
    await expect(page.getByText('Coming soon')).toBeVisible();

    // The Settings pill collapses to an icon-only round button (its text
    // label goes visually hidden, not removed — see `.settingsButtonLabel`).
    const settingsButton = page.getByRole('button', { name: 'Settings' });
    await expect(settingsButton).toBeVisible();
    const box = await settingsButton.boundingBox();
    expect(box?.width).toBeLessThanOrEqual(44);
  });
});
