import { test, expect, seedBoard, seedTask, seedBoardTask, seedTaskEvent, readTask } from './_fixtures/bypass';

/**
 * Board-scoped task edits PR 2 (docs/BOARD_SCOPED_TASK_EDITS.md): renaming a
 * task from Board Edit when it is also placed on another board affects THIS
 * board only. The sheet's Done reads "Save for this board", the first fork
 * asks once, this board shows the new title and stays completed (the
 * in-window completion migrates to the fork), and the other board keeps the
 * original task and title.
 */

const now = new Date();
const p = (n: number): string => String(n).padStart(2, '0');
const d = `${now.getFullYear()}-${p(now.getMonth() + 1)}-${p(now.getDate())}`;
const START = `${d}T00:00:00.000`;
const END = `${d}T23:59:59.999`;

const THIS_BOARD = 'cccccccc-bsed-0001-0000-000000000000';
const OTHER_BOARD = 'cccccccc-bsed-0002-0000-000000000000';
const TASK = 'cccccccc-bsed-0001-task-000000000001';

test.describe('Board-scoped edit — rename a task placed on two boards', () => {
  test.beforeEach(async ({ page }) => {
    await seedBoard(page, {
      id: THIS_BOARD, name: 'Scoped board', boardSize: 3, timeframe: 'daily', status: 'active',
      startDate: START, endDate: END, centerSquareType: 'free',
    });
    await seedBoard(page, {
      id: OTHER_BOARD, name: 'Other board', boardSize: 3, timeframe: 'daily', status: 'active',
      startDate: START, endDate: END, centerSquareType: 'free',
    });
    await seedTask(page, { id: TASK, title: 'Read a book', type: 'normal', isCompleted: true });
    await seedBoardTask(page, { id: 'cccccccc-bsed-0001-bt-000000000001', boardId: THIS_BOARD, taskId: TASK, row: 0, col: 0 });
    await seedBoardTask(page, { id: 'cccccccc-bsed-0002-bt-000000000001', boardId: OTHER_BOARD, taskId: TASK, row: 0, col: 0 });
    await seedTaskEvent(page, {
      id: 'cccccccc-bsed-0001-ev-000000000001', taskId: TASK, kind: 'completion', occurredAt: new Date().toISOString(),
    });
  });

  test('Save for this board → confirm → this board renamed and still completed; the other board unchanged', async ({ page }) => {
    await page.goto(`/boards/${THIS_BOARD}?__oybc_test_bypass=1`);
    await expect(page.getByRole('button', { name: 'Read a book' })).toHaveAttribute('aria-pressed', 'true');

    await page.getByRole('button', { name: 'Edit board' }).click();
    await page.getByRole('button', { name: /^Read a book$/ }).click();
    await page.getByRole('button', { name: 'Edit task…' }).click();
    const sheet = page.getByRole('dialog', { name: 'Edit task' });
    await sheet.getByLabel('Task name').fill('Read a chapter');
    await sheet.getByRole('button', { name: 'Save for this board' }).click();

    const confirm = page.getByRole('alertdialog', { name: 'Save for this board?' });
    await expect(confirm.getByText('Applies to this board only. Other boards keep the original.')).toBeVisible();
    await confirm.getByRole('button', { name: 'Save for this board' }).click();

    await page.getByRole('button', { name: 'Save changes' }).click();
    await expect(page.getByText('Board saved')).toBeVisible();

    await page.reload();
    const renamed = page.getByRole('button', { name: 'Read a chapter' });
    await expect(renamed).toBeVisible();
    await expect(renamed).toHaveAttribute('aria-pressed', 'true');
    // The original row is untouched (title + version).
    expect(await readTask(page, TASK)).toMatchObject({ title: 'Read a book', version: 1 });

    await page.goto(`/boards/${OTHER_BOARD}?__oybc_test_bypass=1`);
    const original = page.getByRole('button', { name: 'Read a book' });
    await expect(original).toBeVisible();
    await expect(original).toHaveAttribute('aria-pressed', 'true');
    await expect(page.getByRole('button', { name: 'Read a chapter' })).toHaveCount(0);
  });
});
