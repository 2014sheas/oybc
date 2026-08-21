import {
  test,
  expect,
  seedBoard,
  seedTask,
  seedBoardTask,
  seedTemplate,
  readBoard,
} from './_fixtures/bypass';

/**
 * E2E coverage for P6 (Task Pools + Recurring Boards Rework,
 * docs/POOLS_RECURRING.md §Surfaces items 7 + 8):
 *
 *  - Boards tab: a paused repeating board's card shows the muted
 *    "↻ PAUSED" badge and dims.
 *  - Board screen: a repeating board shows the manage row (cadence +
 *    source name + inline Pause/Resume), and the toggle round-trips
 *    through Dexie.
 *  - Board screen: a one-off board shows the "Repeat this board…" CTA
 *    (gated off for a CHOSEN-center board); picking a cadence writes a
 *    new spawn record, back-stamps the board, and swaps the CTA for the
 *    manage row + the spawn-provenance note.
 *
 * The underlying write correctness (window-key alignment, mix
 * resolution, provenance-note counting) is exhaustively unit-tested in
 * Jest/Vitest (`packages/shared/tests/algorithms/recurringBoardTemplates
 * .test.ts`, `.../poolMix.test.ts`, `apps/web/src/db/operations/__tests__
 * /repeatBoard.test.ts`). This spec pins the UI wiring only.
 */

const PAUSED_TEMPLATE_ID = '50000000-0000-0000-0000-000000000001';
const PAUSED_BOARD_ID = '50000000-0000-0000-0000-000000000002';

const ACTIVE_TEMPLATE_ID = '50000000-0000-0000-0000-000000000003';
const REPEATING_BOARD_ID = '50000000-0000-0000-0000-000000000004';

const ONE_OFF_BOARD_ID = '50000000-0000-0000-0000-000000000005';
const CHOSEN_CENTER_BOARD_ID = '50000000-0000-0000-0000-000000000006';

// Dates are computed relative to "now" (not hardcoded) so the seeded boards
// are genuinely unexpired/unsealed whenever this spec actually runs — a
// hardcoded past date gets swept up by the real `useBackstopAutoSeal`
// (mounted globally in AppShell) within milliseconds of page load, sealing
// the board and hiding every gate this spec is trying to exercise. Exact
// local-vs-UTC precision doesn't matter here (only "safely not expired,
// not past backstop" does) — unit tests cover exact window-key math.
const NOW = new Date();
const START_ISO = new Date(NOW.getTime() - 60 * 60 * 1000).toISOString(); // 1h ago
const END_ISO = new Date(NOW.getTime() + 30 * 24 * 60 * 60 * 1000).toISOString(); // 30d out

test.describe('P6 — Boards tab paused badge', () => {
  test.beforeEach(async ({ page }) => {
    await seedTemplate(page, {
      id: PAUSED_TEMPLATE_ID,
      name: 'Morning Kickstart',
      timeframe: 'daily',
      boardSize: 3,
      centerSquareType: 'none',
      isRandomized: false,
      seedTaskIds: [],
      isActive: false,
    });
    await seedBoard(page, {
      id: PAUSED_BOARD_ID,
      name: 'Morning Repeat Board',
      boardSize: 3,
      timeframe: 'daily',
      status: 'active',
      startDate: START_ISO,
      endDate: END_ISO,
      centerSquareType: 'none',
      spawnedFromTemplateId: PAUSED_TEMPLATE_ID,
    });
  });

  test('shows the muted "PAUSED" badge and dims the card', async ({ page }) => {
    await page.goto('/boards?__oybc_test_bypass=1');
    await expect(page.getByText('Morning Repeat Board')).toBeVisible();
    await expect(page.getByText('PAUSED')).toBeVisible();
    // Not the plain "RECURRING" label — the paused variant replaces it.
    await expect(page.getByText('RECURRING', { exact: true })).not.toBeVisible();
    // "· repeats daily" subtitle appended.
    await expect(page.getByText(/repeats daily/)).toBeVisible();

    // Dimmed styling — the card <button> carries reduced opacity. Anchored
    // to the start of the accessible name so this doesn't also match the
    // sibling "Delete Morning Repeat Board" trash-icon button.
    const card = page.getByRole('button', { name: /^Morning Repeat Board/ });
    const opacity = await card.evaluate((el) => getComputedStyle(el).opacity);
    expect(Number(opacity)).toBeLessThan(1);
  });
});

test.describe('P6 — Board screen manage row', () => {
  test.beforeEach(async ({ page }) => {
    await seedTemplate(page, {
      id: ACTIVE_TEMPLATE_ID,
      name: 'Evening Wind-down',
      timeframe: 'weekly',
      boardSize: 3,
      centerSquareType: 'none',
      isRandomized: false,
      seedTaskIds: [],
      isActive: true,
    });
    await seedBoard(page, {
      id: REPEATING_BOARD_ID,
      name: 'This Week',
      boardSize: 3,
      timeframe: 'weekly',
      status: 'active',
      startDate: START_ISO,
      endDate: END_ISO,
      centerSquareType: 'none',
      spawnedFromTemplateId: ACTIVE_TEMPLATE_ID,
    });
  });

  test('renders the manage row and Pause/Resume round-trips through Dexie', async ({ page }) => {
    await page.goto(`/boards/${REPEATING_BOARD_ID}?__oybc_test_bypass=1`);
    await expect(page.getByText(/Repeats weekly.*Evening Wind-down/)).toBeVisible();

    const toggleBtn = page.getByRole('button', { name: 'Pause' });
    await expect(toggleBtn).toBeVisible();
    await toggleBtn.click();

    // Button flips to "Resume" once the template's isActive write lands
    // (live-query reactive — no reload needed, unlike the raw-IDB seeds).
    await expect(page.getByRole('button', { name: 'Resume' })).toBeVisible();

    // Confirm the badge at the top of the play header also reflects paused.
    await expect(page.getByText('PAUSED')).toBeVisible();
  });
});

test.describe('P6 — "Repeat this board…" CTA', () => {
  test.beforeEach(async ({ page }) => {
    await seedBoard(page, {
      id: ONE_OFF_BOARD_ID,
      name: 'One-off Daily',
      boardSize: 3,
      timeframe: 'daily',
      status: 'active',
      startDate: START_ISO,
      endDate: END_ISO,
      centerSquareType: 'none',
      completedTasks: 0,
    });
    await seedTask(page, { id: '60000000-0000-0000-0000-000000000001', title: 'Task A', type: 'normal' });
    await seedTask(page, { id: '60000000-0000-0000-0000-000000000002', title: 'Task B', type: 'normal' });
    await seedBoardTask(page, {
      id: '70000000-0000-0000-0000-000000000001',
      boardId: ONE_OFF_BOARD_ID,
      taskId: '60000000-0000-0000-0000-000000000001',
      row: 0,
      col: 0,
    });
    await seedBoardTask(page, {
      id: '70000000-0000-0000-0000-000000000002',
      boardId: ONE_OFF_BOARD_ID,
      taskId: '60000000-0000-0000-0000-000000000002',
      row: 0,
      col: 1,
    });

    await seedBoard(page, {
      id: CHOSEN_CENTER_BOARD_ID,
      name: 'Chosen Center Board',
      boardSize: 3,
      timeframe: 'daily',
      status: 'active',
      startDate: START_ISO,
      endDate: END_ISO,
      centerSquareType: 'chosen',
    });
  });

  test('is hidden for a CHOSEN-center board', async ({ page }) => {
    await page.goto(`/boards/${CHOSEN_CENTER_BOARD_ID}?__oybc_test_bypass=1`);
    await expect(page.getByText('Chosen Center Board')).toBeVisible();
    await expect(page.getByRole('button', { name: /Repeat this board/ })).not.toBeVisible();
  });

  test('appears for a one-off board; picking a cadence writes the spawn record and swaps in the manage row + provenance note', async ({ page }) => {
    await page.goto(`/boards/${ONE_OFF_BOARD_ID}?__oybc_test_bypass=1`);
    await expect(page.getByText('One-off Daily')).toBeVisible();

    const cta = page.getByRole('button', { name: /Repeat this board/ });
    await expect(cta).toBeVisible();
    await cta.click();

    // Cadence picker appears with the 4 options.
    await expect(page.getByRole('group', { name: 'Repeat cadence' })).toBeVisible();
    await page.getByRole('button', { name: 'Weekly', exact: true }).click();

    // CTA is replaced by the manage row.
    await expect(page.getByText(/Repeats weekly.*One-off Daily/)).toBeVisible();
    await expect(page.getByRole('button', { name: /Repeat this board/ })).not.toBeVisible();

    // Spawn-provenance note — 100% manual (no pools involved).
    await expect(page.getByText(/Dealt 2 of 2 — 2 added today/)).toBeVisible();

    // Back-stamp landed in Dexie.
    const board = await readBoard(page, ONE_OFF_BOARD_ID);
    expect(board?.spawnedFromTemplateId).toBeTruthy();
  });
});
