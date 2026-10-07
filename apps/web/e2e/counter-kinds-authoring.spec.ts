import { test, expect, openTab, seedTask } from './_fixtures/bypass';

test.describe('Counter kinds — authoring (A1)', () => {
  test('Tasks tab: create a Continuous and a Duration counting task', async ({ page }) => {
    await openTab(page, 'Tasks');

    await page.getByRole('button', { name: 'New task', exact: true }).click();
    let sheet = page.getByRole('dialog', { name: 'New task' });
    await sheet.getByRole('button', { name: 'Counting', exact: true }).click();
    await sheet.getByLabel('Verb').fill('Run');
    await sheet.getByRole('group', { name: 'Kind' }).getByRole('button', { name: 'Continuous' }).click();
    await sheet.getByLabel('Goal', { exact: true }).fill('26,2');
    await sheet.getByPlaceholder('push-ups').fill('miles');
    await expect(sheet.getByText('Run 26.2 miles')).toBeVisible();
    await sheet.getByRole('button', { name: 'Add to library' }).click();
    await expect(sheet).not.toBeVisible();
    await expect(page.getByRole('button', { name: 'Open Run 26.2 miles details' })).toBeVisible();

    await page.getByRole('button', { name: 'New task', exact: true }).click();
    sheet = page.getByRole('dialog', { name: 'New task' });
    await sheet.getByRole('button', { name: 'Counting', exact: true }).click();
    await sheet.getByLabel('Verb').fill('Practice');
    await sheet.getByRole('group', { name: 'Kind' }).getByRole('button', { name: 'Duration' }).click();
    await expect(sheet.getByPlaceholder('push-ups')).toHaveCount(0);
    await sheet.getByLabel('Goal hours').fill('10');
    await sheet.getByLabel('Goal minutes').fill('30');
    await sheet.getByRole('button', { name: 'Add to library' }).click();
    await expect(sheet).not.toBeVisible();
    await expect(page.getByRole('button', { name: 'Open Practice 10h 30m details' })).toBeVisible();
  });

  test('an auto-linking create shows the root kind tag instead of the picker', async ({ page }) => {
    await seedTask(page, {
      id: 'dddddddd-0006-0000-0000-000000000006',
      title: 'Run 26.2 miles',
      type: 'counting',
      action: 'Run',
      unit: 'miles',
      maxCount: 26.2,
      countKind: 'continuous',
      currentCount: 148.6,
    });
    await openTab(page, 'Tasks');
    await page.getByRole('button', { name: 'New task', exact: true }).click();
    const sheet = page.getByRole('dialog', { name: 'New task' });
    await sheet.getByRole('button', { name: 'Counting', exact: true }).click();
    await expect(sheet.getByRole('group', { name: 'Kind' })).toBeVisible();
    await sheet.getByLabel('Verb').fill('Run');
    await sheet.getByPlaceholder('push-ups').fill('miles');
    await expect(sheet.getByRole('group', { name: 'Kind' })).toHaveCount(0);
    await expect(sheet.getByText('Continuous', { exact: false }).first()).toBeVisible();
  });
});
