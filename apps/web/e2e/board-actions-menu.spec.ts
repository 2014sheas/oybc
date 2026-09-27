import { test, expect, seedBoard, seedTask, seedBoardTask, readBoard } from './_fixtures/bypass';

/**
 * E2E coverage for the Board Edit redesign slice 2 title-row "…" board menu
 * (`docs/BOARD_EDIT_REDESIGN.md`, plan T4): `BoardActionsMenu` +
 * `BoardDetailsSheet` / `BoardRepeatSheet` / `CoreDefaultsSheetHost` /
 * `BoardActionConfirmDialog`, composed in `BoardTitleActions`.
 *
 * Scenarios (plan T4 acceptance list):
 *   (a) Ad-hoc menu items; Board details renames the board.
 *   (b) Ongoing board: editing the start date persists (bugfix B1 regression).
 *   (c) Repeat this board… → Weekly → Save → RECURRING badge; reopening
 *       the menu shows Repeating/Paused.
 *   (d) Archive → confirm → lands on /boards.
 *   (e) Delete → confirm → lands on /boards, the card is gone.
 *   (f) Core board in the pager → menu shows only Core defaults… · Delete;
 *       Core defaults… opens the sheet; Delete leaves the pager on the
 *       setup prompt.
 *   (g) A CHOSEN-center one-off has no Repeat item.
 */

const now = new Date();
const pad = (n: number): string => String(n).padStart(2, '0');
const TODAY_DATE = `${now.getFullYear()}-${pad(now.getMonth() + 1)}-${pad(now.getDate())}`;
const DAY_START = `${TODAY_DATE}T00:00:00.000`;
const DAY_END = `${TODAY_DATE}T23:59:59.999`;
const NEXT_MONTH = new Date(now.getTime() + 30 * 24 * 60 * 60 * 1000).toISOString();
const FIVE_DAYS_AGO = new Date(now.getTime() - 5 * 24 * 60 * 60 * 1000).toISOString();
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

test.describe('Board menu — ad-hoc board', () => {
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

  test('shows Board details… · Repeat this board… · Archive · Delete; renaming saves', async ({ page }) => {
    await page.goto(`/boards/${ADHOC_BOARD_ID}?__oybc_test_bypass=1`);
    await expect(page.getByText('Ship the redesign').first()).toBeVisible();

    await page.getByRole('button', { name: 'Board menu' }).click();
    const menu = page.getByRole('menu', { name: 'Board menu' });
    await expect(menu.getByRole('menuitem', { name: 'Board details…' })).toBeVisible();
    await expect(menu.getByRole('menuitem', { name: 'Repeat this board…' })).toBeVisible();
    await expect(menu.getByRole('menuitem', { name: 'Archive' })).toBeVisible();
    await expect(menu.getByRole('menuitem', { name: 'Delete' })).toBeVisible();

    await menu.getByRole('menuitem', { name: 'Board details…' }).click();
    const nameInput = page.locator('#bw-board-name');
    await expect(nameInput).toHaveValue('Ship the redesign');
    await nameInput.fill('Ship the redesign (v2)');
    await page
      .getByRole('dialog', { name: 'Board details' })
      .getByRole('button', { name: 'Save' })
      .click();

    await expect(page.getByRole('heading', { name: 'Ship the redesign (v2)' })).toBeVisible();
    await expect(page.getByText('Board saved')).toBeVisible();
  });
});

test.describe('Board menu — board sealed while Board details is open (D11)', () => {
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
    await page.getByRole('button', { name: 'Board menu' }).click();
    await page.getByRole('menuitem', { name: 'Board details…' }).click();
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

test.describe('Board menu — ongoing board start-date edit (bugfix B1 regression)', () => {
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

    await page.getByRole('button', { name: 'Board menu' }).click();
    await page.getByRole('menuitem', { name: 'Board details…' }).click();

    const startInput = page.locator('#bw-start-date');
    await expect(startInput).toBeVisible();
    await startInput.fill(TEN_DAYS_AGO);
    const saveBtn = page.getByRole('dialog', { name: 'Board details' }).getByRole('button', { name: 'Save' });
    await expect(saveBtn).toBeEnabled();
    await saveBtn.click();

    await expect(page.getByText('Board saved')).toBeVisible();

    await page.reload();
    await page.getByRole('button', { name: 'Board menu' }).click();
    await page.getByRole('menuitem', { name: 'Board details…' }).click();
    await expect(page.locator('#bw-start-date')).toHaveValue(TEN_DAYS_AGO);
  });
});

test.describe('Board menu — Repeat this board…', () => {
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

  test('Weekly → Save shows the RECURRING badge; reopening shows Repeating/Paused', async ({ page }) => {
    await page.goto(`/boards/${ONE_OFF_BOARD_ID}?__oybc_test_bypass=1`);
    await expect(page.getByText('Reading Sprint').first()).toBeVisible();
    await expect(page.getByText('RECURRING', { exact: true })).not.toBeVisible();

    await page.getByRole('button', { name: 'Board menu' }).click();
    await page.getByRole('menuitem', { name: 'Repeat this board…' }).click();
    await page.getByRole('button', { name: 'Weekly', exact: true }).click();
    await page
      .getByRole('dialog', { name: 'Repeat this board' })
      .getByRole('button', { name: 'Save' })
      .click();

    await expect(page.getByText('RECURRING', { exact: true })).toBeVisible();

    await page.getByRole('button', { name: 'Board menu' }).click();
    await page.getByRole('menuitem', { name: 'Repeat this board…' }).click();
    await expect(page.getByRole('group', { name: 'Repeating status' })).toBeVisible();
  });
});

test.describe('Board menu — a CHOSEN-center one-off has no Repeat item', () => {
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

  test('Repeat this board… is absent from the menu', async ({ page }) => {
    await page.goto(`/boards/${CHOSEN_BOARD_ID}?__oybc_test_bypass=1`);
    await expect(page.getByText('Chosen Center Board').first()).toBeVisible();
    await page.getByRole('button', { name: 'Board menu' }).click();
    await expect(page.getByRole('menuitem', { name: 'Repeat this board…' })).not.toBeVisible();
    await expect(page.getByRole('menuitem', { name: 'Board details…' })).toBeVisible();
  });
});

test.describe('Board menu — Archive', () => {
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

    await page.getByRole('button', { name: 'Board menu' }).click();
    await page.getByRole('menuitem', { name: 'Archive' }).click();
    await expect(page.getByRole('alertdialog', { name: 'Archive this board?' })).toBeVisible();
    await page.getByRole('button', { name: 'Archive', exact: true }).click();

    await expect(page).toHaveURL(/\/boards(\?|$)/);
    const board = await readBoard(page, ARCHIVE_BOARD_ID);
    expect(board?.status).toBe('archived');
  });
});

test.describe('Board menu — Delete', () => {
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

    await page.getByRole('button', { name: 'Board menu' }).click();
    await page.getByRole('menuitem', { name: 'Delete' }).click();
    await expect(page.getByRole('alertdialog', { name: 'Delete board?' })).toBeVisible();
    await page.getByRole('button', { name: 'Delete', exact: true }).click();

    await expect(page).toHaveURL(/\/boards(\?|$)/);
    await expect(page.getByText('Throwaway Board')).not.toBeVisible();
    const board = await readBoard(page, DELETE_BOARD_ID);
    expect(board?.isDeleted).toBe(true);
  });
});

test.describe('Board menu — core board', () => {
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
    // "Loading board tasks…" empty state, which is unrelated to this menu.
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

  test('menu shows only Core defaults… · Delete; Core defaults… opens the sheet; Delete leaves the setup prompt', async ({ page }) => {
    await page.goto(`/boards/${CORE_BOARD_ID}?__oybc_test_bypass=1`);
    await expect(page).toHaveURL(new RegExp(`/boards/core/daily/${TODAY_DATE}$`));

    await page.getByRole('button', { name: 'Board menu' }).click();
    const menu = page.getByRole('menu', { name: 'Board menu' });
    await expect(menu.getByRole('menuitem', { name: 'Core defaults…' })).toBeVisible();
    await expect(menu.getByRole('menuitem', { name: 'Delete' })).toBeVisible();
    await expect(menu.getByRole('menuitem', { name: 'Board details…' })).not.toBeVisible();
    await expect(menu.getByRole('menuitem', { name: 'Archive' })).not.toBeVisible();
    await expect(menu.getByRole('menuitem', { name: 'Repeat this board…' })).not.toBeVisible();

    await menu.getByRole('menuitem', { name: 'Core defaults…' }).click();
    await expect(page.getByText('Daily defaults')).toBeVisible();
    await page.getByRole('button', { name: 'Close' }).click();

    await page.getByRole('button', { name: 'Board menu' }).click();
    await page.getByRole('menuitem', { name: 'Delete' }).click();
    await page.getByRole('button', { name: 'Delete', exact: true }).click();

    // Deleting a core board stays in the pager; the window falls back to
    // its lazy setup prompt (no board row is ever auto-created).
    await expect(page).toHaveURL(new RegExp(`/boards/core/daily/${TODAY_DATE}$`));
    await expect(page.getByText(/No board for .* yet\./)).toBeVisible();
  });
});
