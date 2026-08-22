import {
  test,
  expect,
  seedBoard,
  openCreateHub,
  startOneOffWizard,
  startRecurringWizard,
} from './_fixtures/bypass';

/**
 * E2E coverage for the recurring-UX pass (#321):
 *  - Step 1 (Setup) shows the live task-count requirement line, updating
 *    with size + center selection ("A 5×5 board needs 24 tasks."), with
 *    "at least" phrasing in recurring mode.
 *  - Boards spawned from a template (spawnedFromTemplateId set) carry a
 *    RECURRING badge on the Boards-list card and the play header.
 *
 * (The old "templates page" describe block — pool-preview chips, the
 * "Add tasks" deep-link, "+ New template" — tested the standalone
 * `/profile/recurring-templates` page, which P7 (Task Pools + Recurring
 * Boards Rework) retired in favor of `/profile/board-settings`'s
 * "Repeating boards" roster. See `board-settings.spec.ts` for its
 * coverage.)
 */

const today = new Date();
const isoDay = (d: Date): string => d.toISOString().slice(0, 10);
const TODAY = isoDay(today);
const NEXT_WEEK = isoDay(new Date(today.getTime() + 7 * 24 * 60 * 60 * 1000));

test.describe('Recurring UX pass', () => {
  test('setup step shows the requirement line, live with size + center', async ({ page }) => {
    await openCreateHub(page);
    await startOneOffWizard(page);
    await expect(page.getByLabel(/board name/i)).toBeVisible();

    // Pin a known geometry: 5×5 + Free Space center → 24 tasks.
    await page.getByRole('button', { name: '5×5' }).click();
    await page.getByLabel(/center square/i).selectOption('free');
    await expect(page.getByText('A 5×5 board needs 24 tasks.')).toBeVisible();

    // Size change updates the line immediately: 3×3 + FREE → 8.
    await page.getByRole('button', { name: '3×3' }).click();
    await expect(page.getByText('A 3×3 board needs 8 tasks.')).toBeVisible();

    // Center change updates it too: 3×3 + None → 9 (no reserved center).
    await page.getByLabel(/center square/i).selectOption('none');
    await expect(page.getByText('A 3×3 board needs 9 tasks.')).toBeVisible();
  });

  test('recurring wizard requirement line drops the "A n×n board" framing (pool may overfill)', async ({ page }) => {
    // Board Creation Split (web PR C) — recurring mode is chosen at the
    // Create-hub CTA, not a mid-wizard "Repeats" segmented.
    await openCreateHub(page);
    await startRecurringWizard(page);
    await expect(page.getByLabel(/board name/i)).toBeVisible();

    await page.getByRole('button', { name: '5×5' }).click();
    await page.getByLabel(/center square/i).selectOption('free');
    await expect(
      page.getByText('Needs at least 24 tasks — extras rotate in.'),
    ).toBeVisible();
  });

  test.describe('recurring badge on spawned boards', () => {
    const SPAWNED_ID = 'eeeeeeee-0000-0000-0000-000000000001';
    const MANUAL_ID = 'eeeeeeee-0000-0000-0000-000000000002';

    test.beforeEach(async ({ page }) => {
      await seedBoard(page, {
        id: SPAWNED_ID,
        name: 'Spawned Weekly',
        boardSize: 3,
        timeframe: 'weekly',
        status: 'active',
        startDate: TODAY,
        endDate: NEXT_WEEK,
        spawnedFromTemplateId: '22222222-3333-4444-5555-666666666666',
      });
      await seedBoard(page, {
        id: MANUAL_ID,
        name: 'Manual Weekly',
        boardSize: 3,
        timeframe: 'weekly',
        status: 'active',
        startDate: TODAY,
        endDate: NEXT_WEEK,
      });
    });

    test('boards list shows RECURRING on the spawned board only', async ({ page }) => {
      await page.goto('/boards?__oybc_test_bypass=1');
      await expect(page.getByText('Spawned Weekly')).toBeVisible();
      await expect(page.getByText('Manual Weekly')).toBeVisible();

      const spawnedRow = page
        .getByRole('button')
        .filter({ hasText: 'Spawned Weekly' });
      const manualRow = page
        .getByRole('button')
        .filter({ hasText: 'Manual Weekly' });
      await expect(spawnedRow.getByText('RECURRING')).toBeVisible();
      await expect(manualRow.getByText('RECURRING')).toHaveCount(0);
    });

    test('board play header shows RECURRING for the spawned board', async ({ page }) => {
      await page.goto(`/boards/${SPAWNED_ID}?__oybc_test_bypass=1`);
      await expect(page.getByText('Spawned Weekly')).toBeVisible();
      await expect(page.getByText('RECURRING')).toBeVisible();

      await page.goto(`/boards/${MANUAL_ID}?__oybc_test_bypass=1`);
      await expect(page.getByText('Manual Weekly')).toBeVisible();
      await expect(page.getByText('RECURRING')).toHaveCount(0);
    });
  });
});
