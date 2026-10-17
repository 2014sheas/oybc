import { test, expect, seedBoard, seedBoardTask, seedTask, readTask } from './_fixtures/bypass';

/**
 * Counter kinds — logging (docs/COUNTER_KINDS.md §5, B1): a counting square's
 * tap opens the square sheet; chips log at once (tapLogChips) and only an explicitly
 * entered "Other…" amount is remembered as the default.
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

  test('Continuous: a chip logs at once; a typed Other… amount is remembered as the default', async ({ page }) => {
    const run = page.getByRole('button', { name: 'Run 26.2 mi' });
    await run.click();
    const sheet = page.getByRole('dialog');
    await sheet.getByRole('button', { name: 'Log +5 mi' }).click();
    await expect(sheet.getByText('Logged +5 mi')).toBeVisible();
    await expect(sheet).toContainText('/ 26.2 mi');
    await page.keyboard.press('Escape');
    await expect(run).toContainText('5/26.2');
    expect(await readTask(page, RUN)).not.toHaveProperty('defaultLogAmount');
    await run.click();
    await sheet.getByRole('button', { name: 'Log another amount' }).click();
    await sheet.getByLabel('Custom amount').fill('3,1');
    await sheet.getByRole('button', { name: 'Log', exact: true }).click();
    await expect(sheet.getByText('Logged +3.1 mi')).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(run).toContainText('8.1/26.2');
    await expect.poll(async () => (await readTask(page, RUN))?.defaultLogAmount).toBe(3.1);
  });

  test('Duration: Other… takes h / m and the count renders h:m', async ({ page }) => {
    const practice = page.getByRole('button', { name: 'Practice 10h 30m' });
    await practice.click();
    const sheet = page.getByRole('dialog');
    await expect(sheet).toContainText('/ 10h 30m');
    await expect(sheet.getByRole('button', { name: 'Log +15m' })).toBeVisible();
    await sheet.getByRole('button', { name: 'Log another amount' }).click();
    await sheet.getByLabel('Custom amount hours').fill('1');
    await sheet.getByLabel('Custom amount minutes').fill('30');
    await sheet.getByRole('button', { name: 'Log', exact: true }).click();
    await expect(sheet).toContainText('Logged +1h 30m');
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

  test('Counter Detail: a Continuous counter logs 0.5', async ({ page }) => {
    await seedTask(page, { id: 'f3000000-0000-0000-0000-000000000001', title: 'Run miles', type: 'counting', action: 'Run', unit: 'miles', isCounter: true, countKind: 'continuous', currentCount: 148.6 });
    await page.goto('/profile/counters/f3000000-0000-0000-0000-000000000001?__oybc_test_bypass=1');
    await page.getByRole('group', { name: 'Log amount' }).getByRole('button', { name: 'Log +0.5 miles' }).click();
    await expect(page.getByText('149.1', { exact: true })).toBeVisible();
  });
});
