import { test, expect, seedBoard, seedTask, seedBoardTask, seedTaskEvent, readTaskByTitle } from './_fixtures/bypass';
import { COUNTS_TOWARD_EDIT_BOARD_ID, COUNTS_TOWARD_ROOT_ID, COUNTS_TOWARD_ROOT2_ID } from './_fixtures/countsTowardIds';

/**
 * "Counts toward" PR 4 (docs/SHARED_COUNTER_SETTINGS.md §3d; design handoff
 * §C1): Counter Detail's "Counts toward" section lists the tasks that count
 * toward a Discrete counter — type badge · title · primary board · "+N"
 * amount · StatusPill — with "+ New" opening the task creator preset to the
 * counter; a counter nothing counts toward shows the empty one-liner.
 */

const now = new Date();
const p = (n: number): string => String(n).padStart(2, '0');
const d = `${now.getFullYear()}-${p(now.getMonth() + 1)}-${p(now.getDate())}`;
const START = `${d}T00:00:00.000`;
const END = `${d}T23:59:59.999`;

const ROOT = COUNTS_TOWARD_ROOT_ID;
const ROOT2 = COUNTS_TOWARD_ROOT2_ID;
const BOARD = COUNTS_TOWARD_EDIT_BOARD_ID;
const DUNE = 'eeeeeeee-ctw0-0001-task-000000000020';
const PAGES = 'eeeeeeee-ctw0-0001-task-000000000021';
const LOOSE = 'eeeeeeee-ctw0-0001-task-000000000022';
const SINCE = '2026-01-01T00:00:00.000Z';

test.describe('Counter Detail — Counts toward section', () => {
  test.beforeEach(async ({ page }) => {
    await seedTask(page, { id: ROOT, title: 'Read 12 books', type: 'counting', action: 'Read', unit: 'books', maxCount: 12, isCounter: true, counterName: 'Books' });
    await seedTask(page, { id: ROOT2, title: 'Walk 100 miles', type: 'counting', action: 'Walk', unit: 'miles', maxCount: 100, isCounter: true, counterName: 'Miles' });
    await seedBoard(page, { id: BOARD, name: 'Reading day', boardSize: 3, timeframe: 'daily', status: 'active', startDate: START, endDate: END, centerSquareType: 'free' });
    await seedTask(page, { id: DUNE, title: 'Finish Dune', type: 'normal', countsTowardCounterId: ROOT, countsTowardSince: SINCE });
    await seedTask(page, { id: PAGES, title: 'Read 250 pages', type: 'counting', action: 'Read', unit: 'pages', maxCount: 250, countsTowardCounterId: ROOT, countsTowardAmount: 2, countsTowardSince: SINCE });
    await seedTask(page, { id: LOOSE, title: 'Audiobook: Piranesi', type: 'normal', countsTowardCounterId: ROOT, countsTowardSince: SINCE });
    await seedBoardTask(page, { id: 'eeeeeeee-ctw0-0001-bt-000000000020', boardId: BOARD, taskId: DUNE, row: 0, col: 0 });
    await seedBoardTask(page, { id: 'eeeeeeee-ctw0-0001-bt-000000000021', boardId: BOARD, taskId: PAGES, row: 0, col: 1 });
    await seedTaskEvent(page, { id: 'eeeeeeee-ctw0-0001-ev-000000000020', taskId: DUNE, kind: 'completion', occurredAt: new Date().toISOString() });
    await seedTaskEvent(page, { id: 'eeeeeeee-ctw0-0001-ev-000000000021', taskId: PAGES, kind: 'increment', delta: 100, occurredAt: new Date().toISOString() });
  });

  test('lists the contributors as drawn, ordered Done → In progress → Not started; a row opens Task Detail', async ({ page }) => {
    await page.goto(`/profile/counters/${ROOT}?__oybc_test_bypass=1`);
    const section = page.getByRole('region', { name: 'Counts toward' });
    await expect(section.getByText('Counts toward · 3 tasks')).toBeVisible();
    const rows = section.getByRole('list', { name: 'Tasks that count toward this counter' }).getByRole('listitem');
    await expect(rows).toHaveCount(3);
    await expect(rows.nth(0)).toContainText('Finish Dune');
    await expect(rows.nth(0)).toContainText('Reading day');
    await expect(rows.nth(0)).toContainText('Done');
    await expect(rows.nth(1)).toContainText('Read 250 pages');
    await expect(rows.nth(1)).toContainText('+2');
    await expect(rows.nth(1)).toContainText('In progress');
    await expect(rows.nth(2)).toContainText('Audiobook: Piranesi');
    await expect(rows.nth(2)).toContainText('Not started');
    await expect(rows.nth(2)).not.toContainText('Reading day');
    // A one-off contributor shows no credit count.
    await expect(section.getByText('×')).toHaveCount(0);

    await rows.nth(0).getByRole('button').click();
    await expect(page).toHaveURL(new RegExp(`/tasks/${DUNE}`));
  });

  test('a counter nothing counts toward shows the empty one-liner; "+ New" opens the creator preset to it', async ({ page }) => {
    await page.goto(`/profile/counters/${ROOT2}?__oybc_test_bypass=1`);
    const section = page.getByRole('region', { name: 'Counts toward' });
    await expect(section.getByText('Nothing counts toward Miles yet.')).toBeVisible();
    await expect(section.getByText('Counts toward · ')).toHaveCount(0);

    await section.getByRole('button', { name: '+ New' }).click();
    const sheet = page.getByRole('dialog', { name: 'New task' });
    await expect(sheet.getByRole('button', { name: 'Counts toward: Miles' })).toBeVisible();
    await sheet.getByRole('textbox', { name: /^Title/ }).fill('Walk to work');
    await sheet.getByRole('button', { name: 'Add to library' }).click();
    await expect(sheet).toHaveCount(0);

    await expect.poll(async () => readTaskByTitle(page, 'Walk to work')).toMatchObject({ countsTowardCounterId: ROOT2, countsTowardAmount: 1 });
    await expect(section.getByText('Counts toward · 1 task')).toBeVisible();
    await expect(section.getByRole('listitem')).toContainText('Walk to work');
  });
});
