import {
  test,
  expect,
  seedBoard,
  readBoard,
} from './_fixtures/bypass';

/**
 * E2E coverage for the Boards tab list:
 *  - Default filter is "Active" (not "All").
 *  - Expiry-aware "Active" excludes boards whose `endDate < now` even
 *    when their status is ACTIVE.
 *  - Per-row delete: ✕ button → confirm dialog → soft-delete via Dexie.
 *
 * Both behaviors landed alongside the Phase 6.1 core-board banner fix
 * (PR #58 / fix/core-board-banner-dismissal).
 */

const ACTIVE_LIVE_ID = 'cccccccc-bbbb-0000-0000-000000000001';
const ACTIVE_EXPIRED_ID = 'cccccccc-bbbb-0000-0000-000000000002';
const DRAFT_ID = 'cccccccc-bbbb-0000-0000-000000000003';

const today = new Date();
const isoDay = (d: Date): string => d.toISOString().slice(0, 10);
const TODAY = isoDay(today);
const NEXT_WEEK = isoDay(new Date(today.getTime() + 7 * 24 * 60 * 60 * 1000));
const LAST_WEEK = isoDay(new Date(today.getTime() - 7 * 24 * 60 * 60 * 1000));
const TWO_WEEKS_AGO = isoDay(new Date(today.getTime() - 14 * 24 * 60 * 60 * 1000));

test.describe('Boards tab', () => {
  test.beforeEach(async ({ page }) => {
    // Live active board: ends a week from now.
    await seedBoard(page, {
      id: ACTIVE_LIVE_ID,
      name: 'Active Live',
      boardSize: 5,
      timeframe: 'weekly',
      status: 'active',
      startDate: TODAY,
      endDate: NEXT_WEEK,
    });
    // Active-but-expired: endDate already in the past, status still ACTIVE.
    await seedBoard(page, {
      id: ACTIVE_EXPIRED_ID,
      name: 'Active Expired',
      boardSize: 5,
      timeframe: 'weekly',
      status: 'active',
      startDate: TWO_WEEKS_AGO,
      endDate: LAST_WEEK,
    });
    // Draft for contrast (won't appear under Active).
    await seedBoard(page, {
      id: DRAFT_ID,
      name: 'Draft Board',
      boardSize: 5,
      timeframe: 'weekly',
      status: 'draft',
      startDate: TODAY,
      endDate: NEXT_WEEK,
    });
  });

  test('default filter is Active and excludes expired boards', async ({ page }) => {
    // Force a page reload so Dexie's useLiveQuery picks up the
    // beforeEach raw-IDB seeds. Dexie's change observer only sees
    // writes that go through Dexie's API; raw `indexedDB` writes
    // (which the bypass fixture uses for speed) bypass the observer
    // and a fresh page mount is the simplest way to get a re-read.
    await page.goto('/boards?__oybc_test_bypass=1');
    await expect(page.getByRole('heading', { name: 'Boards', level: 1 })).toBeVisible();

    // Active Live shows; Active Expired (past endDate) does not; Draft does not.
    await expect(page.getByText('Active Live')).toBeVisible();
    await expect(page.getByText('Active Expired')).not.toBeVisible();
    await expect(page.getByText('Draft Board')).not.toBeVisible();

    // Switching to All reveals all three.
    await page.getByRole('button', { name: 'All', exact: true }).click();
    await expect(page.getByText('Active Live')).toBeVisible();
    await expect(page.getByText('Active Expired')).toBeVisible();
    await expect(page.getByText('Draft Board')).toBeVisible();
  });

  test('per-row delete: ✕ → confirm → row disappears + Dexie isDeleted', async ({ page }) => {
    // Direct navigation forces a fresh BoardsPage mount → useLiveQuery
    // re-reads the seeds written via raw IDB in beforeEach.
    await page.goto('/boards?__oybc_test_bypass=1');

    // Use the per-row delete button (aria-label "Delete Active Live").
    await page.getByRole('button', { name: /delete active live/i }).click();

    // Confirm dialog should be visible.
    const dialog = page.getByRole('alertdialog', { name: 'Confirm delete board' });
    await expect(dialog).toBeVisible();
    await dialog.getByRole('button', { name: 'Delete', exact: true }).click();

    // The dialog has fully dismissed and the row should be gone.
    // Scope the row check to the board-list section to avoid matching
    // any other mention of "Active Live" (e.g., a still-mounting dialog).
    await expect(dialog).not.toBeVisible();
    await expect(
      page.getByRole('button', { name: /^Active Live/ }),
    ).not.toBeVisible();

    // Soft-delete on disk: `isDeleted: true`.
    const row = await readBoard(page, ACTIVE_LIVE_ID);
    expect(row).not.toBeNull();
    expect((row as { isDeleted?: boolean }).isDeleted).toBe(true);
  });
});
