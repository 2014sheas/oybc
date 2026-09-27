import { test, expect, seedBoard, seedTask, seedBoardTask, readBoard } from './_fixtures/bypass';

/**
 * E2E coverage for the closed-board COUNTING late-log sheet (Board Edit
 * redesign slice 4, plan D7/D15): "+1 +2 +5 Custom… Log", staged then
 * committed with one "Log" tap, partial progress AND overshoot both visible
 * (never high-clamped).
 */

const now = new Date();
const iso = (d: Date): string => d.toISOString();
const TWO_DAYS_AGO = iso(new Date(now.getTime() - 2 * 24 * 60 * 60 * 1000));
const THIRTY_DAYS_AGO = iso(new Date(now.getTime() - 30 * 24 * 60 * 60 * 1000));

const BOARD_ID = 'c1000000-0000-0000-0000-000000000001';
const TASK_ID = 'c1000000-0000-0000-0000-000000000002';

test.describe('Closed-board late log — COUNTING', () => {
  test.beforeEach(async ({ page }) => {
    await seedTask(page, {
      id: TASK_ID,
      title: 'Run 5 mi',
      type: 'counting',
      action: 'Run',
      unit: 'mi',
      maxCount: 5,
    });
    await seedBoard(page, {
      id: BOARD_ID,
      name: 'Ship the redesign',
      boardSize: 3,
      timeframe: 'monthly',
      status: 'active',
      startDate: THIRTY_DAYS_AGO,
      endDate: TWO_DAYS_AGO,
      centerSquareType: 'none',
      sealedAt: new Date().toISOString(),
      sealedCompletedCells: [],
    });
    await seedBoardTask(page, { id: 'c1000000-bt00-0000-0000-000000000001', boardId: BOARD_ID, taskId: TASK_ID, row: 0, col: 0 });
  });

  test('+2 then Custom 7 → "9/5" — overshoot allowed, never high-clamped', async ({ page }) => {
    await page.goto(`/boards/${BOARD_ID}?__oybc_test_bypass=1`);
    await expect(page.getByText('Closed', { exact: true })).toBeVisible();

    await page.getByText('Run 5 mi').click();
    const sheet = page.getByRole('dialog', { name: /Run 5 mi/ });
    await expect(sheet).toBeVisible();
    // The count + "/max" render as adjacent text within one element ("0/5").
    await expect(sheet.getByText('0/5', { exact: true })).toBeVisible();

    await sheet.getByRole('button', { name: '+2' }).click();
    await sheet.getByRole('button', { name: 'Log', exact: true }).click();
    await expect(sheet).toHaveCount(0);

    // Board still closed; the frozen record now shows partial progress.
    await expect(page.getByText('Closed', { exact: true })).toBeVisible();
    let stored = await readBoard(page, BOARD_ID);
    expect(stored?.sealedCompletedCells).toEqual([]);

    // Second log: a custom amount that overshoots the goal.
    await page.getByText('Run 5 mi').click();
    const sheet2 = page.getByRole('dialog', { name: /Run 5 mi/ });
    await sheet2.getByRole('button', { name: 'Custom…' }).click();
    await sheet2.getByLabel('Custom amount').fill('7');
    await sheet2.getByRole('button', { name: 'Log', exact: true }).click();
    await expect(sheet2).toHaveCount(0);

    stored = await readBoard(page, BOARD_ID);
    expect(stored?.sealedCompletedCells).toContain(0); // now green — overshoot

    // Reopening the sheet shows the true overshot total, not clamped at 5.
    await page.getByText('Run 5 mi').click();
    const sheet3 = page.getByRole('dialog', { name: /Run 5 mi/ });
    await expect(sheet3.getByText('9/5', { exact: true })).toBeVisible();
    await expect(sheet3.getByRole('button', { name: 'Undo late log' })).toBeVisible();
  });
});
