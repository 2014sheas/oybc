import { test, expect, seedBoard } from './_fixtures/bypass';

/**
 * A core board opened from ANY entry point lands in the per-window pager
 * (`/boards/core/:timeframe/:date`) — the same swipe-to-browse surface the
 * Core Boards strip opens — never the plain `/boards/:id` page. The
 * `/boards/:id` route resolves the board and redirects (replace) through
 * the shared `coreWindowRouteForBoard`; an ad-hoc board on the same
 * timeframe stays put. iOS twin: `MainTabView.pushBoard(_:)`.
 *
 * Scenarios:
 *   1. Direct URL to a core daily board → pager URL + window chip.
 *   2. Direct URL to an ad-hoc daily board → stays on `/boards/:id`,
 *      no window chip.
 */

const CORE_BOARD_ID = 'cccccccc-c0de-0000-0000-000000000001';
const ADHOC_BOARD_ID = 'cccccccc-c0de-0000-0000-000000000002';
const CORE_BOARD_NAME = 'Core Daily Board';
const ADHOC_BOARD_NAME = 'Ad-hoc Daily Board';

/** Today's daily window as the app stores it (`toLocalISO`, local clock). */
const now = new Date();
const pad = (n: number): string => String(n).padStart(2, '0');
const TODAY_DATE = `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
const WINDOW_START = `${TODAY_DATE}T00:00:00.000`;
const WINDOW_END = `${TODAY_DATE}T23:59:59.999`;

test.describe('Core boards open in the window pager from any entry point', () => {
  test.beforeEach(async ({ page }) => {
    await seedBoard(page, {
      id: CORE_BOARD_ID,
      name: CORE_BOARD_NAME,
      boardSize: 3,
      timeframe: 'daily',
      status: 'active',
      startDate: WINDOW_START,
      endDate: WINDOW_END,
      isCore: true,
    });
    await seedBoard(page, {
      id: ADHOC_BOARD_ID,
      name: ADHOC_BOARD_NAME,
      boardSize: 3,
      timeframe: 'daily',
      status: 'active',
      startDate: WINDOW_START,
      endDate: WINDOW_END,
      isCore: false,
    });
  });

  test('direct URL to a core board redirects into the pager', async ({ page }) => {
    await page.goto(`/boards/${CORE_BOARD_ID}?__oybc_test_bypass=1`);

    await expect(page).toHaveURL(new RegExp(`/boards/core/daily/${TODAY_DATE}$`));
    // Pager chrome: the window chip (opens the picker) + the board itself.
    await expect(page.getByRole('button', { name: /Opens window picker/ })).toBeVisible();
    await expect(page.getByText(CORE_BOARD_NAME)).toBeVisible();
  });

  test('direct URL to an ad-hoc board on the same timeframe stays on the plain page', async ({
    page,
  }) => {
    await page.goto(`/boards/${ADHOC_BOARD_ID}?__oybc_test_bypass=1`);

    await expect(page.getByText(ADHOC_BOARD_NAME)).toBeVisible();
    // (the bypass query param rides along on a direct hit — anchor before it)
    await expect(page).toHaveURL(new RegExp(`/boards/${ADHOC_BOARD_ID}(\\?|$)`));
    await expect(page.getByRole('button', { name: /Opens window picker/ })).toHaveCount(0);
  });
});
