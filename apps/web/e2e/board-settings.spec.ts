import { test, expect, seedTemplate, seedTask, readTemplate, readUserPreferences } from './_fixtures/bypass';

/**
 * Coverage for `/profile/board-settings`, restructured into three groups
 * (Profile reorg PR3, `design_handoff_profile_reorg/README.md` §4 "Board
 * settings" / screenshot `4c-board-settings.png`):
 *
 *  - EVERY NEW BOARD: Size / Timeframe / Center square / Week starts
 *    `RisoSegmented` rows, writing `UserPreferences`. The Timeframe row is
 *    the one 5-option full-width control that must never wrap, even at a
 *    393px viewport — asserted via bounding boxes.
 *  - PRE-FILLED TASKS BY TIMEFRAME (renamed from "Core-board defaults";
 *    same rows/behavior, kept as a smoke check).
 *  - REPEATING BOARDS: compact one-line rows (name + timeframe badge, meta
 *    line, Active/Paused toggle, chevron) replacing the old expanded rows
 *    with pool-preview chips + "Edit tasks"/"Delete" buttons. The toggle
 *    flips `isActive` in Dexie without navigating; the row itself opens the
 *    existing template editor; "New ›" deep-links into the Create hub's
 *    recurring wizard entry.
 */
test.describe('Board settings page', () => {
  test('renders the three section headings + pre-filled-tasks rows + empty repeating state', async ({
    page,
  }) => {
    await page.goto('/profile/board-settings?__oybc_test_bypass=1');

    await expect(page.getByRole('heading', { name: 'Board settings' })).toBeVisible();

    await expect(page.getByText('Every new board')).toBeVisible();
    await expect(page.getByRole('group', { name: 'Default board size' })).toBeVisible();
    await expect(page.getByRole('group', { name: 'Default timeframe' })).toBeVisible();
    await expect(page.getByRole('group', { name: 'Default center square' })).toBeVisible();
    await expect(page.getByRole('group', { name: 'Week starts on' })).toBeVisible();
    await expect(page.getByText('Sets when weekly boards reset and renew.')).toBeVisible();

    await expect(page.getByText('Pre-filled tasks by timeframe')).toBeVisible();
    const prefilledTasksGroup = page.getByRole('group', { name: 'Pre-filled tasks by timeframe' });
    await expect(prefilledTasksGroup.getByRole('button', { name: /^Daily/ })).toBeVisible();
    await expect(prefilledTasksGroup.getByRole('button', { name: /^Weekly/ })).toBeVisible();
    await expect(prefilledTasksGroup.getByRole('button', { name: /^Monthly/ })).toBeVisible();
    await expect(prefilledTasksGroup.getByRole('button', { name: /^Yearly/ })).toBeVisible();

    // Repeating-boards roster: no templates seeded, so the empty state
    // renders (never a hang on a missing route).
    await expect(page.getByText('Repeating boards', { exact: true })).toBeVisible();
    await expect(page.getByText(/no repeating boards yet/i)).toBeVisible();

    // Footer helper — web diverges one word from the iOS copy (no
    // Notifications sub-page on web; renewal toggles live on Settings
    // directly).
    await expect(
      page.getByText('Tap a board to edit its pool and cadence. Renewal reminders are under Settings.'),
    ).toBeVisible();
  });

  test('Every new board: Size segmented writes UserPreferences', async ({ page }) => {
    await page.goto('/profile/board-settings?__oybc_test_bypass=1');

    const sizeGroup = page.getByRole('group', { name: 'Default board size' });
    await sizeGroup.getByRole('button', { name: '4×4', exact: true }).click();
    await expect(sizeGroup.getByRole('button', { name: '4×4', exact: true })).toHaveAttribute(
      'aria-pressed',
      'true',
    );

    const prefs = await readUserPreferences(page);
    expect((prefs as Record<string, unknown>).defaultBoardSize).toBe(4);
  });

  test('Every new board: the 5-option Timeframe row never wraps, even at a 393px viewport', async ({
    page,
  }) => {
    await page.setViewportSize({ width: 393, height: 844 });
    await page.goto('/profile/board-settings?__oybc_test_bypass=1');

    const timeframeGroup = page.getByRole('group', { name: 'Default timeframe' });
    await expect(timeframeGroup).toBeVisible();

    const labels = ['Custom', 'Daily', 'Weekly', 'Monthly', 'Yearly'];
    const boxes = await Promise.all(
      labels.map(async (label) => {
        const box = await timeframeGroup.getByRole('button', { name: label, exact: true }).boundingBox();
        expect(box).not.toBeNull();
        return box!;
      }),
    );

    // All five segments share the same row (same top y, within a hairline
    // of rounding) — a wrap would place later segments at a greater y.
    const firstTop = boxes[0].y;
    for (const box of boxes) {
      expect(Math.abs(box.y - firstTop)).toBeLessThan(2);
    }

    // No page-level horizontal scroll from an overflowing full-width row.
    const hasHorizontalOverflow = await page.evaluate(
      () => document.documentElement.scrollWidth > document.documentElement.clientWidth,
    );
    expect(hasHorizontalOverflow).toBe(false);
  });

  test.describe('Repeating boards roster', () => {
    const ACTIVE_ID = 'ffffffff-0000-0000-0000-000000000001';
    const PAUSED_ID = 'ffffffff-0000-0000-0000-000000000002';

    test.beforeEach(async ({ page }) => {
      const activeTaskIds = Array.from({ length: 9 }, (_, i) => `ffffffff-1111-0000-0000-00000000000${i}`);
      const pausedTaskIds = Array.from({ length: 8 }, (_, i) => `ffffffff-2222-0000-0000-00000000000${i}`);
      // Seed real Task rows for every seedTaskIds entry — the roster's
      // "N-task pool" count is the ACHIEVABLE resolved size
      // (`useTemplateRosterHealth`), not the raw array length, so an
      // unresolvable id would undercount (or badge `has_deleted_tasks`).
      for (const id of [...activeTaskIds, ...pausedTaskIds]) {
        await seedTask(page, { id, title: `Task ${id}`, type: 'normal' });
      }
      await seedTemplate(page, {
        id: ACTIVE_ID,
        name: 'Morning Routine',
        timeframe: 'weekly',
        boardSize: 5,
        centerSquareType: 'free',
        isRandomized: true,
        seedTaskIds: activeTaskIds,
        isActive: true,
      });
      await seedTemplate(page, {
        id: PAUSED_ID,
        name: 'Weekend Reset',
        timeframe: 'weekly',
        boardSize: 3,
        centerSquareType: 'none',
        isRandomized: true,
        seedTaskIds: pausedTaskIds,
        isActive: false,
      });
    });

    test('shows a compact one-line row per template: name, timeframe badge, and the renews/paused meta line', async ({
      page,
    }) => {
      await page.goto('/profile/board-settings?__oybc_test_bypass=1');

      const activeRow = page.getByRole('button', { name: /Morning Routine/ });
      await expect(activeRow).toBeVisible();
      await expect(activeRow).toContainText('WEEKLY');
      await expect(activeRow).toContainText('5×5 board · 9-task pool · renews Mondays');

      const pausedRow = page.getByRole('button', { name: /Weekend Reset/ });
      await expect(pausedRow).toBeVisible();
      await expect(pausedRow).toContainText('3×3 board · 8-task pool · paused');

      // Dropped from the list per owner decision — pool-preview chips and
      // the separate Edit tasks / Delete buttons stay in the editor only.
      await expect(page.getByRole('button', { name: 'Edit tasks' })).toHaveCount(0);
      await expect(page.getByRole('button', { name: /^Delete /i })).toHaveCount(0);
    });

    test('the toggle flips isActive in Dexie without opening the editor', async ({ page }) => {
      await page.goto('/profile/board-settings?__oybc_test_bypass=1');

      // Scope to the row by its stable name (the template name never
      // changes), then find the ONE checkbox inside it — not by the
      // checkbox's OWN aria-label, which flips between "Pause "/"Resume "
      // the instant the toggle is clicked and would go stale mid-test.
      const activeRow = page.getByRole('button', { name: /Morning Routine/ });
      const activeToggle = activeRow.getByRole('checkbox');
      // The checkbox itself is visually hidden (the styled track is the
      // visible affordance) — same pattern as CoreDefaultsSheet's "Free
      // space" toggle. Interact via the wrapping `<label>` (native
      // label-click semantics forward the click to its descendant input)
      // rather than Playwright's visibility-gated click on the checkbox.
      const activeToggleLabel = activeToggle.locator('xpath=ancestor::label[1]');
      await expect(activeToggle).toBeChecked();
      await activeToggleLabel.click();
      await expect(activeToggle).toBeChecked({ checked: false });

      // Still on Board settings — the toggle click did not open the wizard.
      await expect(page.getByRole('heading', { name: 'Board settings' })).toBeVisible();

      const saved = await readTemplate(page, ACTIVE_ID);
      expect((saved as Record<string, unknown>).isActive).toBe(false);

      const pausedRow = page.getByRole('button', { name: /Weekend Reset/ });
      const pausedToggle = pausedRow.getByRole('checkbox');
      const pausedToggleLabel = pausedToggle.locator('xpath=ancestor::label[1]');
      await expect(pausedToggle).not.toBeChecked();
      await pausedToggleLabel.click();
      await expect(pausedToggle).toBeChecked();
      const resumed = await readTemplate(page, PAUSED_ID);
      expect((resumed as Record<string, unknown>).isActive).toBe(true);
    });

    test('clicking the row (not the toggle) opens the existing template editor', async ({ page }) => {
      await page.goto('/profile/board-settings?__oybc_test_bypass=1');

      await page.getByRole('button', { name: /Morning Routine/ }).click();
      await expect(page.getByText('EDIT RECURRING BOARD')).toBeVisible();
    });

    test('"New ›" opens the Create hub\'s repeating-board wizard entry directly', async ({ page }) => {
      await page.goto('/profile/board-settings?__oybc_test_bypass=1');

      await page.getByRole('link', { name: /New/ }).click();
      await expect(page.getByLabel(/board name/i)).toBeVisible();
      await expect(page.getByRole('group', { name: 'Repeats every' })).toBeVisible();
      await expect(page.getByRole('group', { name: 'Timeframe' })).toHaveCount(0);
    });

    test('Delete lives in the editor: row → "Delete repeating board" → confirm → row gone + Dexie tombstone', async ({
      page,
    }) => {
      await page.goto('/profile/board-settings?__oybc_test_bypass=1');

      // The list itself carries no Delete (owner decision) …
      await expect(page.getByRole('button', { name: /^Delete /i })).toHaveCount(0);

      // … the editor's Setup step does (Profile reorg PR3 self-review).
      await page.getByRole('button', { name: /Weekend Reset/ }).click();
      await expect(page.getByText('EDIT RECURRING BOARD')).toBeVisible();
      await page.getByRole('button', { name: 'Delete repeating board' }).click();

      const confirm = page.getByRole('alertdialog', { name: 'Confirm delete repeating board' });
      await expect(confirm).toBeVisible();
      await expect(confirm).toContainText('Delete "Weekend Reset"?');
      await expect(confirm).toContainText('Boards already created from it will not be deleted.');

      // Cancel backs out with nothing written.
      await confirm.getByRole('button', { name: 'Cancel' }).click();
      await expect(confirm).toBeHidden();
      expect(((await readTemplate(page, PAUSED_ID)) as Record<string, unknown>).isDeleted).toBe(false);

      // Confirm deletes, closes the editor, and lands back on Board settings.
      await page.getByRole('button', { name: 'Delete repeating board' }).click();
      await confirm.getByRole('button', { name: 'Delete', exact: true }).click();
      await expect(page.getByRole('heading', { name: 'Board settings' })).toBeVisible();
      await expect(page.getByText('EDIT RECURRING BOARD')).toHaveCount(0);
      await expect(page.getByRole('button', { name: /Weekend Reset/ })).toHaveCount(0);
      // The other board is untouched.
      await expect(page.getByRole('button', { name: /Morning Routine/ })).toBeVisible();

      // Same op the old roster button called: soft-delete tombstone + version bump.
      const deleted = (await readTemplate(page, PAUSED_ID)) as Record<string, unknown>;
      expect(deleted.isDeleted).toBe(true);
      expect(deleted.deletedAt).toBeTruthy();
      expect(deleted.version).toBe(2);
    });
  });
});
