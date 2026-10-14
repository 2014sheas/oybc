import type { Page } from '@playwright/test';
import {
  test,
  expect,
  openCreateHub,
  readTask,
  seedTask,
  startOneOffWizard,
  startRecurringWizard,
} from './_fixtures/bypass';

/**
 * Owner bug 2026-10-14 — a shared counter on the wizard's "On your board"
 * list (the counter itself, as a repeating board keeps it) opens its editor
 * with the board window's default goal filled in, offers the dice around
 * that default, and an edit saves as a board-only linked copy — the counter
 * itself is never written. Undo puts the counter back.
 */

const ROOT = 'eeeeeeee-crg0-0001-task-000000000001';

async function addCounter(page: Page): Promise<void> {
  await page.getByLabel('New normal task title').fill('Pushups');
  const match = page
    .getByRole('list', { name: 'Matching library tasks' })
    .getByRole('button', { name: /Pushups/ })
    .first();
  await expect(match).toBeVisible();
  await match.click();
  await expect(page.getByRole('list', { name: 'Matching library tasks' })).toBeHidden();
}

test.describe('Wizard — a counter row on the board', () => {
  test.beforeEach(async ({ page }) => {
    await seedTask(page, {
      id: ROOT, title: 'Pushups', type: 'counting', action: 'Do', unit: 'pushups',
      isCounter: true, counterName: 'Pushups', timeframeGoals: { daily: 50 },
    });
  });

  test('editor opens on the window default, dice is offered, an edit lands on a copy and Undo restores the counter', async ({ page }) => {
    await openCreateHub(page);
    await startRecurringWizard(page);
    await page.getByLabel(/board name/i).fill('Counter Row Board');
    await page.getByRole('button', { name: '3×3', exact: true }).click();
    await page.getByRole('group', { name: 'Repeats every' }).getByRole('button', { name: 'Day', exact: true }).click();
    await page.getByRole('button', { name: /^Next/ }).click();

    await addCounter(page);
    const row = page.getByRole('listitem').filter({ hasText: 'goal 50' });
    await expect(row).toBeVisible();
    await expect(row.getByRole('button', { name: 'Vary: off' })).toBeVisible();

    await row.getByRole('button', { name: /^Edit / }).click();
    const editor = page.locator('li').filter({ hasText: 'EDITING · COUNTING TASK' });
    const goal = editor.getByLabel('Goal', { exact: true });
    await expect(goal).toHaveValue('50');
    await page.screenshot({ path: '.playwright-mcp/counter-row-goal-01-editor.png' });

    await goal.fill('60');
    await editor.getByRole('button', { name: 'Save task' }).click();
    await expect(page.getByText('Task edited')).toBeVisible();
    const copyRow = page.getByRole('listitem').filter({ hasText: 'goal 60' });
    await expect(copyRow).toBeVisible();
    await expect(copyRow.getByRole('button', { name: 'Vary: off' })).toBeVisible();
    await page.screenshot({ path: '.playwright-mcp/counter-row-goal-02-copy.png' });

    // The counter itself is untouched.
    const root = await readTask(page, ROOT);
    expect(root?.maxCount).toBeUndefined();
    expect(root?.version).toBe(1);

    await page.getByRole('button', { name: 'Undo' }).click();
    await expect(page.getByRole('listitem').filter({ hasText: 'goal 50' })).toBeVisible();
    await expect(page.getByRole('listitem').filter({ hasText: 'goal 60' })).toHaveCount(0);
  });

  test('one-off board: the picked counter row opens on the default goal and offers the dice', async ({ page }) => {
    await openCreateHub(page);
    await startOneOffWizard(page);
    await page.getByLabel(/board name/i).fill('Counter Row One-off');
    await page.getByRole('button', { name: '3×3', exact: true }).click();
    await page.getByRole('group', { name: 'Timeframe' }).getByRole('button', { name: 'Daily', exact: true }).click();
    await page.getByRole('button', { name: /^Next/ }).click();

    await addCounter(page);
    const row = page.getByRole('listitem').filter({ hasText: 'goal 50' });
    await expect(row.getByRole('button', { name: 'Vary: off' })).toBeVisible();
    await row.getByRole('button', { name: /^Edit / }).click();
    const editor = page.locator('li').filter({ hasText: 'EDITING · COUNTING TASK' });
    const goal = editor.getByLabel('Goal', { exact: true });
    await expect(goal).toHaveValue('50');

    // Discard → Undo reopens the typing intact, and Save still lands it.
    await goal.fill('70');
    await editor.getByRole('button', { name: /discard/i }).click();
    await page.getByRole('button', { name: 'Undo' }).click();
    await expect(goal).toHaveValue('70');
    await editor.getByRole('button', { name: 'Save task' }).click();
    await expect(page.getByRole('listitem').filter({ hasText: 'goal 70' })).toBeVisible();
  });
});
