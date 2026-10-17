import { test, expect, seedBoard, seedBoardTask, seedCompoundChild, seedTask } from './_fixtures/bypass';

/**
 * The unified hold menu (docs/TASK_DETAIL_REDESIGN.md §PR 3): one vocabulary
 * per type, first item gold, writes raise the Undo toast, a closed board shows
 * the menu with a single "Late log…".
 */

const now = new Date();
const iso = (d: Date): string => d.toISOString();
const START = iso(new Date(now.getTime() - 2 * 864e5));
const END = iso(new Date(now.getTime() + 5 * 864e5));
const BOARD = 'e6000000-0000-0000-0000-000000000001';
const CLOSED = 'e6000000-0000-0000-0000-000000000002';
const READ = 'e6000000-0000-0000-0000-000000000010';
const NORMAL = 'e6000000-0000-0000-0000-000000000011';
const COMPOUND = 'e6000000-0000-0000-0000-000000000012';
const WALK = 'e6000000-0000-0000-0000-000000000013';
const bt = (n: number): string => `e6000000-bt00-0000-0000-0000000000${String(n).padStart(2, '0')}`;

test.describe('Square hold menu', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/boards?__oybc_test_bypass=1');
    await seedTask(page, { id: READ, title: 'Read 20 pages', type: 'counting', action: 'Read', unit: 'pages', maxCount: 20 });
    await seedTask(page, { id: NORMAL, title: 'Finish Dune', type: 'normal' });
    await seedTask(page, { id: WALK, title: 'Walk the dog', type: 'normal' });
    await seedTask(page, { id: COMPOUND, title: 'Daily wellness', type: 'compound' });
    await seedCompoundChild(page, { id: 'e6000000-cc00-0000-0000-000000000001', compoundTaskId: COMPOUND, childTaskId: WALK, childIndex: 0 });
    await seedBoard(page, { id: BOARD, name: 'Menu board', boardSize: 3, timeframe: 'weekly', status: 'active', startDate: START, endDate: END, centerSquareType: 'none' });
    await seedBoardTask(page, { id: bt(1), boardId: BOARD, taskId: READ, row: 0, col: 0 });
    await seedBoardTask(page, { id: bt(2), boardId: BOARD, taskId: NORMAL, row: 0, col: 1 });
    await seedBoardTask(page, { id: bt(3), boardId: BOARD, taskId: COMPOUND, row: 0, col: 2 });
  });

  test('Counting: the menu vocabulary; Log +1 writes with an Undo toast that reverses it', async ({ page }) => {
    await page.goto(`/boards/${BOARD}?__oybc_test_bypass=1`);
    const square = page.getByRole('button', { name: 'Read 20 pages' });
    await square.click({ button: 'right' });
    const menu = page.getByRole('menu', { name: 'Read 20 pages' });
    await expect(menu).toContainText('0 / 20');
    await expect(menu.getByRole('menuitem')).toHaveText([
      /Log \+1 pages/, /Log \+10 pages/, /Log other amount…/, /Remove pages…/, /Details/, /Open in library/,
    ]);
    await menu.getByRole('menuitem', { name: 'Log +1 pages' }).click();
    await expect(menu).toHaveCount(0);
    await expect(square).toContainText('1/20');
    const toast = page.getByRole('status').filter({ hasText: 'Logged +1 pages' });
    await expect(toast).toBeVisible();
    await toast.getByRole('button', { name: 'Undo' }).click();
    await expect(square).toContainText('0/20');
  });

  test('Counting: Log other amount… opens the sheet straight into its entry', async ({ page }) => {
    await page.goto(`/boards/${BOARD}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Read 20 pages' }).click({ button: 'right' });
    await page.getByRole('menuitem', { name: 'Log other amount…' }).click();
    const sheet = page.getByRole('dialog', { name: 'Read 20 pages' });
    await expect(sheet.getByLabel('Custom amount')).toBeFocused();
    await sheet.getByLabel('Custom amount').fill('4');
    await sheet.getByRole('button', { name: 'Log', exact: true }).click();
    await expect(sheet.getByText('Logged +4 pages')).toBeVisible();
  });

  test('Remove… opens the entry once: leaving through Library › never leaves the next tap on the entry', async ({ page }) => {
    await page.goto(`/boards/${BOARD}?__oybc_test_bypass=1`);
    const square = page.getByRole('button', { name: 'Read 20 pages' });
    await square.click();
    await page.getByRole('dialog', { name: 'Read 20 pages' }).getByRole('button', { name: 'Log +1 pages' }).click();
    await page.keyboard.press('Escape');
    await square.click({ button: 'right' });
    await page.getByRole('menuitem', { name: 'Remove pages…' }).click();
    const sheet = page.getByRole('dialog', { name: 'Read 20 pages' });
    await expect(sheet.getByLabel('Amount to remove')).toBeVisible();
    await sheet.getByRole('button', { name: 'Open in library' }).click();
    await page.getByRole('button', { name: /^Done/ }).click();
    await square.click();
    const again = page.getByRole('dialog', { name: 'Read 20 pages' });
    await expect(again.getByRole('button', { name: 'Log +1 pages' })).toBeVisible();
    await expect(again.getByLabel('Amount to remove')).toHaveCount(0);
  });

  test('an outside click closes the menu and focus returns to the held square; the menu keeps focus across re-renders', async ({ page }) => {
    await page.goto(`/boards/${BOARD}?__oybc_test_bypass=1`);
    const square = page.getByRole('button', { name: 'Read 20 pages' });
    await square.click({ button: 'right' });
    const menu = page.getByRole('menu');
    await expect(menu.getByRole('menuitem').first()).toBeFocused();
    await page.keyboard.press('ArrowDown');
    await expect(menu.getByRole('menuitem').nth(1)).toBeFocused();
    // A live-query re-render (an unrelated write) must not yank focus back to the first item.
    await page.evaluate(() => new Promise<void>((resolve) => setTimeout(resolve, 300)));
    await expect(menu.getByRole('menuitem').nth(1)).toBeFocused();
    await page.mouse.click(5, 5);
    await expect(menu).toHaveCount(0);
    await expect(square).toBeFocused();
  });

  test('Tab leaves the menu; only the focused item is a tab stop', async ({ page }) => {
    await page.goto(`/boards/${BOARD}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Read 20 pages' }).click({ button: 'right' });
    const items = page.getByRole('menu').getByRole('menuitem');
    await expect(items.first()).toHaveAttribute('tabindex', '0');
    await expect(items.nth(1)).toHaveAttribute('tabindex', '-1');
    await page.keyboard.press('Tab');
    await expect(page.getByRole('menu')).toHaveCount(0);
  });

  test('Compound: Complete next sub-task names the child and toasts with Undo', async ({ page }) => {
    await page.goto(`/boards/${BOARD}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Daily wellness' }).click({ button: 'right' });
    const next = page.getByRole('menuitem', { name: /Complete next sub-task/ });
    await expect(next).toContainText('Walk the dog');
    await expect(page.getByRole('menuitem', { name: /All sub-tasks…/ })).toContainText('0 / 1');
    await next.click();
    const toast = page.getByRole('status').filter({ hasText: 'Walk the dog · done' });
    await expect(toast).toBeVisible();
    await toast.getByRole('button', { name: 'Undo' }).click();
    await page.getByRole('button', { name: 'Daily wellness' }).click();
    await expect(page.getByRole('checkbox', { name: 'Walk the dog' })).toHaveAttribute('aria-checked', 'false');
  });

  test('Normal: Mark done toggles with the Normal toast; Escape closes the menu', async ({ page }) => {
    await page.goto(`/boards/${BOARD}?__oybc_test_bypass=1`);
    const square = page.getByRole('button', { name: 'Finish Dune' });
    await square.click({ button: 'right' });
    await expect(page.getByRole('menu')).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(page.getByRole('menu')).toHaveCount(0);
    await square.click({ button: 'right' });
    await page.getByRole('menuitem', { name: 'Mark done' }).click();
    await expect(square).toHaveAttribute('aria-pressed', 'true');
    await expect(page.getByRole('status').filter({ hasText: 'Finish Dune · done' })).toBeVisible();
  });
});

test.describe('Square hold menu — closed board', () => {
  test('shows the menu with one Late log…; it opens the late-log sheet', async ({ page }) => {
    await page.goto('/boards?__oybc_test_bypass=1');
    await seedTask(page, { id: READ, title: 'Read 20 pages', type: 'counting', action: 'Read', unit: 'pages', maxCount: 20 });
    await seedBoard(page, {
      id: CLOSED, name: 'Closed board', boardSize: 3, timeframe: 'monthly', status: 'active',
      startDate: iso(new Date(now.getTime() - 30 * 864e5)), endDate: iso(new Date(now.getTime() - 2 * 864e5)),
      centerSquareType: 'none', sealedAt: iso(now), sealedCompletedCells: [],
    });
    await seedBoardTask(page, { id: bt(20), boardId: CLOSED, taskId: READ, row: 0, col: 0 });
    await page.goto(`/boards/${CLOSED}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Read 20 pages' }).click({ button: 'right' });
    const menu = page.getByRole('menu');
    await expect(menu.getByRole('menuitem')).toHaveText([/Late log…/, /Details/, /Open in library/]);
    await menu.getByRole('menuitem', { name: 'Late log…' }).click();
    await expect(page.getByRole('dialog', { name: /Read 20 pages/ })).toBeVisible();
  });
});
