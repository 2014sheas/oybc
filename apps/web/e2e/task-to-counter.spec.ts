import { test, expect, seedBoard, seedTask, seedBoardTask } from './_fixtures/bypass';

/**
 * Task → Shared counter navigation: a linked member's Task detail shows a
 * tappable counter-root row ({root} · total · ›) that opens Counter detail; the board-square
 * popup of a counting square has a "Task details" row that opens Task detail.
 */

const ROOT_ID = 'ffffffff-0001-0000-0000-0000000000a1';
const MEMBER_ID = 'ffffffff-0002-0000-0000-0000000000a2';
const BOARD_ID = 'ffffffff-bbbb-0000-0000-0000000000a3';
const TODAY = new Date().toISOString().slice(0, 10);
const NEXT_WEEK = new Date(Date.now() + 7 * 24 * 60 * 60 * 1000).toISOString().slice(0, 10);

test.describe('Task → counter navigation', () => {
  test.beforeEach(async ({ page }) => {
    await seedTask(page, {
      id: ROOT_ID, title: 'Push-ups', type: 'counting', action: 'Push-ups',
      unit: 'reps', maxCount: 100, currentCount: 12,
    });
    await seedTask(page, {
      id: MEMBER_ID, title: 'Push-ups weekly', type: 'counting', action: 'Push-ups',
      unit: 'reps', maxCount: 50, currentCount: 0, baseline: 0, sharedCounterId: ROOT_ID,
    });
    await seedBoard(page, {
      id: BOARD_ID, name: 'Weekly Push Board', boardSize: 3, timeframe: 'weekly',
      status: 'active', startDate: TODAY, endDate: NEXT_WEEK,
    });
    await seedBoardTask(page, {
      id: 'ffffffff-bt00-0000-0000-0000000000a4', boardId: BOARD_ID, taskId: MEMBER_ID, row: 0, col: 0,
    });
  });

  test('Linked-to row on a member opens the counter page', async ({ page }) => {
    await page.goto(`/tasks/${MEMBER_ID}?__oybc_test_bypass=1`);
    const row = page.getByRole('button', { name: 'Open Push-ups counter' });
    await expect(row).toBeVisible();
    await expect(row).toContainText('12 reps');
    await page.screenshot({ path: '.playwright-mcp/task-to-counter-detail.png' });
    await row.click();
    await expect(page).toHaveURL(new RegExp(`/profile/counters/${ROOT_ID}$`));
    await expect(page.getByText(/shared counter/i).first()).toBeVisible();
  });

  test('board-square popup Task details row opens the task sheet', async ({ page }) => {
    await page.goto(`/boards/${BOARD_ID}?__oybc_test_bypass=1`);
    // Active board: right-click → View Details opens the popup.
    await page.getByText('Push-ups weekly').first().click({ button: 'right' });
    await page.getByRole('button', { name: /View Details/ }).click();
    const details = page.getByRole('button', { name: 'Task details' });
    await expect(details).toBeVisible();
    await page.screenshot({ path: '.playwright-mcp/task-to-counter-popup.png' });
    await details.click();
    // The popup must be gone (not just covered) and the sheet must sit on
    // top: Playwright's click fails if another element would receive it.
    await expect(details).toBeHidden();
    const sheet = page.getByRole('dialog', { name: 'Task detail' });
    await expect(sheet).toBeVisible();
    await sheet.getByRole('button', { name: 'Done' }).click();
    await expect(sheet).toBeHidden();
  });
});
