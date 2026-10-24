import { test, expect, readTask, seedTask } from './_fixtures/bypass';

/**
 * Using an existing counting task as a shared counter (docs/SHARED_COUNTERS.md
 * §Using an existing task as the counter): Task Detail's ⋯ › "Use as shared
 * counter" promotes the task and lands on its Counter Detail; the hub's
 * "+ New counter" sheet, on a pair that is already a standalone counting task,
 * disables Create and offers "Use as counter" — the existing task becomes the
 * counter (its count, goal, verb and noun kept, the typed name carried), never
 * a second root for the same pair.
 */

const PLAIN = 'f5000000-0000-0000-0000-000000000001';
const COPY = 'f5000000-0000-0000-0000-000000000002';
const ROOT = 'f5000000-0000-0000-0000-000000000003';

test.describe('Use an existing counting task as a shared counter', () => {
  test.beforeEach(async ({ page }) => {
    await page.goto('/boards?__oybc_test_bypass=1');
    await seedTask(page, { id: PLAIN, title: 'Do 50 push-ups', type: 'counting', action: 'Do', unit: 'push-ups', maxCount: 50, currentCount: 120 });
  });

  test('Task Detail ⋯ › Use as shared counter promotes the task and opens its Counter Detail', async ({ page }) => {
    await page.goto(`/tasks/${PLAIN}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Task options' }).click();
    await page.getByRole('menuitem', { name: 'Use as shared counter' }).click();
    await expect(page).toHaveURL(new RegExp(`/profile/counters/${PLAIN}`));
    await expect.poll(async () => (await readTask(page, PLAIN))?.isCounter).toBe(true);
    const saved = await readTask(page, PLAIN);
    expect(saved).toMatchObject({ currentCount: 120, maxCount: 50, action: 'Do', unit: 'push-ups' });
    // Back on Task Detail the item is gone and the counter row is there.
    await page.goto(`/tasks/${PLAIN}?__oybc_test_bypass=1`);
    await expect(page.getByRole('button', { name: /Open .* counter/ })).toBeVisible();
    await page.getByRole('button', { name: 'Task options' }).click();
    await expect(page.getByRole('menu').getByRole('menuitem')).toHaveText([/Open counter settings/, /Delete task…/]);
  });

  test('a linked copy offers neither counter action beyond settings', async ({ page }) => {
    await seedTask(page, { id: ROOT, title: 'Read pages', type: 'counting', action: 'Read', unit: 'pages', isCounter: true });
    await seedTask(page, { id: COPY, title: 'Read 30 pages', type: 'counting', action: 'Read', unit: 'pages', maxCount: 30, sharedCounterId: ROOT, baseline: 0 });
    await page.goto(`/tasks/${COPY}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Task options' }).click();
    await expect(page.getByRole('menu').getByRole('menuitem')).toHaveText([/Open counter settings/, /Delete task…/]);
  });

  test('hub + New counter on a standalone pair: Create disabled, Use as counter adopts the task with the typed name', async ({ page }) => {
    await page.goto('/profile/counters?__oybc_test_bypass=1');
    await page.getByRole('button', { name: /New counter/ }).click();
    const sheet = page.getByRole('dialog', { name: 'New counter' });
    await sheet.getByLabel('What are you counting?').fill('push-ups');
    await sheet.getByLabel('Task verb', { exact: true }).fill('do');
    await expect(sheet.getByText("You're already counting push-ups")).toBeVisible();
    await expect(sheet.getByText('120 all-time · Do 50 push-ups')).toBeVisible();
    await expect(sheet.getByRole('button', { name: 'Create counter' })).toBeDisabled();
    await expect(sheet.getByLabel('Start from (optional)')).toHaveCount(0);
    await sheet.getByLabel('Name').fill('Push-up club');
    await sheet.getByRole('button', { name: 'Use as counter' }).click();
    await expect(page).toHaveURL(new RegExp(`/profile/counters/${PLAIN}`));
    await expect.poll(async () => (await readTask(page, PLAIN))?.isCounter).toBe(true);
    // The typed casing never rewrites the task; the name lands.
    expect(await readTask(page, PLAIN)).toMatchObject({ action: 'Do', unit: 'push-ups', counterName: 'Push-up club', currentCount: 120, maxCount: 50 });
  });

  test('hub + New counter on an established pair still offers Open, never Use as counter', async ({ page }) => {
    await seedTask(page, { id: ROOT, title: 'Read pages', type: 'counting', action: 'Read', unit: 'pages', isCounter: true, currentCount: 3 });
    await page.goto('/profile/counters?__oybc_test_bypass=1');
    await page.getByRole('button', { name: /New counter/ }).click();
    const sheet = page.getByRole('dialog', { name: 'New counter' });
    await sheet.getByLabel('What are you counting?').fill('pages');
    await sheet.getByLabel('Task verb', { exact: true }).fill('Read');
    await expect(sheet.getByRole('button', { name: /^Open / })).toBeVisible();
    await expect(sheet.getByRole('button', { name: 'Use as counter' })).toHaveCount(0);
  });
});
