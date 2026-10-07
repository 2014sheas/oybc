import { test, expect, seedBoard, seedBoardTask, seedTask } from './_fixtures/bypass';
import type { Locator } from '@playwright/test';

/**
 * Phone width (390): the fixed mobile bottom nav must never cover the
 * closed-board late-log sheet's Log button (D1) or the "Logged +N · Undo"
 * toast (D2). Playwright's click refuses a covered target, and the
 * elementFromPoint check pins that the control itself is on top.
 */

const now = new Date();
const iso = (d: Date): string => d.toISOString();
const BOARD = 'f9000000-0000-0000-0000-000000000001';
const JOG = 'f9000000-0000-0000-0000-000000000002';
const COUNTER = 'f9000000-0000-0000-0000-000000000003';

/** The element at the locator's centre is the locator itself (or inside it). */
async function expectOnTop(target: Locator): Promise<void> {
  const onTop = await target.evaluate((el) => {
    const r = el.getBoundingClientRect();
    const hit = document.elementFromPoint(r.left + r.width / 2, r.top + r.height / 2);
    return hit !== null && (hit === el || el.contains(hit));
  });
  expect(onTop).toBe(true);
}

test.describe('Mobile bottom nav never covers sheets / toasts (390)', () => {
  test.beforeEach(async ({ page }) => {
    await page.setViewportSize({ width: 390, height: 844 });
  });

  test('D1: closed-board late-log Log button is clickable', async ({ page }) => {
    await page.goto('/boards?__oybc_test_bypass=1');
    await seedTask(page, { id: JOG, title: 'Jog 5 mi', type: 'counting', action: 'Jog', unit: 'mi', maxCount: 5, countKind: 'continuous' });
    await seedBoard(page, {
      id: BOARD,
      name: 'Closed kinds',
      boardSize: 3,
      timeframe: 'monthly',
      status: 'active',
      startDate: iso(new Date(now.getTime() - 30 * 864e5)),
      endDate: iso(new Date(now.getTime() - 2 * 864e5)),
      centerSquareType: 'none',
      sealedAt: iso(now),
      sealedCompletedCells: [],
    });
    await seedBoardTask(page, { id: 'f9000000-bt00-0000-0000-000000000001', boardId: BOARD, taskId: JOG, row: 0, col: 0 });
    await page.goto(`/boards/${BOARD}?__oybc_test_bypass=1`);

    await page.getByText('Jog 5 mi').first().click();
    const sheet = page.getByRole('dialog', { name: /Jog 5 mi/ });
    await expect(sheet).toBeVisible();
    const log = sheet.getByRole('button', { name: /^Log/ });
    await expectOnTop(log);
    await log.click();
    await expect(sheet).toHaveCount(0);
  });

  test('D2: the "Logged +N · Undo" toast sits above the nav and Undo works', async ({ page }) => {
    await page.goto('/profile/counters?__oybc_test_bypass=1');
    await seedTask(page, { id: COUNTER, title: 'Run miles', type: 'counting', action: 'Run', unit: 'miles', isCounter: true, countKind: 'continuous', currentCount: 148.6 });
    await page.goto(`/profile/counters/${COUNTER}?__oybc_test_bypass=1`);
    await page.getByRole('group', { name: 'Log amount' }).getByRole('button', { name: '0.5', exact: true }).click();
    await page.getByRole('button', { name: 'Add 0.5 miles' }).click();
    await expect(page.getByText('149.1', { exact: true })).toBeVisible();

    const undo = page.getByRole('button', { name: 'Undo', exact: true });
    await expect(undo).toBeVisible();
    await expectOnTop(undo);
    await undo.click();
    await expect(page.getByText('148.6', { exact: true })).toBeVisible();
  });
});
