import { test, expect, seedBoard, seedTask, seedBoardTask, seedTaskEvent, readTaskByTitle } from './_fixtures/bypass';
import { COUNTS_TOWARD_EDIT_BOARD_ID, COUNTS_TOWARD_ROOT_ID, COUNTS_TOWARD_ROOT2_ID } from './_fixtures/countsTowardIds';

/**
 * Unit tasks (docs/SHARED_COUNTER_SETTINGS.md §3; unit-tasks handoff §A/§B):
 * Counter Detail's "Unit tasks" section lists the tasks that credit one to a
 * Discrete counter — type badge · title · board line (+ progress) · StatusPill
 * · a persistent ✕ remove slot — In progress → Not started → Done; "+ New"
 * opens the task creator in from-counter mode (the counter's UnitTag under the
 * title, Simple / Counting / Compound, no auto-link); a counter with no unit
 * tasks shows the empty one-liner. Remove is immediate without credits and
 * confirms with them.
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

test.describe('Counter Detail — Unit tasks section', () => {
  test.beforeEach(async ({ page }) => {
    await seedTask(page, { id: ROOT, title: 'Read 12 books', type: 'counting', action: 'Read', unit: 'books', maxCount: 12, isCounter: true, counterName: 'Books' });
    await seedTask(page, { id: ROOT2, title: 'Walk 100 miles', type: 'counting', action: 'Walk', unit: 'miles', maxCount: 100, isCounter: true, counterName: 'Miles' });
    await seedBoard(page, { id: BOARD, name: 'Reading day', boardSize: 3, timeframe: 'daily', status: 'active', startDate: START, endDate: END, centerSquareType: 'free' });
    await seedTask(page, { id: DUNE, title: 'Finish Dune', type: 'normal', countsTowardCounterId: ROOT, countsTowardSince: SINCE });
    await seedTask(page, { id: PAGES, title: 'Read 250 pages', type: 'counting', action: 'Read', unit: 'pages', maxCount: 250, countsTowardCounterId: ROOT, countsTowardSince: SINCE });
    await seedTask(page, { id: LOOSE, title: 'Audiobook: Piranesi', type: 'normal', countsTowardCounterId: ROOT, countsTowardSince: SINCE });
    await seedBoardTask(page, { id: 'eeeeeeee-ctw0-0001-bt-000000000020', boardId: BOARD, taskId: DUNE, row: 0, col: 0 });
    await seedBoardTask(page, { id: 'eeeeeeee-ctw0-0001-bt-000000000021', boardId: BOARD, taskId: PAGES, row: 0, col: 1 });
    await seedTaskEvent(page, { id: 'eeeeeeee-ctw0-0001-ev-000000000021', taskId: PAGES, kind: 'increment', delta: 100, occurredAt: new Date().toISOString() });
  });

  test('lists the unit tasks In progress → Not started → Done with progress and a remove slot per row; a row opens Task Detail', async ({ page }) => {
    // Dune is completed on its board — the cascade credits the counter.
    await seedTaskEvent(page, { id: 'eeeeeeee-ctw0-0001-ev-000000000020', taskId: DUNE, kind: 'completion', occurredAt: new Date().toISOString() });
    await page.goto(`/profile/counters/${ROOT}?__oybc_test_bypass=1`);
    const section = page.getByRole('region', { name: 'Unit tasks' });
    await expect(section.getByText('Unit tasks · 3')).toBeVisible();
    const rows = section.getByRole('list', { name: 'Unit tasks of this counter' }).getByRole('listitem');
    await expect(rows).toHaveCount(3);
    await expect(rows.nth(0)).toContainText('Read 250 pages');
    await expect(rows.nth(0)).toContainText('Reading day');
    await expect(rows.nth(0)).toContainText('100 / 250 pages');
    await expect(rows.nth(0)).toContainText('In progress');
    await expect(rows.nth(1)).toContainText('Audiobook: Piranesi');
    await expect(rows.nth(1)).toContainText('Not started');
    await expect(rows.nth(1)).not.toContainText('Reading day');
    await expect(rows.nth(2)).toContainText('Finish Dune');
    await expect(rows.nth(2)).toContainText('Done');
    await expect(section.getByRole('button', { name: 'Remove from Books' })).toHaveCount(3);
    // A one-off unit task shows no credit count.
    await expect(section.getByText('×')).toHaveCount(0);

    await rows.nth(2).getByRole('button').first().click();
    await expect(page).toHaveURL(new RegExp(`/tasks/${DUNE}`));
  });

  test('"+ New" on an empty counter: the UnitTag under the title, Simple / Counting / Compound (no Achievement), no link hint, creates a unit task that wears the return ring', async ({ page }) => {
    await page.goto(`/profile/counters/${ROOT2}?__oybc_test_bypass=1`);
    const section = page.getByRole('region', { name: 'Unit tasks' });
    await expect(section.getByText('No unit tasks yet.')).toBeVisible();
    await expect(section.getByText('Unit tasks · ')).toHaveCount(0);

    await section.getByRole('button', { name: '+ New' }).click();
    const sheet = page.getByRole('dialog', { name: 'New task' });
    await expect(sheet.getByRole('img', { name: 'Unit task of Miles' })).toBeVisible();
    for (const label of ['Simple', 'Counting', 'Compound']) await expect(sheet.getByRole('button', { name: label, exact: true })).toBeVisible();
    await expect(sheet.getByRole('button', { name: 'Achievement', exact: true })).toHaveCount(0);
    // No task form carries the field: no "Counts toward" row anywhere in the sheet.
    await expect(sheet.getByText('Counts toward')).toHaveCount(0);

    // Counting shape: a (verb, unit) pair that would auto-link to "Miles" shows no link hint and does not link.
    await sheet.getByRole('button', { name: 'Counting', exact: true }).click();
    await sheet.getByLabel('Verb').fill('Walk');
    await sheet.getByLabel('Goal', { exact: true }).fill('5');
    await sheet.getByLabel(/^Counting/).fill('miles');
    await expect(sheet.getByRole('region', { name: 'Counter link' })).toHaveCount(0);
    await sheet.getByRole('button', { name: 'Add to library' }).click();
    await expect(sheet).toHaveCount(0);

    await expect.poll(async () => readTaskByTitle(page, 'Walk 5 miles')).toMatchObject({ countsTowardCounterId: ROOT2 });
    const created = (await readTaskByTitle(page, 'Walk 5 miles')) ?? {};
    expect(created.sharedCounterId ?? null).toBeNull();
    await expect(section.getByText('Unit tasks · 1')).toBeVisible();
    const row = section.getByRole('listitem');
    await expect(row).toContainText('Walk 5 miles');
    await expect(row).toHaveClass(/arrived/);
    // Cleared on the next interaction.
    await page.mouse.click(5, 5);
    await expect(row).not.toHaveClass(/arrived/);
  });

  test('"+ New" Simple creates a flagged unit task; Compound Review shows the Counter row with no subtasks required', async ({ page }) => {
    await page.goto(`/profile/counters/${ROOT2}?__oybc_test_bypass=1`);
    const section = page.getByRole('region', { name: 'Unit tasks' });
    await section.getByRole('button', { name: '+ New' }).click();
    let sheet = page.getByRole('dialog', { name: 'New task' });
    await sheet.getByRole('textbox', { name: /^Title/ }).fill('Walk to work');
    await sheet.getByRole('button', { name: 'Add to library' }).click();
    await expect(sheet).toHaveCount(0);
    await expect.poll(async () => readTaskByTitle(page, 'Walk to work')).toMatchObject({ countsTowardCounterId: ROOT2 });
    expect(((await readTaskByTitle(page, 'Walk to work')) ?? {}).countsTowardAmount ?? null).toBeNull();

    await section.getByRole('button', { name: '+ New' }).click();
    sheet = page.getByRole('dialog', { name: 'New task' });
    await sheet.getByRole('button', { name: 'Compound', exact: true }).click();
    await sheet.getByRole('textbox', { name: /^Title/ }).fill('Walking club night');
    await sheet.getByRole('button', { name: /Next/ }).click();
    await expect(sheet.getByText('Ready · no subtasks')).toBeVisible();
    await expect(sheet.getByText('No subtasks yet.')).toBeVisible();
    await sheet.getByRole('button', { name: /Next/ }).click();
    await expect(sheet.getByText('Counter', { exact: true })).toBeVisible();
    await expect(sheet.getByRole('img', { name: 'Unit task of Miles' })).toHaveCount(2);
    await sheet.getByRole('button', { name: 'Create Compound' }).click();
    await expect(sheet).toHaveCount(0);
    await expect.poll(async () => readTaskByTitle(page, 'Walking club night')).toMatchObject({ countsTowardCounterId: ROOT2 });
    const club = section.getByRole('listitem').filter({ hasText: 'Walking club night' });
    await expect(club).toContainText('No subtasks yet');
    // A zero-subtask compound has no remove control (it may only stay counting toward the counter).
    await expect(club.getByRole('button', { name: 'Remove from Miles' })).toHaveCount(0);
    await expect(section.getByRole('listitem').filter({ hasText: 'Walk to work' }).getByRole('button', { name: 'Remove from Miles' })).toHaveCount(1);
  });

  test('remove without credits is immediate: the row leaves, the task stays in the library', async ({ page }) => {
    await page.goto(`/profile/counters/${ROOT}?__oybc_test_bypass=1`);
    const section = page.getByRole('region', { name: 'Unit tasks' });
    await expect(section.getByText('Unit tasks · 3')).toBeVisible();
    await section.getByRole('listitem').filter({ hasText: 'Audiobook: Piranesi' }).getByRole('button', { name: 'Remove from Books' }).click();
    await expect(page.getByRole('alertdialog')).toHaveCount(0);
    await expect(section.getByText('Unit tasks · 2')).toBeVisible();
    await expect(section.getByText('Audiobook: Piranesi')).toHaveCount(0);
    const kept = (await readTaskByTitle(page, 'Audiobook: Piranesi')) ?? {};
    expect(kept.isDeleted ?? false).toBe(false);
    expect(kept.countsTowardCounterId ?? null).toBeNull();
  });

  test('remove with credits confirms and withdraws them; Cancel keeps the row', async ({ page }) => {
    // Completing Dune on its board credits the counter once (the cascade writes it).
    await page.goto(`/boards/${BOARD}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Finish Dune' }).click();
    await expect(page.getByRole('button', { name: 'Finish Dune' })).toHaveAttribute('aria-pressed', 'true');
    await page.goto(`/profile/counters/${ROOT}?__oybc_test_bypass=1`);
    const section = page.getByRole('region', { name: 'Unit tasks' });
    const dune = section.getByRole('listitem').filter({ hasText: 'Finish Dune' });
    await expect(dune).toContainText('Done');

    await dune.getByRole('button', { name: 'Remove from Books' }).click();
    const dialog = page.getByRole('alertdialog', { name: 'Remove from Books?' });
    await expect(dialog).toContainText("'Finish Dune' stays in your library. Its 1 credit on Books is withdrawn.");
    await dialog.getByRole('button', { name: 'Cancel' }).click();
    await expect(dune).toBeVisible();

    await dune.getByRole('button', { name: 'Remove from Books' }).click();
    await page.getByRole('alertdialog', { name: 'Remove from Books?' }).getByRole('button', { name: 'Remove' }).click();
    await expect(section.getByText('Unit tasks · 2')).toBeVisible();
    await expect(section.getByText('Finish Dune')).toHaveCount(0);
    const kept = (await readTaskByTitle(page, 'Finish Dune')) ?? {};
    expect(kept.isDeleted ?? false).toBe(false);
    expect(kept.countsTowardCounterId ?? null).toBeNull();
  });
});
