import { test, expect, seedBoard, seedTask, seedBoardTask, seedTaskEvent } from './_fixtures/bypass';
import type { Page } from '@playwright/test';

/**
 * Bingo + Greenlog moments (docs/BOARD_MOMENTS.md): completing a line opens the
 * full-screen Bingo moment, clearing the board opens the Greenlog moment. Both are
 * dismissed by Back to board / Escape; the Greenlog's "Start a new board" goes to
 * /create. Under reduced motion the replay is skipped and the end state shows.
 */

const BOARD_ID = 'aaaaaaaa-0b17-0000-0000-000000000001';
const id = (n: number) => ({ task: `aaaaaaaa-0b17-1000-0000-00000000000${n}`, bt: `aaaaaaaa-0b17-2000-0000-00000000000${n}` });
const CELLS = [[0, 0], [0, 1], [0, 2], [1, 0], [1, 2], [2, 0], [2, 1], [2, 2]];

const now = new Date();
const p = (n: number): string => String(n).padStart(2, '0');
const d = `${now.getFullYear()}-${p(now.getMonth() + 1)}-${p(now.getDate())}`;

/** Seed a 3x3 FREE-centre board with the first `done` cells already complete. */
async function seed(page: Page, done: number): Promise<void> {
  await seedBoard(page, {
    id: BOARD_ID, name: 'Moment board', boardSize: 3, timeframe: 'custom', status: 'active',
    startDate: `${d}T00:00:00.000`, endDate: `${d}T23:59:59.999`, centerSquareType: 'free',
  });
  for (let i = 0; i < CELLS.length; i++) {
    await seedTask(page, { id: id(i).task, title: `Cell ${i}`, type: 'normal' });
    await seedBoardTask(page, { id: id(i).bt, boardId: BOARD_ID, taskId: id(i).task, row: CELLS[i][0], col: CELLS[i][1] });
    if (i < done) {
      await seedTaskEvent(page, { id: `aaaaaaaa-0b17-3000-0000-00000000000${i}`, taskId: id(i).task, kind: 'completion', occurredAt: `${d}T00:00:${p(10 + i)}.000` });
    }
  }
}

test.describe('Bingo + Greenlog moments', () => {
  test('completing a line opens the Bingo moment; Back to board closes it', async ({ page }) => {
    await seed(page, 2);
    await page.goto(`/boards/${BOARD_ID}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: /Cell 2/ }).click();

    const moment = page.getByRole('dialog', { name: /Bingo/ });
    await expect(moment).toBeVisible();
    await expect(moment.getByText(/Line complete · 1 of 8/i)).toBeVisible();
    await expect(moment.getByText('BINGO!')).toBeVisible();
    await expect(moment.getByRole('button', { name: 'Share this bingo' })).toBeVisible();
    // Opaque and not tap-to-close: a click on the field leaves it open.
    await moment.click({ position: { x: 5, y: 5 } });
    await expect(moment).toBeVisible();

    await moment.getByRole('button', { name: 'Back to board' }).click();
    await expect(moment).toBeHidden();
    await expect(page.getByRole('button', { name: /Cell 2/ })).toBeVisible();
  });

  test('Escape closes the Bingo moment', async ({ page }) => {
    await seed(page, 2);
    await page.goto(`/boards/${BOARD_ID}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: /Cell 2/ }).click();
    const moment = page.getByRole('dialog', { name: /Bingo/ });
    await expect(moment).toBeVisible();
    await page.keyboard.press('Escape');
    await expect(moment).toBeHidden();
  });

  test('clearing the board opens the Greenlog moment; Start a new board goes to /create', async ({ page }) => {
    await seed(page, 7);
    await page.goto(`/boards/${BOARD_ID}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: /Cell 7/ }).click();

    const moment = page.getByRole('dialog', { name: /Board complete/ });
    await expect(moment).toBeVisible();
    await expect(moment.getByText('Board complete', { exact: true })).toBeVisible();
    await expect(moment.getByText('GREENLOG!')).toBeVisible();
    await moment.getByRole('button', { name: 'Start a new board' }).click();
    await expect(page).toHaveURL(/\/create/);
  });

  test('the Greenlog moment has a text Back to board that closes it', async ({ page }) => {
    await seed(page, 7);
    await page.goto(`/boards/${BOARD_ID}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: /Cell 7/ }).click();
    const moment = page.getByRole('dialog', { name: /Board complete/ });
    await expect(moment).toBeVisible();
    await moment.getByRole('button', { name: 'Back to board' }).click();
    await expect(moment).toBeHidden();
  });

  test('reduced motion skips the replay: every completed cell has landed at mount', async ({ page }) => {
    await page.emulateMedia({ reducedMotion: 'reduce' });
    await seed(page, 2);
    await page.goto(`/boards/${BOARD_ID}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: /Cell 2/ }).click();
    const moment = page.getByRole('dialog', { name: /Bingo/ });
    await expect(moment).toBeVisible();
    // 3 landed squares + the FREE centre = the rail's 4 of 9, immediately.
    await expect(moment.getByText('/9')).toBeVisible();
    await expect(moment.locator('div').filter({ hasText: /^4\/9$/ }).first()).toBeVisible({ timeout: 300 });
  });
});
