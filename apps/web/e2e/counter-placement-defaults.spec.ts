import type { Page } from '@playwright/test';
import { test, expect, seedBoard, seedTask, seedBoardTask, readTask } from './_fixtures/bypass';

/**
 * `derivedTaskId` from the shared package. A dynamic import, read through
 * `default` when present: `@oybc/shared` ships CommonJS, and Playwright's ESM
 * loader does not always see its re-exported names as named exports.
 */
async function derivedTaskId(boardId: string, rootId: string): Promise<string> {
  const mod = await import('@oybc/shared');
  const shared = (mod as unknown as { default?: typeof mod }).default ?? mod;
  return shared.derivedTaskId(boardId, rootId);
}

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
    // The match row shows the counter's NAME, its kind and the goal this board gets (the UI PR).
    const row = page.getByRole('list', { name: 'Matching library tasks' }).getByRole('button', { name: /Reading/ });
    await expect(row).toBeVisible();
    await expect(row).toContainText('Discrete');
    await expect(row).toContainText('Weekly · 3 books');
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

  test('Board Edit: a goal-less counter with no default — the row holds a Goal entry gating "+"; the typed goal is the copy\'s', async ({ page }) => {
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
    const plus = list.getByRole('button', { name: 'Add Pages' });
    await expect(plus).toBeDisabled();
    const goal = list.getByLabel('Goal for Pages');
    await expect(goal).toHaveAttribute('placeholder', 'Goal');
    await goal.fill('5');
    await expect(plus).toBeEnabled();
    await plus.click();
    // The picker closes on the pick; nothing was written to the counter root.
    await expect(page.getByRole('dialog', { name: /Add square/ })).toHaveCount(0);
    expect(await readTask(page, GOALLESS)).not.toHaveProperty('maxCount');

    await page.getByRole('button', { name: 'Save changes' }).click();
    await expect(page.getByText('Board saved')).toBeVisible();

    await page.reload();
    await expect(page.getByText('Read 5 pages!')).toBeVisible();
    const placed = await boardTaskIds(page, BOARD_ID);
    const copyId = placed.find((id) => id !== FILLER && id !== ROOT && id !== GOALLESS);
    // The placed row is the board's deterministic copy at the typed goal …
    expect(copyId).toBe(await derivedTaskId(BOARD_ID, GOALLESS));
    const copy = await readTask(page, copyId!);
    expect(copy?.maxCount).toBe(5);
    expect(copy?.sharedCounterId).toBe(GOALLESS);
    expect(await readTask(page, GOALLESS)).not.toHaveProperty('maxCount');
    // … and the pending linked row the pick built was never written: the copy is
    // the ONLY row linking to the counter, so Counter Detail lists one member.
    expect(await linkedTaskIds(page, GOALLESS)).toEqual([copyId]);
    await page.goto(`/profile/counters/${GOALLESS}?__oybc_test_bypass=1`);
    await expect(page.getByLabel(/^Read 5 pages!:/)).toHaveCount(1);
    // "Not counting now" holds only the unplaced root itself — never a ghost
    // "Read 5 pages!" member left over from the pick.
    const inactive = page.getByRole('list', { name: 'Inactive tasks not currently counting' });
    await expect(inactive.getByLabel(/^Read 5 pages!/)).toHaveCount(0);
    await expect(inactive.getByLabel(/— inactive$/)).toHaveCount(1);
    await expect(inactive.getByLabel(/^Pages — inactive$/)).toHaveCount(1);
  });
});
