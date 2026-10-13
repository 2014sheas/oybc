import { test, expect, openCreateHub, seedTask, startOneOffWizard } from './_fixtures/bypass';

/**
 * Undo toasts never get in the way (owner rule 2026-10-13): any interaction
 * outside the toast dismisses it at once; Undo itself still works.
 */

const COUNTER = 'f9100000-0000-0000-0000-000000000001';

test.describe('Undo toast', () => {
  test('the "Logged +N · Undo" toast closes on a tap elsewhere; Undo still works', async ({ page }) => {
    await page.goto('/profile/counters?__oybc_test_bypass=1');
    await seedTask(page, { id: COUNTER, title: 'Run miles', type: 'counting', action: 'Run', unit: 'miles', isCounter: true, countKind: 'continuous', currentCount: 10 });
    await page.goto(`/profile/counters/${COUNTER}?__oybc_test_bypass=1`);
    const amounts = page.getByRole('group', { name: 'Log amount' });
    await amounts.getByRole('button', { name: '0.5', exact: true }).click();
    const add = page.getByRole('button', { name: 'Add 0.5 miles' });
    const undo = page.getByRole('button', { name: 'Undo', exact: true });

    await add.click();
    await expect(undo).toBeVisible();
    await page.mouse.click(5, 5);
    await expect(undo).toHaveCount(0);

    // A second log shows it again; its Undo reverses the log.
    await add.click();
    await expect(page.getByText('11', { exact: true })).toBeVisible();
    await undo.click();
    await expect(page.getByText('10.5', { exact: true })).toBeVisible();
  });

  test('the wizard "Removed" toast closes on a key press elsewhere', async ({ page }) => {
    await page.goto('/boards?__oybc_test_bypass=1');
    await openCreateHub(page);
    await startOneOffWizard(page);
    await page.getByLabel(/board name/i).fill('Toast board');
    await page.getByRole('button', { name: '3×3', exact: true }).click();
    await page.getByRole('group', { name: 'Timeframe' }).getByRole('button', { name: 'Daily', exact: true }).click();
    await page.getByRole('button', { name: /^Next/ }).click();
    const field = page.getByPlaceholder('e.g. Meditate 10 min');
    await field.fill('Toast me');
    await page.getByRole('button', { name: 'Add task' }).click();
    await page.getByRole('button', { name: /Remove Toast me from board/ }).click();
    const toast = page.getByRole('status').filter({ hasText: 'Removed "Toast me"' });
    await expect(toast).toBeVisible();
    await page.getByPlaceholder(/^e\.g\./).first().press('a');
    await expect(toast).toHaveCount(0);
  });
});
