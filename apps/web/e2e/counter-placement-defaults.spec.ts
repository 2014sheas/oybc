import type { Page } from '@playwright/test';
import { test, expect, seedBoard, seedTask, seedBoardTask, readTask } from './_fixtures/bypass';
import {
  COUNTER_PLACEMENT_BOARD_ID,
  COUNTER_PLACEMENT_EXPECTED_COPY_ID,
  COUNTER_PLACEMENT_GOALLESS_ROOT_ID,
} from './_fixtures/counterPlacementIds';

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
 * docs/SHARED_COUNTER_SETTINGS.md §2 (PR 2) — a shared counter carrying a
 * weekly default is found by a word of its title template, and placing it on
 * a WEEKLY board mints the per-board copy at that default with the templated
 * title. The defaults are seeded straight into IndexedDB (the counter sheet's
 * Defaults fields ship with the design-handoff UI PR).
 */

const now = new Date();
const p = (n: number): string => String(n).padStart(2, '0');
const d = `${now.getFullYear()}-${p(now.getMonth() + 1)}-${p(now.getDate())}`;

const BOARD_ID = COUNTER_PLACEMENT_BOARD_ID;
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
    // The match row shows the counter's NAME and its kind — no goal slot (the goal shows once placed).
    const row = page.getByRole('list', { name: 'Matching library tasks' }).getByRole('button', { name: /Reading/ });
    await expect(row).toBeVisible();
    await expect(row).toContainText('Discrete');
    await expect(row).not.toContainText('Weekly · 3 books');
    await expect(row).not.toContainText('Read 12 books');
    await row.click();

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

  test('Board Edit: a goal-less counter with no default places at the kind fallback — 7 on a weekly board', async ({ page }) => {
    const GOALLESS = COUNTER_PLACEMENT_GOALLESS_ROOT_ID;
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
    const placed = await boardTaskIds(page, BOARD_ID);
    const copyId = placed.find((id) => id !== FILLER && id !== ROOT && id !== GOALLESS);
    // The placed row is the board's deterministic copy at the fallback goal
    // (`derivedTaskId(BOARD_ID, GOALLESS)` — pinned by `counterPlacementIds.test.ts`);
    // nothing is written to the counter root.
    expect(copyId).toBe(COUNTER_PLACEMENT_EXPECTED_COPY_ID);
    const copy = await readTask(page, copyId!);
    expect(copy?.maxCount).toBe(7);
    expect(copy?.sharedCounterId).toBe(GOALLESS);
    const root = await readTask(page, GOALLESS);
    expect(root).not.toHaveProperty('maxCount');
    expect(root).not.toHaveProperty('timeframeGoals');
    expect(await linkedTaskIds(page, GOALLESS)).toEqual([copyId]);
  });
});
