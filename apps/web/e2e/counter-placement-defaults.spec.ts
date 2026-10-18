import type { Page } from '@playwright/test';
import { test, expect, seedBoard, seedTask, seedBoardTask, readTask } from './_fixtures/bypass';

/** Every non-deleted task row linking to `rootId` (raw IndexedDB). */
async function linkedTaskIds(page: Page, rootId: string): Promise<string[]> {
  return page.evaluate((id) => {
    return new Promise<string[]>((resolve, reject) => {
      const openReq = indexedDB.open('oybc');
      openReq.onerror = () => reject(openReq.error);
      openReq.onsuccess = () => {
        const db = openReq.result;
        const req = db.transaction(['tasks'], 'readonly').objectStore('tasks').getAll();
        req.onsuccess = () => {
          db.close();
          const rows = req.result as { id: string; sharedCounterId?: string; isDeleted?: boolean }[];
          resolve(rows.filter((r) => r.sharedCounterId === id && !r.isDeleted).map((r) => r.id));
        };
        req.onerror = () => reject(req.error);
      };
    });
  }, rootId);
}

/**
 * docs/SHARED_COUNTER_SETTINGS.md §2 + TASK_WINDOW_REWORK slice 3a — a shared
 * counter carrying a weekly default is found by a word of its title template,
 * and placing it on a WEEKLY board places the counter ITSELF with the default
 * as the placement's goal (`targetOverride`), titled from its templates. The defaults are seeded straight into IndexedDB (the counter sheet's
 * Defaults fields ship with the design-handoff UI PR).
 */

const now = new Date();
const p = (n: number): string => String(n).padStart(2, '0');
const d = `${now.getFullYear()}-${p(now.getMonth() + 1)}-${p(now.getDate())}`;

const BOARD_ID = 'dddddddd-cpd0-0001-0000-000000000000';
const ROOT = 'dddddddd-cpd0-0001-task-000000000001';
const FILLER = 'dddddddd-cpd0-0001-task-000000000002';

/** Every live `boardTasks` row on a board (raw IndexedDB). */
async function boardTaskRows(
  page: Page,
  boardId: string,
): Promise<{ taskId: string; targetOverride?: number; targetKind?: string }[]> {
  return page.evaluate((id) => {
    return new Promise<{ taskId: string; targetOverride?: number; targetKind?: string }[]>((resolve, reject) => {
      const openReq = indexedDB.open('oybc');
      openReq.onerror = () => reject(openReq.error);
      openReq.onsuccess = () => {
        const db = openReq.result;
        const req = db.transaction(['boardTasks'], 'readonly').objectStore('boardTasks').getAll();
        req.onsuccess = () => {
          db.close();
          const rows = req.result as { boardId: string; taskId: string; isDeleted?: boolean; targetOverride?: number; targetKind?: string }[];
          resolve(rows.filter((r) => r.boardId === id && !r.isDeleted));
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
      id: ROOT, title: 'Read 12 novels', type: 'counting', action: 'Read', unit: 'books', maxCount: 12,
      isCounter: true, counterName: 'Reading', titleTemplatePlural: 'Read #N novels', timeframeGoals: { weekly: 3 },
    });
  });

  test('Board Edit: search a template word → pick → the placement carries the weekly default + templated title', async ({ page }) => {
    await page.goto(`/boards/${BOARD_ID}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Edit board' }).click();
    await page.getByRole('button', { name: /^Empty square, row 3, column 2$/ }).click();
    await expect(page.getByRole('dialog', { name: /Add square/ })).toBeVisible();

    // "novels" is only in the counter's plural template — the shared match set finds it.
    await page.getByLabel('New normal task title').fill('novels');
    // The match row shows the counter's NAME and its kind — no goal slot (the goal shows once placed).
    const row = page.getByRole('list', { name: 'Matching library tasks' }).getByRole('button', { name: /Reading/ });
    await expect(row).toBeVisible();
    await expect(row).toContainText('Discrete');
    await expect(row).not.toContainText('Weekly · 3 books');
    await expect(row).not.toContainText('Read 12 novels');
    await row.click();

    await page.getByRole('button', { name: 'Save changes' }).click();
    await expect(page.getByText('Board saved')).toBeVisible();

    await page.reload();
    await expect(page.getByText('Read 3 novels')).toBeVisible();
    const placed = (await boardTaskRows(page, BOARD_ID)).find((r) => r.taskId === ROOT);
    expect(placed).toMatchObject({ targetOverride: 3, targetKind: 'discrete' });
    // Nothing is minted: the root keeps its own goal and no linked row exists.
    expect((await readTask(page, ROOT))?.maxCount).toBe(12);
    expect(await linkedTaskIds(page, ROOT)).toEqual([]);
  });

  test('Board Edit: a goal-less counter with no default places at the kind fallback — 7 on a weekly board', async ({ page }) => {
    const GOALLESS = 'dddddddd-cpd0-0001-task-000000000003';
    await seedTask(page, {
      id: GOALLESS, title: 'Pages', type: 'counting', action: 'Read', unit: 'pages', isCounter: true, currentCount: 40,
      counterName: 'Pages', titleTemplatePlural: 'Read #N pages!',
    });
    await page.goto(`/boards/${BOARD_ID}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Edit board' }).click();
    await page.getByRole('button', { name: /^Empty square, row 3, column 2$/ }).click();
    await expect(page.getByRole('dialog', { name: /Add square/ })).toBeVisible();

    await page.getByLabel('New normal task title').fill('pages');
    const list = page.getByRole('list', { name: 'Matching library tasks' });
    // A plain match row: the fallback resolves, so no Goal entry.
    await expect(list.getByLabel('Goal for Pages')).toHaveCount(0);
    await list.getByRole('button', { name: /Pages/ }).click();
    await expect(page.getByRole('dialog', { name: /Add square/ })).toHaveCount(0);

    await page.getByRole('button', { name: 'Save changes' }).click();
    await expect(page.getByText('Board saved')).toBeVisible();

    await page.reload();
    await expect(page.getByText('Read 7 pages!')).toBeVisible();
    const placed = (await boardTaskRows(page, BOARD_ID)).find((r) => r.taskId === GOALLESS);
    // The counter itself is placed with the fallback goal as its override;
    // nothing is written to the counter root and no copy is minted.
    expect(placed).toMatchObject({ targetOverride: 7, targetKind: 'discrete' });
    const root = await readTask(page, GOALLESS);
    expect(root).not.toHaveProperty('maxCount');
    expect(root).not.toHaveProperty('timeframeGoals');
    expect(await linkedTaskIds(page, GOALLESS)).toEqual([]);
  });
});
