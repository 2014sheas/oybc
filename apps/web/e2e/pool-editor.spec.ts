import { test, expect, openTab, seedPool, seedTask } from './_fixtures/bypass';

/**
 * Pool editor = the board wizard's Tasks step as a full page (owner
 * 2026-10-05): Tasks tab → Pools → "+ New pool" opens a PAGE (no dialog),
 * tasks added through quick-add show as the wizard's rows (not chips), a
 * row's ✎ opens the inline row editor, Save applies the staged edit with
 * the membership, and the return lands on the Pools segment.
 */

const POOL_ID = '72000000-0000-0000-0000-000000000010';
const A_ID = '72000000-0000-0000-0000-000000000001';

test.describe('Pool editor — full page with wizard rows', () => {
  test('new pool: page not dialog → quick-add two tasks → edit one inline → Save → card shows 2 tasks + edited title; reopen shows rows; Cancel returns', async ({
    page,
  }) => {
    await page.goto('/boards');
    await openTab(page, 'Tasks');
    await page.getByRole('button', { name: /^Pools · / }).click();
    // The segment is in the URL, and the header "+" is now "New pool".
    await expect(page).toHaveURL(/segment=pools/);
    await page.getByRole('button', { name: 'New pool', exact: true }).click();

    await expect(page).toHaveURL(/\/tasks\/pools\/new$/);
    await expect(page.getByRole('dialog')).toHaveCount(0);
    await expect(page.getByText('NEW POOL', { exact: true })).toBeVisible();

    await page.getByLabel('Name').fill('Morning set');
    const quick = page.getByLabel('New normal task title');
    await quick.fill('Stretch');
    await page.getByRole('button', { name: 'Add task' }).click();
    await quick.fill('Journal');
    await page.getByRole('button', { name: 'Add task' }).click();

    // Rows (the wizard's PoolList), not chips.
    await expect(page.getByText('In this pool')).toBeVisible();
    await expect(page.getByRole('button', { name: 'Edit Stretch' })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Remove Journal from pool' })).toBeVisible();

    await page.getByRole('button', { name: 'Edit Stretch' }).click();
    await page.getByRole('textbox', { name: 'Task title', exact: true }).fill('Stretch 10 min');
    await page.getByRole('button', { name: 'Save task' }).click();
    await expect(page.getByText('Stretch 10 min', { exact: true })).toBeVisible();

    await page.getByRole('button', { name: 'Create pool' }).click();

    // Back on Tasks → Pools with the card.
    await expect(page).toHaveURL(/\/tasks\?segment=pools$/);
    const card = page.getByRole('button', { name: 'Edit pool Morning set' });
    await expect(card).toBeVisible();
    await expect(card).toContainText('2 tasks');

    // The staged rename was applied to the library task itself.
    await page.getByRole('button', { name: 'Library' }).click();
    await expect(page.getByText('Stretch 10 min').first()).toBeVisible();

    // Reopen: rows (not chips) → Cancel returns without changes.
    await page.getByRole('button', { name: /^Pools · / }).click();
    await page.getByRole('button', { name: 'Edit pool Morning set' }).click();
    await expect(page.getByText('EDIT POOL', { exact: true })).toBeVisible();
    await expect(page.getByRole('button', { name: 'Edit Journal' })).toBeVisible();
    await page.getByRole('button', { name: 'Cancel', exact: true }).click();
    await expect(page).toHaveURL(/\/tasks\?segment=pools$/);
  });

  test('Library segment keeps "+ New task" opening the sheet', async ({ page }) => {
    await page.goto('/boards');
    await openTab(page, 'Tasks');
    await page.getByRole('button', { name: 'New task', exact: true }).click();
    await expect(page).toHaveURL(/\/tasks$/);
    await expect(page.getByRole('dialog')).toBeVisible();
  });

  test('a staged edit is discarded on Cancel (task unchanged)', async ({ page }) => {
    await seedTask(page, { id: A_ID, title: 'Read', type: 'normal' });
    await seedPool(page, { id: POOL_ID, name: 'Evening', taskIds: [A_ID] });
    await page.goto(`/tasks/pools/${POOL_ID}?__oybc_test_bypass=1`);

    await page.getByRole('button', { name: 'Edit Read' }).click();
    await page.getByRole('textbox', { name: 'Task title', exact: true }).fill('Read 20 pages');
    await page.getByRole('button', { name: 'Save task' }).click();
    await page.getByRole('button', { name: 'Cancel', exact: true }).click();

    await expect(page).toHaveURL(/\/tasks\?segment=pools$/);
    await page.getByRole('button', { name: 'Library' }).click();
    await expect(page.getByText('Read', { exact: true }).first()).toBeVisible();
    await expect(page.getByText('Read 20 pages')).toHaveCount(0);
  });
});
