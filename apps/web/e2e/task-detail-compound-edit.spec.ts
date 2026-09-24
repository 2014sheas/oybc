import type { Page } from '@playwright/test';
import { test, expect, seedTask, seedCompoundChild, openTab } from './_fixtures/bypass';

/**
 * Task Detail edits a compound's rule and sub-tasks (Compound Task Editing
 * After Creation, web). Seeds a 2-sub-task "All of" compound, then through
 * the real UI: Tasks tab → detail → Edit → "+ Normal sub-task" "Third" →
 * "At least N of" (2 of 3) → Save. The detail's Subtasks list shows three
 * rows, survives a reload, and the stored row carries the M-of-N rule.
 */

const PARENT_ID = 'cccccccc-0001-0000-0000-000000000001';
const CHILD_A_ID = 'cccccccc-0002-0000-0000-000000000002';
const CHILD_B_ID = 'cccccccc-0003-0000-0000-000000000003';

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
    expect(await readRule(page)).toMatchObject({ operator: 'M_OF_N', threshold: 2, version: 2 });

    // Persisted: a reload re-reads IndexedDB.
    await page.reload();
    await expect(page.getByRole('heading', { name: 'Subtasks (3)' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Open subtask: Third' })).toBeVisible();

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
});
