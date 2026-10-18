import { test, expect, seedBoard, seedTask, seedBoardTask } from './_fixtures/bypass';

/**
 * Unit tasks PR 2 (unit-tasks handoff §C/§D): the dense UnitTag is the first
 * item of a row's meta line for a unit task AND a linked copy (no new mark),
 * a counter's name finds its unit tasks, the quick-add match list shows the
 * counter's own row plus stand-alone unit rows, and Task Detail of a unit
 * task carries the "Counter" row into Counter Detail.
 */

const now = new Date();
const p = (n: number): string => String(n).padStart(2, '0');
const d = `${now.getFullYear()}-${p(now.getMonth() + 1)}-${p(now.getDate())}`;

const ROOT = 'ffffffff-ut20-0001-task-000000000001';
const COPY = 'ffffffff-ut20-0001-task-000000000002';
const DUNE = 'ffffffff-ut20-0001-task-000000000003';
const PAGES = 'ffffffff-ut20-0001-task-000000000004';
const WALK = 'ffffffff-ut20-0001-task-000000000005';
const BOARD = 'ffffffff-ut20-0001-0000-000000000001';
const SINCE = '2026-01-01T00:00:00.000Z';

test.describe('Unit task rows', () => {
  test.beforeEach(async ({ page }) => {
    await seedTask(page, { id: ROOT, title: 'Read 12 books', type: 'counting', action: 'Read', unit: 'books', maxCount: 12, isCounter: true, counterName: 'Books' });
    await seedTask(page, { id: COPY, title: 'Weekly reading', type: 'counting', action: 'Read', unit: 'books', maxCount: 2, sharedCounterId: ROOT });
    await seedTask(page, { id: DUNE, title: 'Finish Dune', type: 'normal', countsTowardCounterId: ROOT, countsTowardSince: SINCE });
    await seedTask(page, { id: PAGES, title: 'Read 300 pages', type: 'counting', action: 'Read', unit: 'pages', maxCount: 300, countsTowardCounterId: ROOT, countsTowardSince: SINCE });
    await seedTask(page, { id: WALK, title: 'Walk the dog', type: 'normal' });
    await seedBoard(page, { id: BOARD, name: 'Reading week', boardSize: 3, timeframe: 'weekly', status: 'active', startDate: `${d}T00:00:00.000`, endDate: `${d}T23:59:59.999`, centerSquareType: 'free' });
    await seedBoardTask(page, { id: 'ffffffff-ut20-0001-bt-000000000001', boardId: BOARD, taskId: WALK, row: 0, col: 0 });
  });

  test('Tasks tab: unit tasks wear the tag; a plain task does not', async ({ page }) => {
    await page.goto('/tasks?__oybc_test_bypass=1');
    const row = (title: string) => page.getByRole('button', { name: `Open ${title} details` });
    await expect(row('Finish Dune').getByRole('img', { name: 'Unit task of Books' })).toBeVisible();
    // A linked copy never lists here (the library shows one generic row per family).
    await expect(row('Weekly reading')).toHaveCount(0);
    await expect(row('Read 300 pages').getByRole('img', { name: 'Unit task of Books' })).toBeVisible();
    await expect(row('Walk the dog').getByRole('img')).toHaveCount(0);
  });

  test('Tasks tab: searching the counter name surfaces its unit tasks', async ({ page }) => {
    await page.goto('/tasks?__oybc_test_bypass=1');
    await page.getByLabel('Search tasks').fill('books');
    await expect(page.getByRole('button', { name: 'Open Finish Dune details' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Open Read 300 pages details' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Open Walk the dog details' })).toHaveCount(0);
  });

  test('quick-add "Books": the counter row plus stand-alone unit rows carrying the tag', async ({ page }) => {
    await page.goto(`/boards/${BOARD}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Edit board' }).click();
    await page.getByRole('button', { name: /^Empty square, row 3, column 2$/ }).click();
    await page.getByLabel('New normal task title').fill('Books');
    const list = page.getByRole('list', { name: 'Matching library tasks' });
    // The counter's own row keeps the kind tag.
    await expect(list.getByText('Discrete')).toBeVisible();
    const dune = list.getByRole('button', { name: /Finish Dune/ });
    await expect(dune).toBeVisible();
    await expect(dune.getByRole('img', { name: 'Unit task of Books' })).toBeVisible();
    await expect(list.getByRole('button', { name: /Read 300 pages/ }).getByRole('img', { name: 'Unit task of Books' })).toBeVisible();
  });

  test('a goal-less hub counter (no maxCount): its unit tasks still tag and match on quick-add', async ({ page }) => {
    const HUB = 'ffffffff-ut20-0001-task-000000000010';
    const HUBUNIT = 'ffffffff-ut20-0001-task-000000000011';
    await seedTask(page, { id: HUB, title: 'Hike', type: 'counting', action: 'Hike', unit: 'trails', isCounter: true, counterName: 'Trails' });
    await seedTask(page, { id: HUBUNIT, title: 'Hike Mount Tam', type: 'normal', countsTowardCounterId: HUB, countsTowardSince: SINCE });
    await page.goto('/tasks?__oybc_test_bypass=1');
    await expect(page.getByRole('button', { name: 'Open Hike Mount Tam details' }).getByRole('img', { name: 'Unit task of Trails' })).toBeVisible();
    await page.goto(`/boards/${BOARD}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Edit board' }).click();
    await page.getByRole('button', { name: /^Empty square, row 3, column 2$/ }).click();
    await page.getByLabel('New normal task title').fill('Trails');
    const row = page.getByRole('list', { name: 'Matching library tasks' }).getByRole('button', { name: /Hike Mount Tam/ });
    await expect(row.getByRole('img', { name: 'Unit task of Trails' })).toBeVisible();
  });

  test('Task Detail of a unit task: the Counter row opens Counter Detail', async ({ page }) => {
    await page.goto(`/tasks/${DUNE}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: /^Open Books counter$/ }).click();
    await expect(page).toHaveURL(new RegExp(`/profile/counters/${ROOT}`));
  });
});
