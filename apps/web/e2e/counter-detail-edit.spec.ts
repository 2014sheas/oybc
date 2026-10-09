import { test, expect, readTask, seedBoard, seedBoardTask, seedTask } from './_fixtures/bypass';

/**
 * Counter Detail "⋯" → Edit counter… opens the COUNTER sheet in edit mode
 * on the counter's ROOT (never the task editor: no Type control); a rename +
 * kind switch reach the hub and every live copy (D5 + #575).
 */

const now = new Date();
const START = new Date(now.getTime() - 2 * 864e5).toISOString();
const END = new Date(now.getTime() + 5 * 864e5).toISOString();
const ROOT = 'f4000000-0000-0000-0000-000000000001';
const COPY = 'f4000000-0000-0000-0000-000000000002';
const BOARD = 'f4000000-0000-0000-0000-000000000003';

test('Counter Detail: Edit counter… renames and switches the kind Discrete → Continuous', async ({ page }) => {
  await page.goto('/boards?__oybc_test_bypass=1');
  await seedTask(page, { id: ROOT, title: 'Run miles', type: 'counting', action: 'Run', unit: 'miles', isCounter: true, countKind: 'discrete', currentCount: 0 });
  await seedTask(page, { id: COPY, title: 'Run 10 miles', type: 'counting', action: 'Run', unit: 'miles', maxCount: 10, countKind: 'discrete', currentCount: 0, sharedCounterId: ROOT });
  await seedBoard(page, { id: BOARD, name: 'Miles board', boardSize: 3, timeframe: 'weekly', status: 'active', startDate: START, endDate: END, centerSquareType: 'none' });
  await seedBoardTask(page, { id: 'f4000000-bt00-0000-0000-000000000001', boardId: BOARD, taskId: COPY, row: 0, col: 0 });

  // A never-logged Discrete counter's hub pill logs 1.
  await page.goto('/profile/counters?__oybc_test_bypass=1');
  await expect(page.getByRole('button', { name: 'Log 1 miles for Run miles' })).toBeVisible();

  await page.goto(`/profile/counters/${ROOT}?__oybc_test_bypass=1`);
  await page.getByRole('button', { name: 'Counter options' }).click();
  const items = page.getByRole('menuitem');
  await expect(items).toHaveText([/Edit counter…/, /Delete counter…/]);
  await page.getByRole('menuitem', { name: /Edit counter…/ }).click();

  const sheet = page.getByRole('dialog', { name: 'Edit counter' });
  await expect(sheet).toBeVisible();
  await expect(sheet.getByLabel('What are you counting?')).toHaveValue('miles');
  await expect(sheet.getByLabel('Task verb (optional)')).toHaveValue('Run');
  await expect(sheet.getByRole('button', { name: 'Simple' })).toHaveCount(0);
  await expect(sheet.getByRole('button', { name: 'Compound' })).toHaveCount(0);
  await expect(sheet.getByText('Start from')).toHaveCount(0);

  await sheet.getByLabel('Task verb (optional)').fill('Jog');
  await sheet.getByRole('group', { name: 'Kind' }).getByRole('button', { name: 'Continuous' }).click();
  await sheet.getByRole('button', { name: 'Save', exact: true }).click();
  await expect(sheet).toHaveCount(0);
  await expect.poll(async () => readTask(page, ROOT)).toMatchObject({ countKind: 'continuous', action: 'Jog', title: 'Jog miles' });
  await expect.poll(async () => readTask(page, COPY)).toMatchObject({ countKind: 'continuous', action: 'Jog', title: 'Jog 10 miles' });

  // The page reflects the new kind at once: Continuous chips, a 0.5 log.
  await page.getByRole('group', { name: 'Log amount' }).getByRole('button', { name: '0.5', exact: true }).click();
  await page.getByRole('button', { name: 'Add 0.5 miles' }).click();
  await expect.poll(async () => readTask(page, ROOT)).toMatchObject({ currentCount: 0.5, defaultLogAmount: 0.5 });

  // The hub pill follows the kind; the member cell renders the Continuous count.
  await page.goto('/profile/counters?__oybc_test_bypass=1');
  await expect(page.getByRole('button', { name: 'Log 0.5 miles for Jog miles' })).toBeVisible();
  await page.goto(`/boards/${BOARD}?__oybc_test_bypass=1`);
  await expect(page.getByRole('button', { name: 'Jog 10 miles' })).toContainText('0.5/10');
});
