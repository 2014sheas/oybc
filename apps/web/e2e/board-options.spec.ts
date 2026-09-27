import { test, expect, seedBoard, seedTask, seedBoardTask, readBoard, openBoardOption } from './_fixtures/bypass';

/**
 * E2E coverage for the Edit consolidation redesign (`docs/BOARD_EDIT_REDESIGN.md`
 * slice 5, plan D1/D6/D9): the title-row "…" `BoardActionsMenu` is retired —
 * ONE `Edit board` button opens the Edit screen, whose BOARD section
 * (`role="group" aria-label="Board options"`) hosts every option
 * (`BoardDetailsSheet` / `BoardRepeatSheet` / `CoreDefaultsSheetHost` /
 * `BoardActionConfirmDialog`, composed in `BoardOptionsSection`). Formerly
 * `board-actions-menu.spec.ts`.
 *
 * Scenarios (mirrors the pre-consolidation spec's coverage, converted to the
 * new surface, plus the new D6/D8/D9 cases at the bottom):
 *   (a) Ad-hoc BOARD rows; Board details renames the board — saving stays
 *       IN Edit (D9); exiting Edit (no dirty squares) shows the new name.
 *   (b) Ongoing board: editing the start date persists (bugfix B1 regression).
 *   (c) Repeat this board… → Weekly → Save → stays in Edit → exit → RECURRING
 *       badge; reopening Edit → Repeat this board… shows Repeating/Paused.
 *   (d) Archive → confirm → lands on /boards.
 *   (e) Delete → confirm → lands on /boards, the card is gone.
 *   (f) Core board in the pager → BOARD rows are only Core defaults… ·
 *       Delete; Core defaults… opens the sheet; Delete leaves the pager on
 *       the setup prompt with the window chip re-enabled and paging
 *       restored (D9 regression — Delete used to be unreachable while
 *       editing, so nothing exercised this before).
 *   (g) A legacy CHOSEN-center one-off shows Repeat, same as any other
 *       one-off (Board Edit slice 3, D5).
 *   (1)-(5) New Edit-consolidation cases (plan W4).
 */

const now = new Date();
const pad = (n: number): string => String(n).padStart(2, '0');
const TODAY_DATE = `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
const DAY_START = `${TODAY_DATE}T00:00:00.000`;
const DAY_END = `${TODAY_DATE}T23:59:59.999`;
const NEXT_MONTH = new Date(now.getTime() + 30 * 24 * 60 * 60 * 1000).toISOString();
const FIVE_DAYS_AGO = new Date(now.getTime() - 5 * 24 * 60 * 60 * 1000).toISOString();
const TWO_DAYS_AGO = new Date(now.getTime() - 2 * 24 * 60 * 60 * 1000).toISOString();
const THIRTY_DAYS_AGO = new Date(now.getTime() - 30 * 24 * 60 * 60 * 1000).toISOString();
const TEN_DAYS_AGO = new Date(now.getTime() - 10 * 24 * 60 * 60 * 1000)
  .toISOString()
  .slice(0, 10);

const ADHOC_BOARD_ID = 'a0000000-0000-0000-0000-000000000001';
const ONGOING_BOARD_ID = 'a0000000-0000-0000-0000-000000000002';
const ONE_OFF_BOARD_ID = 'a0000000-0000-0000-0000-000000000003';
const CHOSEN_BOARD_ID = 'a0000000-0000-0000-0000-000000000004';
const ARCHIVE_BOARD_ID = 'a0000000-0000-0000-0000-000000000005';
const DELETE_BOARD_ID = 'a0000000-0000-0000-0000-000000000006';
const CORE_BOARD_ID = 'a0000000-0000-0000-0000-000000000007';

test.describe('Board options — ad-hoc board', () => {
  test.beforeEach(async ({ page }) => {
    await seedBoard(page, {
      id: ADHOC_BOARD_ID,
      name: 'Ship the redesign',
      boardSize: 3,
      timeframe: 'monthly',
      status: 'active',
      startDate: FIVE_DAYS_AGO,
      endDate: NEXT_MONTH,
      centerSquareType: 'free',
    });
  });

  test('shows Board details… · Repeat this board… · Archive · Delete; renaming saves and stays in Edit (D9)', async ({ page }) => {
    await page.goto(`/boards/${ADHOC_BOARD_ID}?__oybc_test_bypass=1`);
    await expect(page.getByText('Ship the redesign').first()).toBeVisible();

    await page.getByRole('button', { name: 'Edit board' }).click();
    const group = page.getByRole('group', { name: 'Board options' });
    await expect(group.getByRole('button', { name: 'Board details…', exact: true })).toBeVisible();
    await expect(group.getByRole('button', { name: 'Repeat this board…', exact: true })).toBeVisible();
    await expect(group.getByRole('button', { name: 'Archive', exact: true })).toBeVisible();
    await expect(group.getByRole('button', { name: 'Delete', exact: true })).toBeVisible();

    await group.getByRole('button', { name: 'Board details…', exact: true }).click();
    const nameInput = page.locator('#bw-board-name');
    await expect(nameInput).toHaveValue('Ship the redesign');
    await nameInput.fill('Ship the redesign (v2)');
    await page
      .getByRole('dialog', { name: 'Board details' })
      .getByRole('button', { name: 'Save' })
      .click();

    // D9 — Board details save stays IN Edit; the toast fires, the BOARD
    // section is still there (no re-click of "Edit board" needed).
    await expect(page.getByText('Board saved')).toBeVisible();
    await expect(page.getByRole('group', { name: 'Board options' })).toBeVisible();

    // Exit Edit (no dirty squares — Cancel exits immediately) to see the
    // renamed heading on the normal play rail.
    await page.getByRole('button', { name: 'Cancel editing' }).click();
    await expect(page.getByRole('heading', { name: 'Ship the redesign (v2)' })).toBeVisible();
  });
});

test.describe('Board options — board sealed while Board details is open (D11)', () => {
  const SEALED_MID_ID = 'a0000000-0000-0000-0000-000000000008';
  const seed = {
    id: SEALED_MID_ID,
    name: 'Closing soon',
    boardSize: 3,
    timeframe: 'monthly' as const,
    status: 'active' as const,
    startDate: FIVE_DAYS_AGO,
    endDate: NEXT_MONTH,
    centerSquareType: 'free' as const,
  };

  test.beforeEach(async ({ page }) => {
    await seedBoard(page, seed);
  });

  test('Save shows the "Board closed" notice and writes nothing', async ({ page }) => {
    await page.goto(`/boards/${SEALED_MID_ID}?__oybc_test_bypass=1`);
    await openBoardOption(page, 'Board details…');
    await page.locator('#bw-board-name').fill('Renamed after close');

    // The seal backstop (or another device) closes the board mid-session.
    await seedBoard(page, { ...seed, sealedAt: new Date().toISOString() });

    await page
      .getByRole('dialog', { name: 'Board details' })
      .getByRole('button', { name: 'Save' })
      .click();

    const notice = page.getByRole('alertdialog', { name: 'Board closed' });
    await expect(notice).toBeVisible();
    await expect(notice).toContainText('This board has been closed, so your changes weren’t saved.');
    await expect(page.getByRole('dialog', { name: 'Board details' })).toHaveCount(0);
    await expect(page.getByText('Board saved')).toHaveCount(0);
    await notice.getByRole('button', { name: 'OK' }).click();
    await expect(notice).toHaveCount(0);

    const stored = await readBoard(page, SEALED_MID_ID);
    expect(stored?.name).toBe('Closing soon');
  });
});

test.describe('Board options — ongoing board start-date edit (bugfix B1 regression)', () => {
  test.beforeEach(async ({ page }) => {
    await seedBoard(page, {
      id: ONGOING_BOARD_ID,
      name: 'Learn piano',
      boardSize: 3,
      timeframe: 'indefinite',
      status: 'active',
      startDate: FIVE_DAYS_AGO,
      endDate: '',
      centerSquareType: 'none',
    });
  });

  test('editing the start date persists after reload', async ({ page }) => {
    await page.goto(`/boards/${ONGOING_BOARD_ID}?__oybc_test_bypass=1`);
    await expect(page.getByText('Learn piano').first()).toBeVisible();

    await openBoardOption(page, 'Board details…');
    const startInput = page.locator('#bw-start-date');
    await expect(startInput).toBeVisible();
    await startInput.fill(TEN_DAYS_AGO);
    const saveBtn = page.getByRole('dialog', { name: 'Board details' }).getByRole('button', { name: 'Save' });
    await expect(saveBtn).toBeEnabled();
    await saveBtn.click();

    await expect(page.getByText('Board saved')).toBeVisible();

    await page.reload();
    await openBoardOption(page, 'Board details…');
    await expect(page.locator('#bw-start-date')).toHaveValue(TEN_DAYS_AGO);
  });
});

test.describe('Board options — Repeat this board…', () => {
  test.beforeEach(async ({ page }) => {
    await seedBoard(page, {
      id: ONE_OFF_BOARD_ID,
      name: 'Reading Sprint',
      boardSize: 3,
      timeframe: 'daily',
      status: 'active',
      startDate: DAY_START,
      endDate: DAY_END,
      centerSquareType: 'none',
    });
  });

  test('Weekly → Save stays in Edit; exiting shows the RECURRING badge; reopening Repeat shows Repeating/Paused', async ({ page }) => {
    await page.goto(`/boards/${ONE_OFF_BOARD_ID}?__oybc_test_bypass=1`);
    await expect(page.getByText('Reading Sprint').first()).toBeVisible();
    await expect(page.getByText('RECURRING', { exact: true })).not.toBeVisible();

    await openBoardOption(page, 'Repeat this board…');
    await page.getByRole('button', { name: 'Weekly', exact: true }).click();
    await page
      .getByRole('dialog', { name: 'Repeat this board' })
      .getByRole('button', { name: 'Save' })
      .click();

    // D9 — stays in Edit; exit (no dirty squares) to see the badge on the
    // normal play rail.
    await expect(page.getByRole('group', { name: 'Board options' })).toBeVisible();
    await page.getByRole('button', { name: 'Cancel editing' }).click();
    await expect(page.getByText('RECURRING', { exact: true })).toBeVisible();

    await openBoardOption(page, 'Repeat this board…');
    await expect(page.getByRole('group', { name: 'Repeating status' })).toBeVisible();
  });
});

test.describe('Board options — a legacy CHOSEN-center one-off now shows Repeat (Board Edit slice 3, D5)', () => {
  test.beforeEach(async ({ page }) => {
    await seedBoard(page, {
      id: CHOSEN_BOARD_ID,
      name: 'Chosen Center Board',
      boardSize: 3,
      timeframe: 'daily',
      status: 'active',
      startDate: DAY_START,
      endDate: DAY_END,
      centerSquareType: 'chosen',
    });
  });

  test('Repeat this board… is offered, same as any other one-off', async ({ page }) => {
    await page.goto(`/boards/${CHOSEN_BOARD_ID}?__oybc_test_bypass=1`);
    await expect(page.getByText('Chosen Center Board').first()).toBeVisible();
    await page.getByRole('button', { name: 'Edit board' }).click();
    const group = page.getByRole('group', { name: 'Board options' });
    await expect(group.getByRole('button', { name: 'Repeat this board…', exact: true })).toBeVisible();
    await expect(group.getByRole('button', { name: 'Board details…', exact: true })).toBeVisible();
  });
});

test.describe('Board options — Archive', () => {
  test.beforeEach(async ({ page }) => {
    await seedBoard(page, {
      id: ARCHIVE_BOARD_ID,
      name: 'Old Sprint Board',
      boardSize: 3,
      timeframe: 'monthly',
      status: 'active',
      startDate: FIVE_DAYS_AGO,
      endDate: NEXT_MONTH,
      centerSquareType: 'none',
    });
  });

  test('confirming Archive navigates back to /boards', async ({ page }) => {
    await page.goto(`/boards/${ARCHIVE_BOARD_ID}?__oybc_test_bypass=1`);
    await expect(page.getByText('Old Sprint Board').first()).toBeVisible();

    await openBoardOption(page, 'Archive');
    const confirm = page.getByRole('alertdialog', { name: 'Archive this board?' });
    await expect(confirm).toBeVisible();
    await confirm.getByRole('button', { name: 'Archive', exact: true }).click();

    await expect(page).toHaveURL(/\/boards(\?|$)/);
    const board = await readBoard(page, ARCHIVE_BOARD_ID);
    expect(board?.status).toBe('archived');
  });
});

test.describe('Board options — Delete', () => {
  test.beforeEach(async ({ page }) => {
    await seedBoard(page, {
      id: DELETE_BOARD_ID,
      name: 'Throwaway Board',
      boardSize: 3,
      timeframe: 'monthly',
      status: 'active',
      startDate: FIVE_DAYS_AGO,
      endDate: NEXT_MONTH,
      centerSquareType: 'none',
    });
  });

  test('confirming Delete navigates back to /boards and the card is gone', async ({ page }) => {
    await page.goto(`/boards/${DELETE_BOARD_ID}?__oybc_test_bypass=1`);
    await expect(page.getByText('Throwaway Board').first()).toBeVisible();

    await openBoardOption(page, 'Delete');
    const confirm = page.getByRole('alertdialog', { name: 'Delete board?' });
    await expect(confirm).toBeVisible();
    await confirm.getByRole('button', { name: 'Delete', exact: true }).click();

    await expect(page).toHaveURL(/\/boards(\?|$)/);
    await expect(page.getByText('Throwaway Board')).not.toBeVisible();
    const board = await readBoard(page, DELETE_BOARD_ID);
    expect(board?.isDeleted).toBe(true);
  });
});

test.describe('Board options — core board', () => {
  test.beforeEach(async ({ page }) => {
    await seedBoard(page, {
      id: CORE_BOARD_ID,
      name: 'Today',
      boardSize: 3,
      timeframe: 'daily',
      status: 'active',
      startDate: DAY_START,
      endDate: DAY_END,
      centerSquareType: 'none',
      isCore: true,
    });
    // A core board always has placed tasks in production (wizard/spawn
    // fill every cell) — seed one so the grid isn't stuck on its
    // "Loading board tasks…" empty state, which is unrelated to this test.
    await seedTask(page, {
      id: 'a0000000-task-0000-0000-000000000007',
      title: 'Meditate',
      type: 'normal',
    });
    await seedBoardTask(page, {
      id: 'a0000000-bt00-0000-0000-000000000007',
      boardId: CORE_BOARD_ID,
      taskId: 'a0000000-task-0000-0000-000000000007',
      row: 0,
      col: 0,
    });
  });

  test('BOARD rows are only Core defaults… · Delete; Core defaults… opens the sheet; Delete leaves the setup prompt with the chip re-enabled and paging restored (D9)', async ({ page }) => {
    await page.goto(`/boards/${CORE_BOARD_ID}?__oybc_test_bypass=1`);
    await expect(page).toHaveURL(new RegExp(`/boards/core/daily/${TODAY_DATE}$`));

    const chip = page.getByRole('button', { name: /Opens window picker/ });
    await expect(chip).toBeEnabled();

    await page.getByRole('button', { name: 'Edit board' }).click();
    // D9 — the pager's window chip (rendered as the normal rail's
    // `kickerAccessory`) is part of the normal play rail, which the edit
    // overlay replaces entirely — so it's gone from the tree while editing,
    // not merely disabled. The regression this case exists to catch is
    // whether it comes BACK (enabled, paging restored) after Delete exits
    // Edit — Delete used to be unreachable while editing, so nothing
    // exercised this before.
    await expect(chip).toHaveCount(0);
    const group = page.getByRole('group', { name: 'Board options' });
    await expect(group.getByRole('button', { name: 'Core defaults…', exact: true })).toBeVisible();
    await expect(group.getByRole('button', { name: 'Delete', exact: true })).toBeVisible();
    await expect(group.getByRole('button', { name: 'Board details…', exact: true })).toHaveCount(0);
    await expect(group.getByRole('button', { name: 'Archive', exact: true })).toHaveCount(0);
    await expect(group.getByRole('button', { name: 'Repeat this board…', exact: true })).toHaveCount(0);

    await group.getByRole('button', { name: 'Core defaults…', exact: true }).click();
    await expect(page.getByText('Daily defaults')).toBeVisible();
    await page.getByRole('button', { name: 'Close' }).click();

    await page.getByRole('group', { name: 'Board options' }).getByRole('button', { name: 'Delete', exact: true }).click();
    await page.getByRole('alertdialog', { name: 'Delete board?' }).getByRole('button', { name: 'Delete', exact: true }).click();

    // Deleting a core board stays in the pager; the window falls back to
    // its lazy setup prompt (no board row is ever auto-created), Edit's
    // overlay is gone, the chip is re-enabled, and paging works again.
    await expect(page).toHaveURL(new RegExp(`/boards/core/daily/${TODAY_DATE}$`));
    await expect(page.getByText(/No board for .* yet\./)).toBeVisible();
    await expect(page.getByRole('group', { name: 'Board options' })).toHaveCount(0);
    await expect(chip).toBeEnabled();
    await page.keyboard.press('ArrowRight');
    await expect(page).not.toHaveURL(new RegExp(`/boards/core/daily/${TODAY_DATE}$`));
  });
});

// ─── Edit consolidation — new cases (plan D6/D8/D9, W4) ─────────────────────

test.describe('Board options — Edit consolidation (new cases)', () => {
  const NEW_ADHOC_ID = 'a0000000-0000-0000-0000-000000000009';
  const NEW_TASK_ID = 'a0000000-0000-0000-0000-00000000000a';
  const NEW_BT_ID = 'a0000000-0000-0000-0000-00000000000b';
  const CLOSED_ADHOC_ID = 'a0000000-0000-0000-0000-00000000000c';
  const ARCHIVED_ADHOC_ID = 'a0000000-0000-0000-0000-00000000000d';

  test('1. Active ad-hoc: Edit shows "Editing" + SQUARES + BOARD; a staged square edit survives a Board-details save; Save changes persists both (D8 keep)', async ({ page }) => {
    await seedBoard(page, {
      id: NEW_ADHOC_ID,
      name: 'Case one board',
      boardSize: 3,
      timeframe: 'monthly',
      status: 'active',
      startDate: FIVE_DAYS_AGO,
      endDate: NEXT_MONTH,
      centerSquareType: 'none',
    });
    await seedTask(page, { id: NEW_TASK_ID, title: 'Read a chapter', type: 'normal' });
    await seedBoardTask(page, { id: NEW_BT_ID, boardId: NEW_ADHOC_ID, taskId: NEW_TASK_ID, row: 0, col: 0 });

    await page.goto(`/boards/${NEW_ADHOC_ID}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Edit board' }).click();

    await expect(page.locator('[aria-label="Board is in edit mode"]')).toHaveText('Editing');
    await expect(page.getByRole('button', { name: /Read a chapter/ })).toBeVisible();
    const group = page.getByRole('group', { name: 'Board options' });
    await expect(group).toBeVisible();
    await expect(group.getByRole('button', { name: 'Board details…', exact: true })).toBeVisible();

    // Stage a square edit — lock the placed square.
    await page.getByRole('button', { name: /Read a chapter/ }).click();
    await page.getByRole('button', { name: 'Lock in place' }).click();
    await expect(page.getByText(/^1$/).first()).toBeVisible();

    // Board details… → rename → Save — stays in Edit (D9), the draft survives (D8 keep).
    await group.getByRole('button', { name: 'Board details…', exact: true }).click();
    await page.locator('#bw-board-name').fill('Case one board (renamed)');
    await page.getByRole('dialog', { name: 'Board details' }).getByRole('button', { name: 'Save' }).click();
    await expect(page.getByText('Board saved')).toBeVisible();
    await expect(page.getByText(/^1$/).first()).toBeVisible();

    // Save changes — commits the squares draft too.
    await page.getByRole('button', { name: 'Save changes' }).click();
    await expect(page.getByRole('heading', { name: 'Case one board (renamed)' })).toBeVisible();

    await page.reload();
    await expect(page.getByRole('heading', { name: 'Case one board (renamed)' })).toBeVisible();
    await expect(page.getByRole('img', { name: 'Locked in place' })).toHaveCount(1);
  });

  test('2. Dirty draft → Delete: confirm body ends with the discard suffix (D8)', async ({ page }) => {
    await seedBoard(page, {
      id: `${NEW_ADHOC_ID}-2`,
      name: 'Case two board',
      boardSize: 3,
      timeframe: 'monthly',
      status: 'active',
      startDate: FIVE_DAYS_AGO,
      endDate: NEXT_MONTH,
      centerSquareType: 'none',
    });
    await seedTask(page, { id: `${NEW_TASK_ID}-2`, title: 'Water the plants', type: 'normal' });
    await seedBoardTask(page, {
      id: `${NEW_BT_ID}-2`,
      boardId: `${NEW_ADHOC_ID}-2`,
      taskId: `${NEW_TASK_ID}-2`,
      row: 0,
      col: 0,
    });

    await page.goto(`/boards/${NEW_ADHOC_ID}-2?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Edit board' }).click();
    await page.getByRole('button', { name: /Water the plants/ }).click();
    await page.getByRole('button', { name: 'Lock in place' }).click();
    await expect(page.getByText(/^1$/).first()).toBeVisible();

    await page.getByRole('group', { name: 'Board options' }).getByRole('button', { name: 'Delete', exact: true }).click();
    const confirm = page.getByRole('alertdialog', { name: 'Delete board?' });
    await expect(confirm).toContainText('Your unsaved square changes will be discarded.');
    await confirm.getByRole('button', { name: 'Delete', exact: true }).click();

    await expect(page).toHaveURL(/\/boards(\?|$)/);
  });

  test('3. Closed ad-hoc: Edit shows the D4 reason line, "Done", no Shuffle/Save; rows Reopen · Repeat · Archive · Delete', async ({ page }) => {
    await seedTask(page, { id: `${NEW_TASK_ID}-3`, title: 'Write the recap', type: 'normal' });
    await seedBoard(page, {
      id: CLOSED_ADHOC_ID,
      name: 'Case three board',
      boardSize: 3,
      timeframe: 'monthly',
      status: 'active',
      startDate: THIRTY_DAYS_AGO,
      endDate: TWO_DAYS_AGO,
      centerSquareType: 'none',
      sealedAt: new Date().toISOString(),
      sealedCompletedCells: [],
    });
    await seedBoardTask(page, {
      id: `${NEW_BT_ID}-3`,
      boardId: CLOSED_ADHOC_ID,
      taskId: `${NEW_TASK_ID}-3`,
      row: 0,
      col: 0,
    });

    await page.goto(`/boards/${CLOSED_ADHOC_ID}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Edit board' }).click();

    await expect(page.getByText("This board has ended, so its squares can't change.")).toBeVisible();
    await expect(page.getByRole('button', { name: 'Shuffle' })).toHaveCount(0);
    await expect(page.getByRole('button', { name: 'Save changes' })).toHaveCount(0);
    const doneBtn = page.getByRole('button', { name: 'Done editing' });
    await expect(doneBtn).toBeVisible();

    const group = page.getByRole('group', { name: 'Board options' });
    await expect(group.getByRole('button', { name: 'Reopen board', exact: true })).toBeVisible();
    await expect(group.getByRole('button', { name: 'Repeat this board…', exact: true })).toBeVisible();
    await expect(group.getByRole('button', { name: 'Archive', exact: true })).toBeVisible();
    await expect(group.getByRole('button', { name: 'Delete', exact: true })).toBeVisible();
    await expect(group.getByRole('button', { name: 'Close board', exact: true })).toHaveCount(0);
    await expect(group.getByRole('button', { name: 'Board details…', exact: true })).toHaveCount(0);

    await doneBtn.click();
    await expect(page.getByRole('group', { name: 'Board options' })).toHaveCount(0);
  });

  test('4. Archived board: Edit is visible, BOARD shows Delete only, reason line explains why', async ({ page }) => {
    await seedBoard(page, {
      id: ARCHIVED_ADHOC_ID,
      name: 'Case four board',
      boardSize: 3,
      timeframe: 'monthly',
      status: 'archived',
      startDate: FIVE_DAYS_AGO,
      endDate: NEXT_MONTH,
      centerSquareType: 'none',
    });

    await page.goto(`/boards/${ARCHIVED_ADHOC_ID}?__oybc_test_bypass=1`);
    const editBtn = page.getByRole('button', { name: 'Edit board' });
    await expect(editBtn).toBeVisible();
    await editBtn.click();

    await expect(page.getByText("This board is archived, so its squares can't change.")).toBeVisible();
    const group = page.getByRole('group', { name: 'Board options' });
    await expect(group.getByRole('button', { name: 'Delete', exact: true })).toBeVisible();
    await expect(group.locator('button')).toHaveCount(1);
  });

  test('5. No "Board menu" button anywhere — the "…" trigger is retired', async ({ page }) => {
    await seedBoard(page, {
      id: `${NEW_ADHOC_ID}-5`,
      name: 'Case five board',
      boardSize: 3,
      timeframe: 'monthly',
      status: 'active',
      startDate: FIVE_DAYS_AGO,
      endDate: NEXT_MONTH,
      centerSquareType: 'none',
    });

    await page.goto(`/boards/${NEW_ADHOC_ID}-5?__oybc_test_bypass=1`);
    await expect(page.getByRole('button', { name: 'Board menu' })).toHaveCount(0);
    await page.getByRole('button', { name: 'Edit board' }).click();
    await expect(page.getByRole('button', { name: 'Board menu' })).toHaveCount(0);
  });
});
