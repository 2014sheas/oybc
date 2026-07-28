import {
  test,
  expect,
  seedBoard,
  seedTask,
  seedTemplate,
  clearTemplates,
  openCreateHub,
} from './_fixtures/bypass';

/**
 * E2E coverage for the recurring-UX pass (#321):
 *  - Step 1 (Setup) shows the live task-count requirement line, updating
 *    with size + center selection ("A 5×5 board needs 24 tasks."), with
 *    "at least" phrasing in recurring mode.
 *  - Template rows show a compact pool preview (title chips + "+k more")
 *    and an "Add tasks" affordance that deep-links to the wizard's
 *    Tasks step.
 *  - The templates page regained a "+ New template" entry point routing
 *    to the recurring wizard.
 *  - Boards spawned from a template (spawnedFromTemplateId set) carry a
 *    RECURRING badge on the Boards-list card and the play header.
 */

const today = new Date();
const isoDay = (d: Date): string => d.toISOString().slice(0, 10);
const TODAY = isoDay(today);
const NEXT_WEEK = isoDay(new Date(today.getTime() + 7 * 24 * 60 * 60 * 1000));

test.describe('Recurring UX pass', () => {
  test('setup step shows the requirement line, live with size + center', async ({ page }) => {
    await openCreateHub(page);
    await page.getByRole('button', { name: /start a new board/i }).click();
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

  test('recurring wizard requirement line uses "at least" (pool may overfill)', async ({ page }) => {
    await openCreateHub(page);
    await page.getByRole('button', { name: /create a recurring board/i }).click();
    await expect(page.getByLabel(/board name/i)).toBeVisible();

    await page.getByRole('button', { name: '5×5' }).click();
    await page.getByLabel(/center square/i).selectOption('free');
    await expect(
      page.getByText('A 5×5 board needs at least 24 tasks.'),
    ).toBeVisible();
  });

  test.describe('templates page', () => {
    const TEMPLATE_ID = '22222222-3333-4444-5555-666666666666';

    test.beforeEach(async ({ page }) => {
      await clearTemplates(page);
      // 9 resolvable pool tasks → healthy 3×3/FREE template (needs 8).
      for (let i = 1; i <= 9; i++) {
        await seedTask(page, {
          id: `dddddddd-0000-0000-0000-${String(i).padStart(12, '0')}`,
          title: `Pool Task ${i}`,
          type: 'normal',
        });
      }
      await seedTemplate(page, {
        id: TEMPLATE_ID,
        name: 'Morning Routine',
        timeframe: 'weekly',
        boardSize: 3,
        centerSquareType: 'free',
        isRandomized: true,
        seedTaskIds: Array.from({ length: 9 }, (_, i) =>
          `dddddddd-0000-0000-0000-${String(i + 1).padStart(12, '0')}`,
        ),
        isActive: true,
      });
      await page.goto('/profile/recurring-templates?__oybc_test_bypass=1');
    });

    test('row shows pool count + first-3 title chips + "+k more"', async ({ page }) => {
      await expect(page.getByText('Morning Routine')).toBeVisible();
      await expect(page.getByText('9-task pool')).toBeVisible();
      // First three resolved titles, in seedTaskIds order, then the tail.
      await expect(page.getByText('Pool Task 1', { exact: true })).toBeVisible();
      await expect(page.getByText('Pool Task 2', { exact: true })).toBeVisible();
      await expect(page.getByText('Pool Task 3', { exact: true })).toBeVisible();
      await expect(page.getByText('Pool Task 4', { exact: true })).not.toBeVisible();
      await expect(page.getByText('+6 more')).toBeVisible();
    });

    test('"Add tasks" deep-links to the wizard Tasks step for the template', async ({ page }) => {
      await page
        .getByRole('button', { name: `Add tasks to Morning Routine` })
        .click();

      // Param consumed + cleared; wizard mounts in template-edit mode
      // directly on step 2 (Tasks).
      await expect(page).toHaveURL(/\/create$/);
      await expect(
        page.getByRole('heading', { name: /edit recurring board/i }),
      ).toBeVisible();
      const tasksStep = page
        .getByRole('navigation', { name: 'Wizard progress' })
        .getByText('Tasks');
      await expect(tasksStep).toBeVisible();
      // The Tasks step is the ACTIVE step — its selection counter renders
      // (hydrated from the 9-task pool; 3×3 FREE needs 8, so "9 / 8 min").
      await expect(page.getByText(/Selected:/)).toBeVisible();
      await expect(page.getByText(/9 \/ 8 min/)).toBeVisible();
    });

    test('"+ New template" routes into the recurring wizard', async ({ page }) => {
      await page.getByRole('button', { name: '+ New template' }).click();

      await expect(page).toHaveURL(/\/create$/);
      await expect(
        page.getByRole('heading', { name: /new recurring board/i }),
      ).toBeVisible();
      // Recurring mode: Custom timeframe absent.
      await expect(
        page.getByRole('button', { name: 'Custom', exact: true }),
      ).toHaveCount(0);
    });
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
