import { test, expect, seedBoard, seedTask, seedBoardTask } from './_fixtures/bypass';

/**
 * Board Edit redesign slice 1 — per-square locks on web. Slice 3 (D7)
 * retired the Edit tasks ⇄ Rearrange sub-mode split: there is ONE grid now
 * (`SquaresEditGrid`), so "Rearrange pins it" is exercised on the SAME
 * grid a hold-drag from a locked square is attempted on, not a separate
 * toggle.
 *   1. Enter Edit squares, tap a square, "Lock in place", Save: the row is
 *      persisted, the lock chip shows on the board after a reload.
 *   2. The locked square is pinned in the squares editor: it never lifts,
 *      so a pointer drag from it changes nothing.
 *   3. A seeded-locked square offers "Unlock" in the tap menu.
 */

const BOARD_ID = 'aaaaaaaa-10c4-0000-0000-000000000001';
const ids = (n: number) => ({ task: `aaaaaaaa-10c4-task-0000-00000000000${n}`, bt: `aaaaaaaa-10c4-bt00-0000-00000000000${n}` });
const TITLES = ['Morning workout', 'Cook a meal', 'Call a friend', 'Read 50 pages', 'Write in journal', 'Take a walk', 'Stretch', 'Drink 8 glasses'];
const CELLS = [[0, 0], [0, 1], [0, 2], [1, 0], [1, 2], [2, 0], [2, 1], [2, 2]];

const now = new Date();
const p = (n: number): string => String(n).padStart(2, '0');
const d = `${now.getFullYear()}-${p(now.getMonth() + 1)}-${p(now.getDate())}`;

test.describe('Lock a square (Board Edit redesign slice 1/3)', () => {
  test.beforeEach(async ({ page }) => {
    await seedBoard(page, {
      id: BOARD_ID, name: 'Lock board', boardSize: 3, timeframe: 'monthly', status: 'active',
      startDate: `${d}T00:00:00.000`, endDate: `${d}T23:59:59.999`, centerSquareType: 'free',
    });
    for (let i = 0; i < TITLES.length; i++) {
      await seedTask(page, { id: ids(i).task, title: TITLES[i], type: 'normal' });
      await seedBoardTask(page, {
        id: ids(i).bt, boardId: BOARD_ID, taskId: ids(i).task, row: CELLS[i][0], col: CELLS[i][1],
        // Seed one square already locked (index 7, bottom-right).
        ...(i === 7 ? { isLocked: true } : {}),
      });
    }
  });

  test('lock via the tap menu, save, reload → chip persists; the squares editor pins it', async ({ page }) => {
    await page.goto(`/boards/${BOARD_ID}?__oybc_test_bypass=1`);
    await expect(page.getByText('Lock board').first()).toBeVisible();

    // Seeded lock is drawn on the board (not only in edit mode).
    await expect(page.getByRole('img', { name: 'Locked in place' })).toHaveCount(1);

    await page.getByRole('button', { name: /^edit squares/i }).click();
    await page.getByRole('button', { name: /Morning workout/ }).click();
    await page.getByRole('button', { name: 'Lock in place' }).click();

    // Staged: the lock chip is on the square, the counter reads one edit.
    await expect(page.getByRole('img', { name: 'Locked in place' })).toHaveCount(2);
    await expect(page.getByText(/^1$/).first()).toBeVisible();

    await page.getByRole('button', { name: 'Save changes' }).click();
    await expect(page.getByText('Board saved')).toBeVisible();

    await page.reload();
    await expect(page.getByText('Lock board').first()).toBeVisible();
    await expect(page.getByRole('img', { name: 'Locked in place' })).toHaveCount(2);

    // Re-enter editing: the locked square is pinned — a drag from it is a no-op.
    await page.getByRole('button', { name: /^edit squares/i }).click();
    const locked = page.locator(`[data-cid="${ids(0).bt}"]`);
    await expect(locked).toBeVisible();
    await expect(locked.locator('span[aria-hidden="true"] > i')).toHaveCount(0); // no grip handle
    const box = (await locked.boundingBox())!;
    await page.mouse.move(box.x + box.width / 2, box.y + box.height / 2);
    await page.mouse.down();
    await page.mouse.move(box.x + box.width * 1.6, box.y + box.height / 2, { steps: 8 });
    await page.mouse.up();
    // Still at slot 0 and the edit counter is still 0.
    await expect(page.locator('[data-wbcell="0"]')).toHaveAttribute('data-cid', ids(0).bt);
    await expect(page.getByText(/^0$/).first()).toBeVisible();
  });

  test('a locked square offers Unlock', async ({ page }) => {
    await page.goto(`/boards/${BOARD_ID}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: /^edit squares/i }).click();
    await page.getByRole('button', { name: /Drink 8 glasses/ }).click();
    await expect(page.getByRole('button', { name: 'Unlock' })).toBeVisible();
    await page.getByRole('button', { name: 'Unlock' }).click();
    await expect(page.getByRole('img', { name: 'Locked in place' })).toHaveCount(0);
  });
});
