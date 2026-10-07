import type { Page } from '@playwright/test';
import { test, expect, seedTask, seedCompoundChild, openTab } from './_fixtures/bypass';

/**
 * Task Detail edits a compound's rule and sub-tasks (Compound Task Editing
 * After Creation, web). Seeds a 2-sub-task "All of" compound, then through
 * the real UI: Tasks tab → detail → Edit → type "Third" + Enter in the
 * sub-task quick-add row → "At least N of" (2 of 3) → Save. The detail's
 * Subtasks list shows three rows, survives a reload, and the stored row
 * carries the M-of-N rule. A second case links an EXISTING library task by
 * typing part of its title and clicking the match.
 */

const PARENT_ID = 'cccccccc-0001-0000-0000-000000000001';
const CHILD_A_ID = 'cccccccc-0002-0000-0000-000000000002';
const CHILD_B_ID = 'cccccccc-0003-0000-0000-000000000003';
const LIBRARY_ID = 'cccccccc-0004-0000-0000-000000000004';
const UNITLESS_ID = 'cccccccc-0005-0000-0000-000000000005';

/** Reads the stored counting child titled `title` straight from IndexedDB. */
async function readCountingChild(
  page: Page,
  title: string,
): Promise<{ type?: string; action?: string; maxCount?: number; unit?: string } | null> {
  return page.evaluate(async (wanted) => {
    return new Promise((resolve, reject) => {
      const openReq = indexedDB.open('oybc');
      openReq.onerror = () => reject(openReq.error);
      openReq.onsuccess = () => {
        const db = openReq.result;
        const req = db.transaction(['tasks'], 'readonly').objectStore('tasks').getAll();
        req.onsuccess = () => {
          db.close();
          const row = (req.result as Array<Record<string, unknown>>).find((r) => r.title === wanted && !r.isDeleted);
          resolve(
            row
              ? { type: row.type as string, action: row.action as string, maxCount: row.maxCount as number, unit: row.unit as string }
              : null,
          );
        };
        req.onerror = () => reject(req.error);
      };
    });
  }, title);
}

/** Reads the compound's stored rule straight from IndexedDB. */
async function readRule(page: Page): Promise<{ operator?: string; threshold?: number; version?: number }> {
  return page.evaluate(async (id) => {
    return new Promise((resolve, reject) => {
      const openReq = indexedDB.open('oybc');
      openReq.onerror = () => reject(openReq.error);
      openReq.onsuccess = () => {
        const db = openReq.result;
        const req = db.transaction(['tasks'], 'readonly').objectStore('tasks').get(id);
        req.onsuccess = () => {
          db.close();
          const row = req.result ?? {};
          resolve({ operator: row.operator, threshold: row.threshold, version: row.version });
        };
        req.onerror = () => reject(req.error);
      };
    });
  }, PARENT_ID);
}

test.describe('Task Detail — compound editing', () => {
  test.beforeEach(async ({ page }) => {
    await seedTask(page, { id: PARENT_ID, title: 'Workout routine', type: 'compound' });
    await seedTask(page, { id: CHILD_A_ID, title: 'Pushups', type: 'normal' });
    await seedTask(page, { id: CHILD_B_ID, title: 'Squats', type: 'normal' });
    await seedCompoundChild(page, {
      id: 'cccccccc-aaaa-0000-0000-000000000001',
      compoundTaskId: PARENT_ID,
      childTaskId: CHILD_A_ID,
      childIndex: 0,
    });
    await seedCompoundChild(page, {
      id: 'cccccccc-aaaa-0000-0000-000000000002',
      compoundTaskId: PARENT_ID,
      childTaskId: CHILD_B_ID,
      childIndex: 1,
    });
  });

  test('adds a sub-task and switches the rule to "at least 2 of 3"', async ({ page }) => {
    await openTab(page, 'Tasks');
    await page.getByRole('button', { name: /open workout routine details/i }).click();
    await expect(page).toHaveURL(new RegExp(`/tasks/${PARENT_ID}`));
    await expect(page.getByRole('heading', { name: 'Subtasks (2)' })).toBeVisible();
    await expect(page.getByText('All of 2', { exact: true })).toBeVisible();
    // The old "edited from the board-creation wizard" hint is gone.
    await expect(page.getByText(/board-creation wizard/i)).toHaveCount(0);

    await page.getByRole('button', { name: 'Edit', exact: true }).click();
    const sheet = page.getByRole('dialog', { name: 'Edit task' });
    // The editor seeds from the stored sub-tasks, in order.
    await expect(sheet.getByLabel('Sub-task 1 title')).toHaveValue('Pushups');
    await expect(sheet.getByLabel('Sub-task 2 title')).toHaveValue('Squats');

    // The wizard's quick-add row: Enter appends a NEW sub-task (even with
    // matches showing — a match is linked only by clicking it).
    await sheet.getByLabel('New normal task title').fill('Third');
    await sheet.getByLabel('New normal task title').press('Enter');
    await expect(sheet.getByLabel('Sub-task 3 title')).toHaveValue('Third');
    await expect(sheet.getByLabel('New normal task title')).toHaveValue('');
    await sheet.getByRole('button', { name: 'At least N of' }).click();
    await expect(sheet.getByText('of 3 sub-tasks')).toBeVisible();

    await sheet.getByRole('button', { name: /save changes/i }).click();
    await expect(sheet).toHaveCount(0);

    await expect(page.getByRole('heading', { name: 'Subtasks (3)' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Open subtask: Third' })).toBeVisible();
    await expect(page.getByText('2 of 3', { exact: true })).toBeVisible();
    expect(await readRule(page)).toMatchObject({ operator: 'M_OF_N', threshold: 2, version: 2 });

    // Persisted: a reload re-reads IndexedDB.
    await page.reload();
    await expect(page.getByRole('heading', { name: 'Subtasks (3)' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Open subtask: Third' })).toBeVisible();
    await expect(page.getByText('2 of 3', { exact: true })).toBeVisible();

    // Reopening the sheet shows the saved rule.
    await page.getByRole('button', { name: 'Edit', exact: true }).click();
    const reopened = page.getByRole('dialog', { name: 'Edit task' });
    await expect(reopened.getByLabel('Sub-task 3 title')).toHaveValue('Third');
    await expect(reopened.getByText('of 3 sub-tasks')).toBeVisible();
  });

  test('with the Counting chip on, the Goal / Counting row appears, gates Enter, and Save persists a counting child', async ({ page }) => {
    await page.goto(`/tasks/${PARENT_ID}?__oybc_test_bypass=1`);
    await expect(page.getByRole('heading', { name: 'Subtasks (2)' })).toBeVisible();
    await page.getByRole('button', { name: 'Edit', exact: true }).click();
    const sheet = page.getByRole('dialog', { name: 'Edit task' });
    await expect(sheet.getByLabel('Sub-task 2 title')).toHaveValue('Squats');

    // Normal on: no config row.
    const goal = sheet.getByRole('textbox', { name: 'Goal', exact: true });
    const unit = sheet.getByRole('textbox', { name: 'Counting*', exact: true });
    await expect(goal).toHaveCount(0);
    await sheet.getByRole('button', { name: 'Counting', exact: true }).click();
    await expect(goal).toBeVisible();
    await expect(unit).toBeVisible();
    const field = sheet.getByLabel('New normal task title');
    await expect(field).toHaveAttribute('placeholder', 'Do');

    // Text alone doesn't append — Enter is ignored until Goal + Counting are valid.
    await field.fill('Run');
    await expect(sheet.getByText('Reads as: Run — — — —')).toBeVisible();
    await expect(sheet.getByRole('button', { name: 'Add task' })).toBeDisabled();
    await field.press('Enter');
    await expect(sheet.getByLabel('Sub-task 3 title')).toHaveCount(0);
    await expect(field).toHaveValue('Run');

    await goal.fill('5');
    await unit.fill('km');
    await expect(sheet.getByText('Reads as: Run — 5 — km')).toBeVisible();
    await expect(sheet.getByRole('button', { name: 'Add task' })).toBeEnabled();
    await field.press('Enter');

    // The appended card is complete: derived title + editable Action/Goal/Unit.
    await expect(sheet.getByLabel('Sub-task 3 title')).toHaveValue('Run 5 km');
    await expect(sheet.getByLabel('Sub-task 3 action')).toHaveValue('Run');
    await expect(sheet.getByLabel('Sub-task 3 goal')).toHaveValue('5');
    await expect(sheet.getByLabel('Sub-task 3 unit')).toHaveValue('km');
    // The row clears and the chip is back on Normal for the next sub-task
    // (the create panel's behaviour), so the Goal / Counting row is gone.
    await expect(field).toHaveValue('');
    await expect(goal).toHaveCount(0);
    await expect(unit).toHaveCount(0);

    await sheet.getByRole('button', { name: /save changes/i }).click();
    await expect(sheet).toHaveCount(0);
    await expect(page.getByRole('heading', { name: 'Subtasks (3)' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Open subtask: Run 5 km' })).toBeVisible();
    expect(await readCountingChild(page, 'Run 5 km')).toEqual({ type: 'counting', action: 'Run', maxCount: 5, unit: 'km' });
  });

  test('saves a compound down to ONE sub-task; removing the last one is blocked', async ({ page }) => {
    // One sub-task is enough (2026-10-06, owner ask); zero stays blocked.
    await page.goto(`/tasks/${PARENT_ID}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Edit', exact: true }).click();
    const sheet = page.getByRole('dialog', { name: 'Edit task' });
    await expect(sheet.getByLabel('Sub-task 2 title')).toHaveValue('Squats');

    await sheet.getByRole('button', { name: 'Delete sub-task' }).nth(1).click();
    await expect(sheet.getByText('A compound task needs a sub-task.')).toHaveCount(0);
    await expect(sheet.getByRole('button', { name: /save changes/i })).toBeEnabled();
    await sheet.getByRole('button', { name: /save changes/i }).click();
    await expect(sheet).toHaveCount(0);
    await expect(page.getByRole('heading', { name: 'Subtasks (1)' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Open subtask: Pushups' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Open subtask: Squats' })).toHaveCount(0);

    // Persisted: a reload re-reads IndexedDB.
    await page.reload();
    await expect(page.getByRole('heading', { name: 'Subtasks (1)' })).toBeVisible();

    // Zero sub-tasks is still a block.
    await page.getByRole('button', { name: 'Edit', exact: true }).click();
    const reopened = page.getByRole('dialog', { name: 'Edit task' });
    await expect(reopened.getByLabel('Sub-task 1 title')).toHaveValue('Pushups');
    await reopened.getByRole('button', { name: 'Delete sub-task' }).first().click();
    await expect(reopened.getByText('A compound task needs a sub-task.')).toBeVisible();
    await expect(reopened.getByRole('button', { name: /save changes/i })).toBeDisabled();
  });

  test('an already-invalid compound (no sub-tasks left) can still be renamed', async ({ page }) => {
    // Drop BOTH links so the STORED structure fails validation.
    await page.goto(`/tasks/${PARENT_ID}?__oybc_test_bypass=1`);
    await seedCompoundChild(page, {
      id: 'cccccccc-aaaa-0000-0000-000000000001',
      compoundTaskId: PARENT_ID,
      childTaskId: CHILD_A_ID,
      childIndex: 0,
      isDeleted: true,
    });
    await seedCompoundChild(page, {
      id: 'cccccccc-aaaa-0000-0000-000000000002',
      compoundTaskId: PARENT_ID,
      childTaskId: CHILD_B_ID,
      childIndex: 1,
      isDeleted: true,
    });
    await page.reload();
    await expect(page.getByRole('heading', { name: 'Subtasks', exact: true })).toBeVisible();

    await page.getByRole('button', { name: 'Edit', exact: true }).click();
    const sheet = page.getByRole('dialog', { name: 'Edit task' });
    // The validation line still shows as a hint, but Save isn't blocked by it.
    await expect(sheet.getByText('A compound task needs a sub-task.')).toBeVisible();
    await sheet.getByLabel('Title', { exact: true }).fill('Arm day');
    await sheet.getByRole('button', { name: /save changes/i }).click();

    await expect(sheet).toHaveCount(0);
    await expect(page.getByRole('heading', { name: 'Arm day' })).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Subtasks', exact: true })).toBeVisible();
  });

  test('links an existing library task by typing and clicking its match', async ({ page }) => {
    await seedTask(page, { id: LIBRARY_ID, title: 'Stretch', type: 'normal' });
    // A counting task with no unit would fail save validation — never offered.
    await seedTask(page, { id: UNITLESS_ID, title: 'Read 10', type: 'counting', action: 'Read', maxCount: 10 });
    await page.goto(`/tasks/${PARENT_ID}?__oybc_test_bypass=1`);
    await expect(page.getByRole('heading', { name: 'Subtasks (2)' })).toBeVisible();

    await page.getByRole('button', { name: 'Edit', exact: true }).click();
    const sheet = page.getByRole('dialog', { name: 'Edit task' });
    await expect(sheet.getByLabel('Sub-task 2 title')).toHaveValue('Squats');
    const field = sheet.getByLabel('New normal task title');
    const matches = sheet.getByRole('list', { name: 'Matching library tasks' });

    // The unit-less counter is never offered; a current sub-task isn't either.
    await field.fill('Read');
    await expect(matches).toHaveCount(0);
    await field.fill('Squ');
    await expect(matches).toHaveCount(0);

    await field.fill('Stret');
    await matches.getByRole('button', { name: /Stretch/ }).click();
    await expect(matches).toHaveCount(0);
    await expect(field).toHaveValue('');
    // The picked task is linked as sub-task 3; no new task was created.
    await expect(sheet.getByLabel('Sub-task 3 title')).toHaveValue('Stretch');

    await sheet.getByRole('button', { name: /save changes/i }).click();
    await expect(sheet).toHaveCount(0);
    await expect(page.getByRole('heading', { name: 'Subtasks (3)' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Open subtask: Stretch' })).toBeVisible();

    await page.reload();
    await expect(page.getByRole('heading', { name: 'Subtasks (3)' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Open subtask: Stretch' })).toBeVisible();
    await page.getByRole('button', { name: 'Open subtask: Stretch' }).click();
    await expect(page).toHaveURL(new RegExp(`/tasks/${LIBRARY_ID}`));
  });
});
