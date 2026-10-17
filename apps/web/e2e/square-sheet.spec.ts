import {
  test, expect, seedBoard, seedBoardTask, seedCompoundChild, seedTask, readBoard,
} from './_fixtures/bypass';

/**
 * Tap contract + square sheet (docs/TASK_DETAIL_REDESIGN.md §PR 2): a Normal
 * tap toggles at once with an Undo toast; Counting / Compound / Achievement
 * open the square sheet whose chips write immediately with an inline Undo
 * strip; a closed board opens the same sheet read-only with `Late log…`.
 */

const now = new Date();
const iso = (d: Date): string => d.toISOString();
const START = iso(new Date(now.getTime() - 2 * 864e5));
const END = iso(new Date(now.getTime() + 5 * 864e5));
const PAST_START = iso(new Date(now.getTime() - 30 * 864e5));
const PAST_END = iso(new Date(now.getTime() - 2 * 864e5));

const BOARD = 'e5000000-0000-0000-0000-000000000001';
const CLOSED = 'e5000000-0000-0000-0000-000000000002';
const NORMAL = 'e5000000-0000-0000-0000-000000000010';
const READ = 'e5000000-0000-0000-0000-000000000011';
const COMPOUND = 'e5000000-0000-0000-0000-000000000012';
const WALK = 'e5000000-0000-0000-0000-000000000013';
const PAGES = 'e5000000-0000-0000-0000-000000000014';
const WATCHER = 'e5000000-0000-0000-0000-000000000015';
const WATCHED = 'e5000000-0000-0000-0000-000000000003';
const bt = (n: number): string => `e5000000-bt00-0000-0000-0000000000${String(n).padStart(2, '0')}`;

test.describe('Square sheet + tap contract', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/boards?__oybc_test_bypass=1');
    await seedTask(page, { id: NORMAL, title: 'Finish Dune', type: 'normal' });
    await seedTask(page, { id: READ, title: 'Read 20 pages', type: 'counting', action: 'Read', unit: 'pages', maxCount: 20 });
    await seedTask(page, { id: WALK, title: 'Walk the dog', type: 'normal' });
    await seedTask(page, { id: PAGES, title: 'Read a chapter', type: 'counting', action: 'Read', unit: 'pages', maxCount: 20 });
    await seedTask(page, { id: COMPOUND, title: 'Daily wellness', type: 'compound' });
    await seedCompoundChild(page, { id: 'e5000000-cc00-0000-0000-000000000001', compoundTaskId: COMPOUND, childTaskId: WALK, childIndex: 0 });
    await seedCompoundChild(page, { id: 'e5000000-cc00-0000-0000-000000000002', compoundTaskId: COMPOUND, childTaskId: PAGES, childIndex: 1 });
    await seedBoard(page, { id: WATCHED, name: 'Watched October', boardSize: 3, timeframe: 'monthly', status: 'active', startDate: START, endDate: END, centerSquareType: 'none' });
    await seedTask(page, { id: WATCHER, title: 'First bingo on October', type: 'achievement', referencedBoardId: WATCHED, achievementTrigger: 'bingo' });
    await seedBoard(page, { id: BOARD, name: 'Sheet board', boardSize: 3, timeframe: 'weekly', status: 'active', startDate: START, endDate: END, centerSquareType: 'none' });
    await seedBoardTask(page, { id: bt(1), boardId: BOARD, taskId: NORMAL, row: 0, col: 0 });
    await seedBoardTask(page, { id: bt(2), boardId: BOARD, taskId: READ, row: 0, col: 1 });
    await seedBoardTask(page, { id: bt(3), boardId: BOARD, taskId: COMPOUND, row: 0, col: 2 });
    await seedBoardTask(page, { id: bt(4), boardId: BOARD, taskId: WATCHER, row: 1, col: 0 });
  });

  test('Normal tap toggles at once, shows the Undo toast, and Undo re-toggles', async ({ page }) => {
    await page.goto(`/boards/${BOARD}?__oybc_test_bypass=1`);
    const square = page.getByRole('button', { name: 'Finish Dune' });
    await square.click();
    await expect(square).toHaveAttribute('aria-pressed', 'true');
    const toast = page.getByRole('status').filter({ hasText: 'Finish Dune · done' });
    await expect(toast).toBeVisible();
    await expect(toast).toContainText('Sheet board');
    await expect(page.getByRole('dialog')).toHaveCount(0);
    await toast.getByRole('button', { name: 'Undo' }).click();
    await expect(square).toHaveAttribute('aria-pressed', 'false');
  });

  test('Counting tap → chip logs at once → count moves → Undo restores', async ({ page }) => {
    await page.goto(`/boards/${BOARD}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Read 20 pages' }).click();
    const sheet = page.getByRole('dialog', { name: 'Read 20 pages' });
    await expect(sheet).toContainText('/ 20 pages');
    await expect(sheet.getByRole('button', { name: 'Log the rest, +20 pages' })).toBeVisible();
    await sheet.getByRole('button', { name: 'Log +10 pages' }).click();
    await expect(sheet.getByText('Logged +10 pages')).toBeVisible();
    await expect(sheet.locator('span').filter({ hasText: /^10$/ }).first()).toBeVisible();
    await expect(sheet).toContainText('10 to go');
    await sheet.getByRole('button', { name: 'Undo', exact: true }).click();
    await expect(sheet.getByText('Logged +10 pages')).toHaveCount(0);
    await expect(sheet).toContainText('20 to go');
    // Overshoot is valid: the rest chip lands exactly on the goal, "Other…" opens the entry.
    await sheet.getByRole('button', { name: 'Log the rest, +20 pages' }).click();
    await expect(sheet).not.toContainText('to go');
    await sheet.getByRole('button', { name: 'Log another amount' }).click();
    await sheet.getByLabel('Custom amount').fill('5');
    await sheet.getByRole('button', { name: 'Log', exact: true }).click();
    await expect(sheet.getByText('Logged +5 pages')).toBeVisible();
    await expect(sheet.getByRole('button', { name: 'Remove…', exact: false })).toBeVisible();
  });

  test('Compound: a counting child opens inline chips; the parent updates; Undo restores', async ({ page }) => {
    await page.goto(`/boards/${BOARD}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Daily wellness' }).click();
    const sheet = page.getByRole('dialog', { name: 'Daily wellness' });
    await expect(sheet).toContainText('of 2 sub-tasks');
    await expect(sheet).toContainText('0 / 20');
    await sheet.getByRole('button', { name: 'Log Read a chapter' }).click();
    await sheet.getByRole('button', { name: 'Log +10 pages' }).click();
    await expect(sheet).toContainText('10 / 20');
    await expect(sheet.getByText('Logged +10 pages')).toBeVisible();
    await sheet.getByRole('button', { name: 'Undo', exact: true }).click();
    await expect(sheet).toContainText('0 / 20');
    // The plain child toggles by its checkbox.
    await sheet.getByRole('checkbox', { name: 'Walk the dog' }).click();
    await expect(sheet.getByRole('checkbox', { name: 'Walk the dog' })).toHaveAttribute('aria-checked', 'true');
  });

  test('Compound: a child toggle shows its own Undo strip and hides the earlier log strip', async ({ page }) => {
    await page.goto(`/boards/${BOARD}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Daily wellness' }).click();
    const sheet = page.getByRole('dialog', { name: 'Daily wellness' });
    await sheet.getByRole('button', { name: 'Log Read a chapter' }).click();
    await sheet.getByRole('button', { name: 'Log +1 pages' }).click();
    await expect(sheet.getByText('Logged +1 pages')).toBeVisible();
    await sheet.getByRole('checkbox', { name: 'Walk the dog' }).click();
    await expect(sheet.getByText('Walk the dog · done')).toBeVisible();
    await expect(sheet.getByText('Logged +1 pages')).toHaveCount(0);
    await sheet.getByRole('button', { name: 'Undo', exact: true }).click();
    await expect(sheet.getByRole('checkbox', { name: 'Walk the dog' })).toHaveAttribute('aria-checked', 'false');
    await expect(sheet.getByText('Walk the dog · done')).toHaveCount(0);
  });

  test('Normal: the hold menu Details opens the sheet; Mark done closes it and raises the Undo toast', async ({ page }) => {
    await page.goto(`/boards/${BOARD}?__oybc_test_bypass=1`);
    const square = page.getByRole('button', { name: 'Finish Dune' });
    await square.click({ button: 'right' });
    await page.getByRole('button', { name: /View Details/ }).click();
    const sheet = page.getByRole('dialog', { name: 'Finish Dune' });
    await sheet.getByRole('button', { name: 'Mark done' }).click();
    await expect(page.getByRole('dialog')).toHaveCount(0);
    await expect(square).toHaveAttribute('aria-pressed', 'true');
    await expect(page.getByRole('status').filter({ hasText: 'Finish Dune · done' })).toBeVisible();
  });

  test('Achievement tap opens the watched-board card; Open ‹board› navigates', async ({ page }) => {
    await page.goto(`/boards/${BOARD}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'First bingo on October' }).click();
    const sheet = page.getByRole('dialog', { name: 'First bingo on October' });
    await expect(sheet).toContainText('Watched board');
    await expect(sheet).toContainText('0 / 1 bingo');
    await sheet.getByRole('button', { name: 'Open Watched October' }).click();
    await expect(page).toHaveURL(new RegExp(`/boards/${WATCHED}|/boards/core/`));
  });

  test('Library › opens the task detail sheet and Escape closes the square sheet', async ({ page }) => {
    await page.goto(`/boards/${BOARD}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Read 20 pages' }).click();
    await expect(page.getByRole('dialog', { name: 'Read 20 pages' })).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(page.getByRole('dialog')).toHaveCount(0);
    await page.getByRole('button', { name: 'Read 20 pages' }).click();
    await page.getByRole('button', { name: 'Open in library' }).click();
    await expect(page.getByRole('dialog', { name: 'Read 20 pages' })).toHaveCount(0);
  });
});

test.describe('Square sheet — closed board', () => {
  test('a tap opens the sheet read-only; Late log… opens the late-log sheet', async ({ page }) => {
    await page.goto('/boards?__oybc_test_bypass=1');
    await seedTask(page, { id: READ, title: 'Read 20 pages', type: 'counting', action: 'Read', unit: 'pages', maxCount: 20 });
    await seedBoard(page, {
      id: CLOSED, name: 'Closed board', boardSize: 3, timeframe: 'monthly', status: 'active',
      startDate: PAST_START, endDate: PAST_END, centerSquareType: 'none', sealedAt: iso(now), sealedCompletedCells: [],
    });
    await seedBoardTask(page, { id: bt(20), boardId: CLOSED, taskId: READ, row: 0, col: 0 });
    await page.goto(`/boards/${CLOSED}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Read 20 pages' }).click();
    const sheet = page.getByRole('dialog', { name: 'Read 20 pages' });
    await expect(sheet).toContainText('Closed');
    await expect(sheet.getByRole('button', { name: 'Log +1 pages' })).toHaveCount(0);
    await expect(sheet.getByRole('button', { name: /Remove/ })).toHaveCount(0);
    await sheet.getByRole('button', { name: 'Late log…' }).click();
    await expect(page.getByRole('dialog', { name: /Read 20 pages/ })).toBeVisible();
    expect((await readBoard(page, CLOSED))?.sealedCompletedCells).toEqual([]);
  });
});
