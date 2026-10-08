import { test, expect, openCreateHub, seedBoard, seedBoardTask, seedTask, startOneOffWizard } from './_fixtures/bypass';
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

/** A bottom-anchored sheet paints over the nav strip: the element at the
 *  nav's centre is inside the sheet (not the nav's tab bar). */
async function expectSheetOverNav(sheet: Locator): Promise<void> {
  const over = await sheet.evaluate((el) => {
    const hit = document.elementFromPoint(window.innerWidth / 2, window.innerHeight - 20);
    return hit !== null && el.contains(hit);
  });
  expect(over).toBe(true);
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

  // ── Every other fixed sheet/dialog under <main> (one root cause: the shell's
  //    <main> stacking context). Each asserts the sheet's bottom-most control is
  //    on top of the nav and that clicking it acts.

  const ACTIVE = 'f9000000-0000-0000-0000-0000000000a1';
  const LIB_TASK = 'f9000000-0000-0000-0000-0000000000a2';

  async function seedActiveBoard(page: import('@playwright/test').Page): Promise<void> {
    const p = (n: number): string => String(n).padStart(2, '0');
    const d = `${now.getFullYear()}-${p(now.getMonth() + 1)}-${p(now.getDate())}`;
    await seedBoard(page, {
      id: ACTIVE, name: 'Phone board', boardSize: 3, timeframe: 'monthly', status: 'active',
      startDate: `${d}T00:00:00.000`, endDate: `${d}T23:59:59.999`, centerSquareType: 'free',
    });
    await seedTask(page, { id: LIB_TASK, title: 'Morning workout', type: 'normal' });
    await seedBoardTask(page, { id: 'f9000000-bt00-0000-0000-0000000000a1', boardId: ACTIVE, taskId: LIB_TASK, row: 0, col: 0 });
  }

  test('D3: Board Edit square picker sheet paints over the nav', async ({ page }) => {
    await page.goto('/boards?__oybc_test_bypass=1');
    await seedActiveBoard(page);
    await page.goto(`/boards/${ACTIVE}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Edit board' }).click();
    await page.getByRole('button', { name: /^Empty square, row 3, column 2$/ }).click();
    const sheet = page.getByRole('dialog', { name: /Add square/ });
    await expect(sheet).toBeVisible();
    await expectSheetOverNav(sheet);
  });

  test('D4: board cell "Open in library" sheet paints over the nav and Done works', async ({ page }) => {
    await page.goto('/boards?__oybc_test_bypass=1');
    await seedActiveBoard(page);
    await page.goto(`/boards/${ACTIVE}?__oybc_test_bypass=1`);
    await page.getByText('Morning workout').first().click({ button: 'right' });
    await page.getByText('Open in library').click();
    const sheet = page.getByRole('dialog').last();
    await expect(sheet).toBeVisible();
    await expectSheetOverNav(sheet);
    const done = sheet.getByRole('button', { name: /^Done/ });
    await done.click();
    await expect(sheet).toHaveCount(0);
  });

  test('D5: wizard source sheet paints over the nav', async ({ page }) => {
    await page.goto('/boards?__oybc_test_bypass=1');
    await openCreateHub(page);
    await startOneOffWizard(page);
    await page.getByLabel(/board name/i).fill('Phone wizard');
    await page.getByRole('button', { name: '3×3', exact: true }).click();
    await page.getByRole('group', { name: 'Timeframe' }).getByRole('button', { name: 'Daily', exact: true }).click();
    await page.getByRole('button', { name: /^Next/ }).click();
    await page.getByRole('button', { name: 'Add from a pool or board' }).click();
    const src = page.getByRole('dialog', { name: 'Add from a pool or board' });
    await expect(src).toBeVisible();
    await expectSheetOverNav(src);
  });

  test('D6: New counter sheet bottom control stays clickable', async ({ page }) => {
    await page.goto('/profile/counters?__oybc_test_bypass=1');
    await page.getByRole('button', { name: /New counter/ }).first().click();
    const sheet = page.getByRole('dialog', { name: 'New counter' });
    await expect(sheet).toBeVisible();
    await expectOnTop(sheet.getByRole('button').last());
  });
});
