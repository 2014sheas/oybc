import { test, expect, openTab, readTask, seedPool, seedTask } from './_fixtures/bypass';

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

  test('Task Detail: Continuous → Discrete confirms, rounds and saves', async ({ page }) => {
    const id = 'e0000000-0000-0000-0000-000000000001';
    await openTab(page, 'Tasks');
    await seedTask(page, { id, title: 'Run 26.2 miles', type: 'counting', action: 'Run', unit: 'miles', maxCount: 26.2, currentCount: 12.75, countKind: 'continuous' });
    await page.goto(`/tasks/${id}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Edit', exact: true }).click();
    await page.getByRole('group', { name: 'Kind' }).getByRole('button', { name: 'Discrete' }).click();
    const confirm = page.getByRole('alertdialog', { name: 'Switch to Discrete?' });
    await expect(confirm.getByText('Run 26 miles')).toBeVisible();
    await expect(confirm.getByText('13 logged')).toBeVisible();
    await confirm.getByRole('button', { name: 'Switch' }).click();
    await expect(page.getByLabel('Goal', { exact: true })).toHaveValue('26');
    await page.getByRole('button', { name: 'Save changes', exact: true }).click();
    await expect.poll(async () => readTask(page, id)).toMatchObject({ countKind: 'discrete', maxCount: 26 });
  });

  test('Pool editor row: Kind row, Continuous → Discrete confirm, staged switch lands on Save', async ({ page }) => {
    const id = 'e0000000-0000-0000-0000-000000000002';
    const poolId = 'e0000000-0000-0000-0000-000000000003';
    await openTab(page, 'Tasks');
    await seedTask(page, { id, title: 'Run 26.2 miles', type: 'counting', action: 'Run', unit: 'miles', maxCount: 26.2, currentCount: 0, countKind: 'continuous' });
    await seedPool(page, { id: poolId, name: 'Runs', taskIds: [id] });
    await page.goto(`/tasks/pools/${poolId}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Edit Run 26.2 miles' }).click();
    const kind = page.getByRole('group', { name: 'Kind' });
    await expect(kind).toBeVisible();
    await page.screenshot({ path: '.playwright-mcp/task12-a5-light.png' });
    await page.emulateMedia({ colorScheme: 'dark' });
    await page.screenshot({ path: '.playwright-mcp/task12-a5-dark.png' });
    await page.emulateMedia({ colorScheme: 'light' });
    await kind.getByRole('button', { name: 'Discrete' }).click();
    const confirm = page.getByRole('alertdialog', { name: 'Switch to Discrete?' });
    await expect(confirm.getByText('Run 26 miles')).toBeVisible();
    await confirm.getByRole('button', { name: 'Switch' }).click();
    await expect(page.getByLabel('Goal', { exact: true })).toHaveValue('26');
    await page.getByRole('button', { name: 'Save task' }).click();
    await page.getByRole('button', { name: 'Save', exact: true }).click();
    await expect.poll(async () => readTask(page, id)).toMatchObject({ countKind: 'discrete', maxCount: 26 });
  });
});
