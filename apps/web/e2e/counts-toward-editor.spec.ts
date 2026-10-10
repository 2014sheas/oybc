import { test, expect, seedBoard, seedTask, seedBoardTask, readTask } from './_fixtures/bypass';
import {
  COUNTS_TOWARD_EDIT_BOARD_ID,
  COUNTS_TOWARD_EXPECTED_FORK_ID,
  COUNTS_TOWARD_OTHER_BOARD_ID,
  COUNTS_TOWARD_ROOT_ID,
  COUNTS_TOWARD_ROOT2_ID,
  COUNTS_TOWARD_TWO_BOARD_TASK_ID,
} from './_fixtures/countsTowardIds';

/**
 * "Counts toward" PR 4 (docs/SHARED_COUNTER_SETTINGS.md §3d; design handoff
 * §C2): the task editor's "Counts toward" row — set a counter, step the
 * amount, pick None — in the global sheet (Task Detail), and in the Board
 * Edit square sheet, where a task placed on two boards is forked first and
 * the flag lands on the fork. Every write goes through `setCountsToward`
 * (the `since` stamp proves it).
 */

const now = new Date();
const p = (n: number): string => String(n).padStart(2, '0');
const d = `${now.getFullYear()}-${p(now.getMonth() + 1)}-${p(now.getDate())}`;
const START = `${d}T00:00:00.000`;
const END = `${d}T23:59:59.999`;

const ROOT = COUNTS_TOWARD_ROOT_ID;
const ROOT2 = COUNTS_TOWARD_ROOT2_ID;
const BOARD = COUNTS_TOWARD_EDIT_BOARD_ID;
const OTHER = COUNTS_TOWARD_OTHER_BOARD_ID;
const TASK = COUNTS_TOWARD_TWO_BOARD_TASK_ID;
const SOLO = 'eeeeeeee-ctw0-0001-task-000000000011';

test.describe('Task editors — Counts toward row', () => {
  test.beforeEach(async ({ page }) => {
    await seedTask(page, { id: ROOT, title: 'Read 12 books', type: 'counting', action: 'Read', unit: 'books', maxCount: 12, isCounter: true, counterName: 'Books' });
    await seedTask(page, { id: ROOT2, title: 'Walk 100 miles', type: 'counting', action: 'Walk', unit: 'miles', maxCount: 100, isCounter: true, counterName: 'Miles' });
    await seedBoard(page, { id: BOARD, name: 'Edit board', boardSize: 3, timeframe: 'daily', status: 'active', startDate: START, endDate: END, centerSquareType: 'free' });
    await seedBoard(page, { id: OTHER, name: 'Other board', boardSize: 3, timeframe: 'daily', status: 'active', startDate: START, endDate: END, centerSquareType: 'free' });
    await seedTask(page, { id: SOLO, title: 'Finish Dune', type: 'normal' });
    await seedTask(page, { id: TASK, title: 'Book club', type: 'normal' });
    await seedBoardTask(page, { id: 'eeeeeeee-ctw0-0001-bt-000000000011', boardId: BOARD, taskId: SOLO, row: 0, col: 0 });
    await seedBoardTask(page, { id: 'eeeeeeee-ctw0-0001-bt-000000000010', boardId: BOARD, taskId: TASK, row: 0, col: 1 });
    await seedBoardTask(page, { id: 'eeeeeeee-ctw0-0002-bt-000000000010', boardId: OTHER, taskId: TASK, row: 0, col: 0 });
  });

  test('global sheet: None → Books, amount 2 (stamps since); re-point asks; None clears', async ({ page }) => {
    await page.goto(`/tasks/${SOLO}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Edit', exact: true }).click();
    const sheet = page.getByRole('dialog', { name: 'Edit task' });
    await expect(sheet.getByRole('group', { name: 'Amount' })).toHaveCount(0);

    await sheet.getByRole('button', { name: 'Counts toward: None' }).click();
    const listbox = sheet.getByRole('listbox', { name: 'Counters' });
    await expect(listbox.getByRole('option')).toHaveText([/None/, /Books.*Discrete.*all-time/, /Miles.*Discrete.*all-time/]);
    await listbox.getByRole('textbox', { name: 'Search counters' }).fill('boo');
    await expect(listbox.getByRole('option')).toHaveCount(2);
    await listbox.getByRole('option', { name: /Books/ }).click();
    await expect(sheet.getByRole('button', { name: 'Counts toward: Books' })).toBeVisible();
    const amount = sheet.getByRole('group', { name: 'Amount' });
    await amount.getByRole('button', { name: 'Less' }).click();
    await expect(amount).toContainText('1');
    await amount.getByRole('button', { name: 'More' }).click();
    await expect(amount).toContainText('2');
    await sheet.getByRole('button', { name: /save changes/i }).click();
    await expect(sheet).toHaveCount(0);
    const flagged = await readTask(page, SOLO);
    expect(flagged).toMatchObject({ countsTowardCounterId: ROOT, countsTowardAmount: 2 });
    expect(typeof flagged.countsTowardSince).toBe('string');

    // The board cell carries the two-dot mark while not done.
    await page.goto(`/boards/${BOARD}?__oybc_test_bypass=1`);
    await expect(page.getByRole('button', { name: 'Finish Dune' }).locator('[class*="sharedMarker"]')).toHaveCount(1);
    await expect(page.getByRole('button', { name: 'Book club' }).locator('[class*="sharedMarker"]')).toHaveCount(0);

    // Re-pointing an already-counting task asks first.
    await page.goto(`/tasks/${SOLO}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Edit', exact: true }).click();
    const again = page.getByRole('dialog', { name: 'Edit task' });
    await again.getByRole('button', { name: 'Counts toward: Books' }).click();
    await again.getByRole('listbox', { name: 'Counters' }).getByRole('option', { name: /Miles/ }).click();
    const confirm = page.getByRole('alertdialog', { name: 'Switch to Miles?' });
    await expect(confirm.getByText('Earlier credits on Books are withdrawn.')).toBeVisible();
    await confirm.getByRole('button', { name: 'Cancel' }).click();
    await expect(again.getByRole('button', { name: 'Counts toward: Books' })).toBeVisible();

    // None clears every field (the picker is still open after the cancelled switch).
    await again.getByRole('listbox', { name: 'Counters' }).getByRole('option', { name: 'None' }).click();
    await expect(again.getByRole('group', { name: 'Amount' })).toHaveCount(0);
    await again.getByRole('button', { name: /save changes/i }).click();
    await expect(again).toHaveCount(0);
    const cleared = await readTask(page, SOLO);
    expect(cleared.countsTowardCounterId).toBeUndefined();
    expect(cleared.countsTowardAmount).toBeUndefined();
    expect(cleared.countsTowardSince).toBeUndefined();
  });

  test('Board Edit square sheet: a task on two boards is forked first and the FORK counts toward Books', async ({ page }) => {
    await page.goto(`/boards/${BOARD}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Edit board' }).click();
    await page.getByRole('button', { name: /^Book club$/ }).click();
    await page.getByRole('button', { name: 'Edit task…' }).click();
    const sheet = page.getByRole('dialog', { name: 'Edit task' });
    await sheet.getByRole('button', { name: 'Counts toward: None' }).click();
    await sheet.getByRole('listbox', { name: 'Counters' }).getByRole('option', { name: /Books/ }).click();
    await sheet.getByRole('group', { name: 'Amount' }).getByRole('button', { name: 'More' }).click();
    await sheet.getByRole('button', { name: 'Save for this board' }).click();
    const confirm = page.getByRole('alertdialog', { name: 'Save for this board?' });
    await confirm.getByRole('button', { name: 'Save for this board' }).click();
    await page.getByRole('button', { name: 'Save changes' }).click();
    await expect(page.getByText('Board saved')).toBeVisible();

    const fork = await readTask(page, COUNTS_TOWARD_EXPECTED_FORK_ID);
    expect(fork).toMatchObject({ forkedFromTaskId: TASK, countsTowardCounterId: ROOT, countsTowardAmount: 2 });
    expect(typeof fork.countsTowardSince).toBe('string');
    const original = await readTask(page, TASK);
    expect(original.countsTowardCounterId).toBeUndefined();

    // Completing the forked square credits Books.
    await page.reload();
    await page.getByRole('button', { name: 'Book club' }).click();
    await expect.poll(async () => readTask(page, ROOT)).toMatchObject({ currentCount: 2 });
  });
});
