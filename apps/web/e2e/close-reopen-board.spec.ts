import { test, expect, seedBoard, seedTask, seedBoardTask, readBoard } from './_fixtures/bypass';

/**
 * E2E coverage for the Board Edit redesign slice 4 (T3): Close / Reopen +
 * the closed-board direct late log (docs/BOARD_EDIT_REDESIGN.md; plan D3,
 * D6, D7, D10, D12–D15).
 *
 * Walks the owner's device checklist end to end on one ad-hoc monthly
 * board:
 *   ENDED pill + banner + "LEFT / Ended / … · still logging" stat card
 *   → "…" → Close board → CLOSED pill + "ENDED / … / permanent record"
 *   → tap a normal square → "Mark done on board" → green, still CLOSED
 *   → tap again → "Undo late log" → grey
 *   → "…" → Reopen board (verbatim alert copy) → ENDED again.
 */

const now = new Date();
const iso = (d: Date): string => d.toISOString();
const TWO_DAYS_AGO = iso(new Date(now.getTime() - 2 * 24 * 60 * 60 * 1000));
const THIRTY_DAYS_AGO = iso(new Date(now.getTime() - 30 * 24 * 60 * 60 * 1000));

const BOARD_ID = 'c0000000-0000-0000-0000-000000000001';
const TASK_ID = 'c0000000-0000-0000-0000-000000000002';

test.describe('Close / Reopen a board (Board Edit redesign slice 4)', () => {
  test.beforeEach(async ({ page }) => {
    await seedTask(page, { id: TASK_ID, title: 'Write the recap', type: 'normal' });
    await seedBoard(page, {
      id: BOARD_ID,
      name: 'Ship the redesign',
      boardSize: 3,
      timeframe: 'monthly',
      status: 'active',
      // Ended 2 days ago, well inside the next-month auto-close grace —
      // never silently auto-closes during this test.
      startDate: THIRTY_DAYS_AGO,
      endDate: TWO_DAYS_AGO,
      centerSquareType: 'none',
    });
    await seedBoardTask(page, { id: 'c0000000-bt00-0000-0000-000000000001', boardId: BOARD_ID, taskId: TASK_ID, row: 0, col: 0 });
  });

  test('ENDED → Close → late log → Undo → Reopen, full round trip', async ({ page }) => {
    await page.goto(`/boards/${BOARD_ID}?__oybc_test_bypass=1`);
    await expect(page.getByText('Ship the redesign').first()).toBeVisible();

    // ── ENDED, not yet closed ──────────────────────────────────────────
    // "Ended" appears twice (the pill, and the LEFT stat card's value) — the
    // pill renders first in DOM order.
    await expect(page.getByText('Ended', { exact: true }).first()).toBeVisible();
    await expect(page.getByText(/Board ended on .+\. Still logging until you close it\./)).toBeVisible();
    await expect(page.getByText('Left', { exact: true })).toBeVisible();
    await expect(page.getByText(/· still logging/)).toBeVisible();
    // No Edit squares on an ended board (D13).
    await expect(page.getByRole('button', { name: 'Edit squares' })).toHaveCount(0);

    await page.getByRole('button', { name: 'Board menu' }).click();
    let menu = page.getByRole('menu', { name: 'Board menu' });
    await expect(menu.getByRole('menuitem', { name: 'Close board' })).toBeVisible();
    await menu.getByRole('menuitem', { name: 'Close board' }).click();

    // ── CLOSED ──────────────────────────────────────────────────────────
    await expect(page.getByText('Closed', { exact: true })).toBeVisible();
    await expect(page.getByText('permanent record')).toBeVisible();
    await expect(page.getByText(/Board ended on .+\. Still logging/)).toHaveCount(0);
    // The CLOSED pill IS the feedback (iOS parity) — never the edit-save
    // toast. A point-in-time count, not a retrying `toHaveCount(0)`: the toast
    // self-dismisses after ~2.4s, so a retrying assertion would pass anyway.
    await page.waitForTimeout(300);
    expect(await page.getByText('Board saved').count()).toBe(0);

    const sealedRow = await readBoard(page, BOARD_ID);
    expect(sealedRow?.sealedAt).toBeTruthy();

    // ── Direct late log on the closed board ────────────────────────────
    await page.getByText('Write the recap').click();
    const sheet = page.getByRole('dialog', { name: /Write the recap/ });
    await expect(sheet).toBeVisible();
    await expect(sheet.getByText('Closed', { exact: true })).toBeVisible();
    await sheet.getByRole('button', { name: 'Mark done on board' }).click();
    await expect(sheet).toHaveCount(0);

    // Still CLOSED, but the write landed (green cell 0 in the frozen snapshot).
    await expect(page.getByText('Closed', { exact: true })).toBeVisible();
    const afterLog = await readBoard(page, BOARD_ID);
    expect(afterLog?.sealedCompletedCells).toContain(0);

    // ── Undo the late log ───────────────────────────────────────────────
    await page.getByText('Write the recap').click();
    const sheet2 = page.getByRole('dialog', { name: /Write the recap/ });
    await expect(sheet2.getByRole('button', { name: 'Undo late log' })).toBeVisible();
    await sheet2.getByRole('button', { name: 'Undo late log' }).click();
    await expect(sheet2).toHaveCount(0);
    const afterUndo = await readBoard(page, BOARD_ID);
    expect(afterUndo?.sealedCompletedCells).not.toContain(0);

    // ── Reopen ──────────────────────────────────────────────────────────
    await page.getByRole('button', { name: 'Board menu' }).click();
    menu = page.getByRole('menu', { name: 'Board menu' });
    await menu.getByRole('menuitem', { name: 'Reopen board' }).click();
    const confirm = page.getByRole('alertdialog', { name: 'Reopen this board?' });
    await expect(confirm).toContainText(
      'It accepts logs again until you close it. Streaks and achievements that watch it will recompute.',
    );
    await confirm.getByRole('button', { name: 'Reopen' }).click();
    await expect(confirm).toHaveCount(0);

    await expect(page.getByText('Ended', { exact: true }).first()).toBeVisible();
    await expect(page.getByText('Closed', { exact: true })).toHaveCount(0);
    await page.waitForTimeout(300);
    expect(await page.getByText('Board saved').count()).toBe(0);
    const reopened = await readBoard(page, BOARD_ID);
    expect(reopened?.sealedAt).toBeFalsy();
    expect(reopened?.reopenedAt).toBeTruthy();
  });

  test('a reopened board never auto-closes and is excluded from the closing-out banner', async ({ page }) => {
    await seedBoard(page, {
      id: BOARD_ID,
      name: 'Ship the redesign',
      boardSize: 3,
      timeframe: 'monthly',
      status: 'active',
      startDate: THIRTY_DAYS_AGO,
      endDate: TWO_DAYS_AGO,
      centerSquareType: 'none',
      reopenedAt: new Date().toISOString(),
    });

    await page.goto('/boards?__oybc_test_bypass=1');
    // "All" tab so the ended/reopened board's list classification (a
    // separate concern from D6) can't hide it from this visibility check.
    await page.getByRole('button', { name: 'All' }).click();
    await expect(page.getByText('Ship the redesign')).toBeVisible();
    // The closing-out banner never names a reopened board — its own header
    // (visited via the board's own play surface) carries the ENDED state instead.
    await expect(page.getByRole('region', { name: 'Boards ready to close out' })).toHaveCount(0);
  });
});
