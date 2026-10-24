import { test, expect, readTask, seedBoard, seedBoardTask, seedCompoundChild, seedTask } from './_fixtures/bypass';

/**
 * Task Detail shell (docs/TASK_DETAIL_REDESIGN.md §A/B): one page, two
 * presentations. The hero's live control writes through the anchor placement
 * (the soonest-ending in-play board); segments All · Boards · Links · Activity;
 * the sheet's Done pill and return pill; no square in play → a counting task
 * logs all-time, any other type has no control.
 */

const now = new Date();
const iso = (d: Date): string => d.toISOString();
const START = iso(new Date(now.getTime() - 2 * 864e5));
const END = iso(new Date(now.getTime() + 5 * 864e5));
const LATER = iso(new Date(now.getTime() + 20 * 864e5));
const id = (n: number): string => `e7000000-0000-0000-0000-0000000000${String(n).padStart(2, '0')}`;
const READ = id(1);
const WALK = id(2);
const COMPOUND = id(3);
const WATCHER = id(4);
const LONE = id(5);
const BOARD = id(10);
const OTHER = id(11);
/** A segment pill (scoped: "All boards ›" jumps and nav tabs share names). */
const seg = (scope: import('@playwright/test').Page | import('@playwright/test').Locator, name: string | RegExp) =>
  scope.getByRole('group', { name: 'Task detail section' }).getByRole('button', { name });
const bt = (n: number): string => `e7000000-bt00-0000-0000-0000000000${String(n).padStart(2, '0')}`;

test.describe('Task Detail shell', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/boards?__oybc_test_bypass=1');
    await seedTask(page, { id: READ, title: 'Read 20 pages', type: 'counting', action: 'Read', unit: 'pages', maxCount: 20 });
    await seedTask(page, { id: WALK, title: 'Walk the dog', type: 'normal' });
    await seedTask(page, { id: COMPOUND, title: 'Daily wellness', type: 'compound' });
    await seedCompoundChild(page, { id: id(20), compoundTaskId: COMPOUND, childTaskId: WALK, childIndex: 0 });
    await seedCompoundChild(page, { id: id(21), compoundTaskId: COMPOUND, childTaskId: READ, childIndex: 1 });
    await seedTask(page, { id: LONE, title: 'Unplaced idea', type: 'counting', action: 'Do', unit: 'reps', maxCount: 5, description: 'Nobody has placed me' });
    await seedBoard(page, { id: BOARD, name: 'Week 42', boardSize: 3, timeframe: 'weekly', status: 'active', startDate: START, endDate: END, centerSquareType: 'none' });
    await seedBoard(page, { id: OTHER, name: 'Later board', boardSize: 3, timeframe: 'monthly', status: 'active', startDate: START, endDate: LATER, centerSquareType: 'none' });
    await seedTask(page, { id: WATCHER, title: 'Bingo on Week 42', type: 'achievement', referencedBoardId: BOARD, achievementTrigger: 'bingo' });
    await seedBoardTask(page, { id: bt(1), boardId: BOARD, taskId: READ, row: 0, col: 0 });
    await seedBoardTask(page, { id: bt(2), boardId: OTHER, taskId: READ, row: 0, col: 0 });
    await seedBoardTask(page, { id: bt(3), boardId: BOARD, taskId: COMPOUND, row: 0, col: 1 });
    await seedBoardTask(page, { id: bt(4), boardId: BOARD, taskId: WATCHER, row: 0, col: 2 });
  });

  test('Counting: kicker, anchor-anchored count, a chip logs at once and Undo restores; Boards + Activity follow', async ({ page }) => {
    await page.goto(`/tasks/${READ}?__oybc_test_bypass=1`);
    await expect(page.getByRole('heading', { level: 1, name: 'Read 20 pages' })).toBeVisible();
    await expect(page.getByText('COUNTING', { exact: true })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Log another amount' })).toHaveText('Other…');
    // The anchor is the soonest-ending board (Week 42), not "Later board".
    await expect(page.getByText('/ 20 pages · Week 42')).toBeVisible();
    await page.getByRole('button', { name: 'Log +10 pages' }).click();
    await expect(page.getByRole('status').getByText('Logged +10 pages · Week 42')).toBeVisible();
    await expect(page.getByText('10 to go · Week 42')).toBeVisible();
    await page.getByRole('button', { name: 'Undo', exact: true }).click();
    await expect(page.getByRole('status').getByText('Logged +10 pages · Week 42')).toHaveCount(0);
    await page.getByRole('button', { name: 'Log +1 pages' }).click();

    await seg(page, /^Boards/).click();
    const row = page.getByRole('button', { name: 'Open board Week 42' });
    await expect(row).toContainText('1/20');
    // The log is dated now, so it also falls inside the later board's window (read per board, not per anchor).
    await expect(page.getByRole('button', { name: 'Open board Later board' })).toContainText('1/20');

    await seg(page, 'Activity').click();
    await expect(page.getByText(/Logged \+1 pages · Week 42/).first()).toBeVisible();
    await expect(page.getByText(/^Placed on Week 42$/)).toBeVisible();
    await expect(page.getByText(/Completed 0× all-time/)).toBeVisible();
  });

  test('Normal hero: Mark done ↔ Done with its Undo strip', async ({ page }) => {
    await seedBoardTask(page, { id: bt(5), boardId: BOARD, taskId: WALK, row: 1, col: 0 });
    await page.goto(`/tasks/${WALK}?__oybc_test_bypass=1`);
    await expect(page.getByText('NOT DONE THIS WEEK')).toBeVisible();
    await page.getByRole('button', { name: 'Mark done' }).click();
    await expect(page.getByRole('button', { name: 'Done', exact: true })).toBeVisible();
    await expect(page.getByRole('status').getByText('Walk the dog · done')).toBeVisible();
    await page.getByRole('button', { name: 'Undo', exact: true }).click();
    await expect(page.getByRole('button', { name: 'Mark done' })).toBeVisible();
  });

  test('Compound hero: checklist is the control; Links lists the sub-tasks', async ({ page }) => {
    await page.goto(`/tasks/${COMPOUND}?__oybc_test_bypass=1`);
    await expect(page.getByText('COMPOUND · ALL OF 2')).toBeVisible();
    await expect(page.getByText('of 2 sub-tasks · Week 42')).toBeVisible();
    await page.getByRole('checkbox', { name: 'Walk the dog' }).click();
    await expect(page.getByText('Walk the dog · done')).toBeVisible();
    await seg(page, 'Links').click();
    await expect(page.getByRole('heading', { name: 'Sub-tasks (2)' })).toBeVisible();
  });

  test('Achievement hero: watched-board card with the closest line and Open ‹board›', async ({ page }) => {
    await page.goto(`/tasks/${WATCHER}?__oybc_test_bypass=1`);
    await expect(page.getByText('ACHIEVEMENT · FIRST BINGO')).toBeVisible();
    await expect(page.getByText('WATCHING')).toBeVisible();
    await expect(page.getByText('0 / 1 bingo')).toBeVisible();
    await expect(page.getByText(/Closest line · \d of 3/)).toBeVisible();
    await page.getByRole('button', { name: 'Open Week 42' }).click();
    await expect(page).toHaveURL(new RegExp(`/boards/${BOARD}|/boards/core/`));
  });

  test('No square in play: a counting task logs all-time with Undo; any other type has no control', async ({ page }) => {
    await page.goto(`/tasks/${LONE}?__oybc_test_bypass=1`);
    await expect(page.getByRole('heading', { level: 1, name: 'Unplaced idea' })).toBeVisible();
    await expect(page.getByText('Nobody has placed me')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Edit', exact: true })).toBeVisible();
    await expect(page.getByText('Tap to log')).toBeVisible();
    await page.getByRole('button', { name: 'Log +1 reps' }).click();
    await expect(page.getByRole('status').getByText('Logged +1 reps · All-time')).toBeVisible();
    await expect.poll(async () => (await readTask(page, LONE))?.currentCount).toBe(1);
    await page.getByRole('button', { name: 'Undo', exact: true }).click();
    await expect.poll(async () => (await readTask(page, LONE))?.currentCount).toBe(0);
    await seg(page, /^Boards/).click();
    await expect(page.getByText('Not on a board')).toBeVisible();

    await seedTask(page, { id: id(31), title: 'Someday chore', type: 'normal' });
    await page.goto(`/tasks/${id(31)}?__oybc_test_bypass=1`);
    await expect(page.getByRole('button', { name: 'Edit', exact: true })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Mark done' })).toHaveCount(0);
  });

  test('Library counter row opens Task Detail; the root anchors on its linked row\'s square and a log writes the root', async ({ page }) => {
    const ROOT = id(32);
    await seedTask(page, { id: ROOT, title: 'Read pages', type: 'counting', action: 'Read', unit: 'pages', isCounter: true });
    await seedTask(page, { id: id(33), title: 'Read 30 pages', type: 'counting', action: 'Read', unit: 'pages', maxCount: 30, sharedCounterId: ROOT, baseline: 0 });
    await seedBoardTask(page, { id: bt(6), boardId: BOARD, taskId: id(33), row: 1, col: 1 });
    await page.goto('/tasks?__oybc_test_bypass=1');
    await page.getByRole('button', { name: 'Open Read pages details' }).click();
    await expect(page).toHaveURL(new RegExp(`/tasks/${ROOT}`));
    await expect(page.getByText('/ 30 pages · Week 42')).toBeVisible();
    await page.getByRole('button', { name: 'Log +10 pages' }).click();
    await expect(page.getByRole('status').getByText('Logged +10 pages · Week 42')).toBeVisible();
    await expect.poll(async () => (await readTask(page, ROOT))?.currentCount).toBe(10);
  });

  test('A sub-task placed only through its compound drives that square', async ({ page }) => {
    await page.goto(`/tasks/${WALK}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Mark done' }).click();
    await expect(page.getByRole('button', { name: 'Done', exact: true })).toBeVisible();
    await page.goto(`/tasks/${COMPOUND}?__oybc_test_bypass=1`);
    await expect(page.getByRole('checkbox', { name: 'Walk the dog' })).toBeChecked();
  });

  test('⋯ menu: Delete task… opens the existing confirm; a plain counting task offers Use as shared counter, never counter settings', async ({ page }) => {
    await page.goto(`/tasks/${LONE}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Task options' }).click();
    const menu = page.getByRole('menu', { name: 'Task options' });
    await expect(menu.getByRole('menuitem')).toHaveText([/Use as shared counter/, /Delete task…/]);
    await menu.getByRole('menuitem', { name: 'Delete task…' }).click();
    await expect(page.getByRole('alertdialog')).toBeVisible();
  });

  test('⋯ menu keyboard: focus lands on the first item, arrows rove, Escape returns focus to ⋯; counter settings is counting-only', async ({ page }) => {
    await seedTask(page, { id: id(30), title: 'Pages counter', type: 'counting', action: 'Read', unit: 'pages', isCounter: true });
    await page.goto(`/tasks/${id(30)}?__oybc_test_bypass=1`);
    const dots = page.getByRole('button', { name: 'Task options' });
    await dots.click();
    const items = page.getByRole('menu', { name: 'Task options' }).getByRole('menuitem');
    await expect(items).toHaveText([/Open counter settings/, /Delete task…/]);
    await expect(items.first()).toBeFocused();
    await page.keyboard.press('ArrowDown');
    await expect(items.nth(1)).toBeFocused();
    await page.keyboard.press('Escape');
    await expect(page.getByRole('menu')).toHaveCount(0);
    await expect(dots).toBeFocused();
    // A counting task with no counter offers "Use as shared counter" instead; a Normal task offers neither.
    await page.goto(`/tasks/${READ}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Task options' }).click();
    await expect(page.getByRole('menu').getByRole('menuitem')).toHaveText([/Use as shared counter/, /Delete task…/]);
    await page.goto(`/tasks/${WALK}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Task options' }).click();
    await expect(page.getByRole('menu').getByRole('menuitem')).toHaveText([/Delete task…/]);
  });

  test('Sheet: Done pill, return pill after a swap (segment survives), board rows close or navigate', async ({ page }) => {
    await page.goto(`/boards/${BOARD}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Read 20 pages' }).click({ button: 'right' });
    await page.getByRole('menuitem', { name: 'Open in library' }).click();
    const sheet = page.getByRole('dialog', { name: 'Task detail' });
    await expect(sheet.getByRole('heading', { level: 1, name: 'Read 20 pages' })).toBeVisible();
    await expect(sheet.getByRole('button', { name: 'Done' })).toBeVisible();
    await expect(sheet.getByRole('button', { name: /Back to/ })).toHaveCount(0);

    // Swap to the parent compound through Links; the return pill names the previous task.
    await seg(sheet, 'Links').click();
    await sheet.getByRole('button', { name: 'Open parent task: Daily wellness' }).click();
    await expect(sheet.getByRole('heading', { level: 1, name: 'Daily wellness' })).toBeVisible();
    await expect(seg(sheet, 'Links')).toHaveAttribute('aria-pressed', 'true');
    await sheet.getByRole('button', { name: 'Back to Read 20 pages' }).click();
    await expect(sheet.getByRole('heading', { level: 1, name: 'Read 20 pages' })).toBeVisible();
    await expect(sheet.getByRole('button', { name: /Back to/ })).toHaveCount(0);

    // The board it came from just dismisses; another board navigates.
    await seg(sheet, /^Boards/).click();
    await sheet.getByRole('button', { name: 'Open board Week 42' }).click();
    await expect(sheet).toHaveCount(0);
    await expect(page).toHaveURL(new RegExp(`/boards/${BOARD}`));
    await page.getByRole('button', { name: 'Read 20 pages' }).click({ button: 'right' });
    await page.getByRole('menuitem', { name: 'Open in library' }).click();
    await seg(page.getByRole('dialog', { name: 'Task detail' }), /^Boards/).click();
    await page.getByRole('dialog', { name: 'Task detail' }).getByRole('button', { name: 'Open board Later board' }).click();
    await expect(page).toHaveURL(new RegExp(`/boards/${OTHER}`));
  });
});
