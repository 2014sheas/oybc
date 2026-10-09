import { test, expect, seedBoard, seedTask, seedBoardTask, openTab, readTask } from './_fixtures/bypass';

/**
 * The global editor's type switch: Tasks tab → ✎ → Type "Counting" → Action /
 * Goal / Unit → Save changes. The edit is global and retroactive: BOTH boards
 * placing the task now show it as a counting cell (0/5), and the stored row is
 * the same task (same id), now type counting.
 */

const now = new Date();
const p = (n: number): string => String(n).padStart(2, '0');
const d = `${now.getFullYear()}-${p(now.getMonth() + 1)}-${p(now.getDate())}`;
const START = `${d}T00:00:00.000`;
const END = `${d}T23:59:59.999`;

const BOARD_A = 'cccccccc-tsw0-0001-0000-000000000000';
const BOARD_B = 'cccccccc-tsw0-0002-0000-000000000000';
const TASK = 'cccccccc-tsw0-0001-task-000000000001';

test.describe('Global editor — type switch', () => {
  test.beforeEach(async ({ page }) => {
    for (const [id, name] of [[BOARD_A, 'Board A'], [BOARD_B, 'Board B']]) {
      await seedBoard(page, {
        id, name, boardSize: 3, timeframe: 'daily', status: 'active',
        startDate: START, endDate: END, centerSquareType: 'free',
      });
    }
    await seedTask(page, { id: TASK, title: 'Run', type: 'normal' });
    await seedBoardTask(page, { id: 'cccccccc-tsw0-0001-bt-000000000001', boardId: BOARD_A, taskId: TASK, row: 0, col: 0 });
    await seedBoardTask(page, { id: 'cccccccc-tsw0-0002-bt-000000000001', boardId: BOARD_B, taskId: TASK, row: 0, col: 0 });
  });

  test('Simple → Counting from the Tasks tab turns the square into a counting cell on both boards', async ({ page }) => {
    await openTab(page, 'Tasks');
    await page.getByRole('button', { name: 'Edit Run' }).click();
    const sheet = page.getByRole('dialog', { name: 'Edit task' });
    await sheet.getByRole('button', { name: 'Counting', exact: true }).click();
    await sheet.getByLabel('Action', { exact: true }).fill('Run');
    await sheet.getByRole('textbox', { name: 'Goal', exact: true }).fill('5');
    await sheet.getByLabel('Unit', { exact: true }).fill('km');
    await sheet.getByLabel('Title', { exact: true }).fill('Run 5 km');
    await sheet.getByRole('button', { name: /save changes/i }).click();
    await expect(sheet).toHaveCount(0);

    expect(await readTask(page, TASK)).toMatchObject({ type: 'counting', action: 'Run', maxCount: 5, unit: 'km' });

    for (const board of [BOARD_A, BOARD_B]) {
      await page.goto(`/boards/${board}?__oybc_test_bypass=1`);
      await expect(page.getByRole('button', { name: 'Run 5 km' })).toContainText('0/5');
    }
  });
});
