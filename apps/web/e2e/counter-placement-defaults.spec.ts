import type { Page } from '@playwright/test';
import { test, expect, seedBoard, seedTask, seedBoardTask, readTask } from './_fixtures/bypass';

/**
 * docs/SHARED_COUNTER_SETTINGS.md §2 (PR 2) — a shared counter carrying a
 * weekly default is found by a word of its title template, and placing it on
 * a WEEKLY board mints the per-board copy at that default with the templated
 * title. The defaults are seeded straight into IndexedDB (the counter sheet's
 * Defaults fields ship with the design-handoff UI PR).
 */

const now = new Date();
const p = (n: number): string => String(n).padStart(2, '0');
const d = `${now.getFullYear()}-${p(now.getMonth() + 1)}-${p(now.getDate())}`;

const BOARD_ID = 'dddddddd-cpd0-0001-0000-000000000000';
const ROOT = 'dddddddd-cpd0-0001-task-000000000001';
const FILLER = 'dddddddd-cpd0-0001-task-000000000002';

/** Every `boardTasks` row on a board (raw IndexedDB). */
async function boardTaskIds(page: Page, boardId: string): Promise<string[]> {
  return page.evaluate((id) => {
    return new Promise<string[]>((resolve, reject) => {
      const openReq = indexedDB.open('oybc');
      openReq.onerror = () => reject(openReq.error);
      openReq.onsuccess = () => {
        const db = openReq.result;
        const req = db.transaction(['boardTasks'], 'readonly').objectStore('boardTasks').getAll();
        req.onsuccess = () => {
          db.close();
          const rows = req.result as { boardId: string; taskId: string; isDeleted?: boolean }[];
          resolve(rows.filter((r) => r.boardId === id && !r.isDeleted).map((r) => r.taskId));
        };
        req.onerror = () => reject(req.error);
      };
    });
  }, boardId);
}

test.describe('Shared counter placement defaults', () => {
  test.beforeEach(async ({ page }) => {
    await seedBoard(page, {
      id: BOARD_ID, name: 'Reading week', boardSize: 3, timeframe: 'weekly', status: 'active',
      startDate: `${d}T00:00:00.000`, endDate: `${d}T23:59:59.999`, centerSquareType: 'free',
    });
    await seedTask(page, { id: FILLER, title: 'Morning workout', type: 'normal' });
    await seedBoardTask(page, { id: 'dddddddd-cpd0-0001-bt-000000000001', boardId: BOARD_ID, taskId: FILLER, row: 0, col: 0 });
    await seedTask(page, {
      id: ROOT, title: 'Read 12 books', type: 'counting', action: 'Read', unit: 'books', maxCount: 12,
      isCounter: true, counterName: 'Reading', titleTemplatePlural: 'Read #N novels', timeframeGoals: { weekly: 3 },
    });
  });

  test('Board Edit: search a template word → pick → the copy carries the weekly default + templated title', async ({ page }) => {
    await page.goto(`/boards/${BOARD_ID}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Edit board' }).click();
    await page.getByRole('button', { name: /^Empty square, row 3, column 2$/ }).click();
    await expect(page.getByRole('dialog', { name: /Add square/ })).toBeVisible();

    // "novels" is only in the counter's plural template — the shared match set finds it.
    await page.getByLabel('New normal task title').fill('novels');
    await page.getByRole('button', { name: /Read 12 books/ }).click();

    await page.getByRole('button', { name: 'Save changes' }).click();
    await expect(page.getByText('Board saved')).toBeVisible();

    await page.reload();
    await expect(page.getByText('Read 3 novels')).toBeVisible();
    const placed = await boardTaskIds(page, BOARD_ID);
    const copyId = placed.find((id) => id !== FILLER && id !== ROOT);
    expect(copyId).toBeDefined();
    const copy = await readTask(page, copyId!);
    expect(copy?.maxCount).toBe(3);
    expect(copy?.sharedCounterId).toBe(ROOT);
  });
});
