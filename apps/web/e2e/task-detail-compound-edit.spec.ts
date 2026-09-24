import type { Page } from '@playwright/test';
import { test, expect, seedTask, seedCompoundChild, openTab } from './_fixtures/bypass';

/**
 * Task Detail edits a compound's rule and sub-tasks (Compound Task Editing
 * After Creation, web). Seeds a 2-sub-task "All of" compound, then through
 * the real UI: Tasks tab → detail → Edit → "+ Normal sub-task" "Third" →
 * "At least N of" (2 of 3) → Save. The detail's Subtasks list shows three
 * rows, survives a reload, and the stored row carries the M-of-N rule.
 * A second case links an EXISTING library task through "+ Existing task…".
 */

const PARENT_ID = 'cccccccc-0001-0000-0000-000000000001';
const CHILD_A_ID = 'cccccccc-0002-0000-0000-000000000002';
const CHILD_B_ID = 'cccccccc-0003-0000-0000-000000000003';
const LIBRARY_ID = 'cccccccc-0004-0000-0000-000000000004';
const UNITLESS_ID = 'cccccccc-0005-0000-0000-000000000005';

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

    await sheet.getByRole('button', { name: '+ Normal sub-task' }).click();
    await sheet.getByLabel('Sub-task 3 title').fill('Third');
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

  test('blocks saving a compound down to one sub-task', async ({ page }) => {
    await page.goto(`/tasks/${PARENT_ID}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Edit', exact: true }).click();
    const sheet = page.getByRole('dialog', { name: 'Edit task' });
    await expect(sheet.getByLabel('Sub-task 2 title')).toHaveValue('Squats');

    await sheet.getByRole('button', { name: 'Delete sub-task' }).nth(1).click();
    await expect(sheet.getByText('A compound task needs at least two sub-tasks.')).toBeVisible();
    await expect(sheet.getByRole('button', { name: /save changes/i })).toBeDisabled();
  });

  test('an already-invalid compound (one sub-task left) can still be renamed', async ({ page }) => {
    // Drop Squats' link so the STORED structure fails validation.
    await page.goto(`/tasks/${PARENT_ID}?__oybc_test_bypass=1`);
    await seedCompoundChild(page, {
      id: 'cccccccc-aaaa-0000-0000-000000000002',
      compoundTaskId: PARENT_ID,
      childTaskId: CHILD_B_ID,
      childIndex: 1,
      isDeleted: true,
    });
    await page.reload();
    await expect(page.getByRole('heading', { name: 'Subtasks (1)' })).toBeVisible();

    await page.getByRole('button', { name: 'Edit', exact: true }).click();
    const sheet = page.getByRole('dialog', { name: 'Edit task' });
    await expect(sheet.getByLabel('Sub-task 1 title')).toHaveValue('Pushups');
    // The validation line still shows as a hint, but Save isn't blocked by it.
    await expect(sheet.getByText('A compound task needs at least two sub-tasks.')).toBeVisible();
    await sheet.getByLabel('Title', { exact: true }).fill('Arm day');
    await sheet.getByRole('button', { name: /save changes/i }).click();

    await expect(sheet).toHaveCount(0);
    await expect(page.getByRole('heading', { name: 'Arm day' })).toBeVisible();
    await expect(page.getByRole('heading', { name: 'Subtasks (1)' })).toBeVisible();
  });

  test('links an existing library task through "+ Existing task…"', async ({ page }) => {
    await seedTask(page, { id: LIBRARY_ID, title: 'Plank', type: 'normal' });
    // A counting task with no unit would fail save validation — never offered.
    await seedTask(page, { id: UNITLESS_ID, title: 'Read 10', type: 'counting', action: 'Read', maxCount: 10 });
    await page.goto(`/tasks/${PARENT_ID}?__oybc_test_bypass=1`);
    await expect(page.getByRole('heading', { name: 'Subtasks (2)' })).toBeVisible();

    await page.getByRole('button', { name: 'Edit', exact: true }).click();
    const sheet = page.getByRole('dialog', { name: 'Edit task' });
    await expect(sheet.getByLabel('Sub-task 2 title')).toHaveValue('Squats');
    await sheet.getByRole('button', { name: '+ Existing task…' }).click();

    const picker = page.getByRole('dialog', { name: 'Add an existing task' });
    const rows = picker.getByRole('list', { name: 'Tasks you can add' });
    await expect(rows.getByRole('button', { name: 'Add Plank' })).toBeVisible();
    // Current sub-tasks, the compound itself and the unit-less counter are hidden.
    await expect(rows.getByRole('button', { name: /Add (Pushups|Squats|Workout routine|Read 10)/ })).toHaveCount(0);
    await picker.getByLabel('Search tasks').fill('pla');
    await rows.getByRole('button', { name: 'Add Plank' }).click();
    await expect(picker).toHaveCount(0);
    // The edit sheet stays open with the picked task as sub-task 3.
    await expect(sheet.getByLabel('Sub-task 3 title')).toHaveValue('Plank');

    await sheet.getByRole('button', { name: /save changes/i }).click();
    await expect(sheet).toHaveCount(0);
    await expect(page.getByRole('heading', { name: 'Subtasks (3)' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Open subtask: Plank' })).toBeVisible();

    await page.reload();
    await expect(page.getByRole('heading', { name: 'Subtasks (3)' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Open subtask: Plank' })).toBeVisible();
  });

  test('Escape closes the picker but keeps the edit sheet open', async ({ page }) => {
    await page.goto(`/tasks/${PARENT_ID}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Edit', exact: true }).click();
    const sheet = page.getByRole('dialog', { name: 'Edit task' });
    await sheet.getByRole('button', { name: '+ Existing task…' }).click();
    const picker = page.getByRole('dialog', { name: 'Add an existing task' });
    await expect(picker.getByLabel('Search tasks')).toBeFocused();
    await page.keyboard.press('Escape');
    await expect(picker).toHaveCount(0);
    await expect(sheet).toBeVisible();
  });
});
