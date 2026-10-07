import { test, expect, seedBoard, seedBoardTask, seedTask, readTask } from './_fixtures/bypass';

/**
 * Counter kinds — logging (docs/COUNTER_KINDS.md §5, B1): a counting square's
 * tap opens the DetailModal; Continuous / Duration log through the ¼ · ½ ·
 * goal · # chips and the always-open amount field, and only an explicitly
 * entered amount is remembered as the default.
 */

const now = new Date();
const iso = (d: Date) => d.toISOString();
const START = iso(new Date(now.getTime() - 2 * 864e5));
const END = iso(new Date(now.getTime() + 5 * 864e5));
const BOARD = 'f1000000-0000-0000-0000-000000000001';
const RUN = 'f1000000-0000-0000-0000-000000000002';
const PRACTICE = 'f1000000-0000-0000-0000-000000000003';

test.describe('Counter kinds — logging (B1)', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/boards?__oybc_test_bypass=1');
    await seedTask(page, { id: RUN, title: 'Run 26.2 mi', type: 'counting', action: 'Run', unit: 'mi', maxCount: 26.2, countKind: 'continuous' });
    await seedTask(page, { id: PRACTICE, title: 'Practice 10h 30m', type: 'counting', action: 'Practice', unit: '', maxCount: 630, countKind: 'duration' });
    await seedBoard(page, { id: BOARD, name: 'Kinds board', boardSize: 3, timeframe: 'weekly', status: 'active', startDate: START, endDate: END, centerSquareType: 'none' });
    await seedBoardTask(page, { id: 'f1000000-bt00-0000-0000-000000000001', boardId: BOARD, taskId: RUN, row: 0, col: 0 });
    await seedBoardTask(page, { id: 'f1000000-bt00-0000-0000-000000000002', boardId: BOARD, taskId: PRACTICE, row: 0, col: 1 });
    await page.goto(`/boards/${BOARD}?__oybc_test_bypass=1`);
  });

  test('Continuous: chip, typed custom amount, remembered on reopen', async ({ page }) => {
    const run = page.getByRole('button', { name: 'Run 26.2 mi' });
    await run.click();
    const modal = page.getByRole('dialog');
    await modal.getByRole('button', { name: '13.1', exact: true }).click();
    await modal.getByRole('button', { name: '+ 13.1 mi' }).click();
    await expect(modal).toContainText('13.1/26.2');
    await page.keyboard.press('Escape');
    await expect(run).toContainText('13.1/26.2');
    expect(await readTask(page, RUN)).not.toHaveProperty('defaultLogAmount');
    await run.click();
    await modal.getByLabel('Log amount', { exact: true }).fill('3,1');
    await modal.getByRole('button', { name: '+ 3.1 mi' }).click();
    await expect(modal).toContainText('16.2/26.2');
    await page.keyboard.press('Escape');
    await expect.poll(async () => (await readTask(page, RUN))?.defaultLogAmount).toBe(3.1);
    await run.click();
    await expect(modal.getByRole('button', { name: '#3.1' })).toHaveAttribute('aria-pressed', 'true');
    await expect(modal.getByLabel('Log amount', { exact: true })).toHaveValue('3.1');
  });

  test('Duration: h / m entry', async ({ page }) => {
    const practice = page.getByRole('button', { name: 'Practice 10h 30m' });
    await practice.click();
    const modal = page.getByRole('dialog');
    await expect(modal.getByRole('button', { name: '2h 38m', exact: true })).toHaveAttribute('aria-pressed', 'true');
    await modal.getByLabel('Log amount hours').fill('1');
    await modal.getByLabel('Log amount minutes').fill('30');
    await modal.getByRole('button', { name: '+ 1h 30m' }).click();
    await expect(modal).toContainText('1h 30m/10h 30m');
    await page.keyboard.press('Escape');
    await expect.poll(async () => (await readTask(page, PRACTICE))?.defaultLogAmount).toBe(90);
  });

  test('right-click: + Add {last} unit', async ({ page }) => {
    const run = page.getByRole('button', { name: 'Run 26.2 mi' });
    await run.click({ button: 'right' });
    await page.getByRole('button', { name: '+ Add 6.6 mi' }).click();
    await expect(run).toContainText('6.6/26.2');
  });

  test('hub: a never-logged Continuous counter pill opens Counter Detail', async ({ page }) => {
    await seedTask(page, { id: 'f2000000-0000-0000-0000-000000000001', title: 'Run miles', type: 'counting', action: 'Run', unit: 'miles', isCounter: true, countKind: 'continuous', currentCount: 148.6 });
    await page.goto('/profile/counters?__oybc_test_bypass=1');
    await page.getByRole('button', { name: 'Log Run miles', exact: true }).click();
    await expect(page).toHaveURL(/\/profile\/counters\/f2000000-0000-0000-0000-000000000001/);
  });
});
