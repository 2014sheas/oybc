import {
  test,
  expect,
  seedBoard,
  seedTask,
  seedBoardTask,
} from './_fixtures/bypass';

/**
 * E2E coverage for the Tasks tab (post-extraction from Create).
 *
 * The Create tab no longer surfaces the library; everything goes through
 * `/tasks`. These tests seed a small mixed-type library + a board with a
 * placement, then exercise the full happy-path:
 *
 * 1. Navigate to the tab.
 * 2. Verify each seeded task renders.
 * 3. Apply the Normal type filter and confirm filtering works.
 * 4. Tap a row → detail page mounts.
 * 5. Edit the title → list reflects the change.
 * 6. Delete → cascade dialog → list updates.
 *
 * The cascade-delete impact preview is asserted explicitly because the
 * cascade is the bulk of the new persistence surface (the only path
 * that calls `deleteTaskWithCascade`).
 */

const NORMAL_ID = 'dddddddd-0001-0000-0000-000000000001';
const COUNTING_ID = 'dddddddd-0002-0000-0000-000000000002';
const PLACED_ID = 'dddddddd-0003-0000-0000-000000000003';
const BOARD_ID = 'dddddddd-bbbb-0000-0000-000000000001';

test.describe('Tasks tab', () => {
  test.beforeEach(async ({ page }) => {
    // Seed a normal task (will be edited + deleted), a counting task
    // (different type for filter assertions), and a placed task (so
    // the cascade dialog has placements to report).
    await seedTask(page, { id: NORMAL_ID, title: 'Read for 30 minutes', type: 'normal' });
    await seedTask(page, {
      id: COUNTING_ID,
      title: 'Run miles',
      type: 'counting',
      // SeedTask doesn't carry counting fields; the detail page only
      // uses them for display, and the type-filter assertion doesn't
      // need them. Set via a second update if needed.
    });
    await seedTask(page, { id: PLACED_ID, title: 'Stretch', type: 'normal' });
    await seedBoard(page, {
      id: BOARD_ID,
      name: 'Test Board',
      boardSize: 5,
      timeframe: 'weekly',
      status: 'active',
      startDate: '2026-05-11',
      endDate: '2026-05-17',
    });
    await seedBoardTask(page, {
      id: 'dddddddd-bt00-0000-0000-000000000001',
      boardId: BOARD_ID,
      taskId: PLACED_ID,
      row: 0,
      col: 0,
    });
  });

  test('Tasks tab lists seeded tasks and renders the right empty/filter affordances', async ({ page }) => {
    await page.getByRole('link', { name: /tasks/i }).click();
    await expect(page.getByRole('heading', { name: 'Tasks', level: 1 })).toBeVisible();
    await expect(page.getByText('Read for 30 minutes')).toBeVisible();
    await expect(page.getByText('Run miles')).toBeVisible();
    await expect(page.getByText('Stretch')).toBeVisible();

    // Apply the Normal type filter — Run miles (counting) drops out.
    // Scope to the type-filter group so we don't collide with the
    // quick-add form's type selector, which also has a "Normal" button.
    await page
      .getByRole('group', { name: /filter by task type/i })
      .getByRole('button', { name: 'Normal', exact: true })
      .click();
    await expect(page.getByText('Read for 30 minutes')).toBeVisible();
    await expect(page.getByText('Stretch')).toBeVisible();
    await expect(page.getByText('Run miles')).not.toBeVisible();
  });

  test('Edit flow: tapping a task opens detail, saving a title change reflects on the list', async ({ page }) => {
    await page.getByRole('link', { name: /tasks/i }).click();

    // Tap the Read row to navigate to detail. The list rows have aria-labels
    // like 'Open Read for 30 minutes details'.
    await page.getByRole('button', { name: /open read for 30 minutes details/i }).click();

    // Detail page mounts at /tasks/<id>.
    await expect(page).toHaveURL(/\/tasks\/dddddddd-0001/);
    await expect(page.getByRole('heading', { name: 'Read for 30 minutes' })).toBeVisible();

    // Edit. Title field is in the edit sheet; rename and save.
    await page.getByRole('button', { name: 'Edit' }).click();
    const titleInput = page.getByRole('dialog', { name: 'Edit task' }).getByLabel(/title/i);
    await titleInput.fill('Read for 45 minutes');
    await page.getByRole('button', { name: /save changes/i }).click();

    // Detail page reflects the new title; navigate back to the list and
    // confirm it shows there too (Dexie live-query propagation).
    await expect(page.getByRole('heading', { name: 'Read for 45 minutes' })).toBeVisible();
    await page.getByRole('link', { name: '‹ Tasks' }).click();
    await expect(page.getByText('Read for 45 minutes')).toBeVisible();
    await expect(page.getByText('Read for 30 minutes')).not.toBeVisible();
  });

  test('Delete flow: cascade dialog surfaces placement count and removes the row on confirm', async ({ page }) => {
    await page.getByRole('link', { name: /tasks/i }).click();
    await page
      .getByRole('button', { name: /open stretch details/i })
      .click();

    await page.getByRole('button', { name: 'Delete' }).click();

    // Confirm dialog shows the cascade impact. "Stretch" sits on 1 board.
    const dialog = page.getByRole('alertdialog', { name: 'Confirm delete' });
    await expect(dialog).toBeVisible();
    await expect(dialog.getByText(/Removes from 1 board square/i)).toBeVisible();

    // Confirm. The detail page navigates back to /tasks and the row is gone.
    await dialog.getByRole('button', { name: 'Delete' }).click();
    await expect(page).toHaveURL(/\/tasks$/);
    await expect(page.getByText('Stretch')).not.toBeVisible();
  });

  test('Create tab no longer surfaces the task library', async ({ page }) => {
    // Verifies the Phase D relocation: CreateHub used to render a
    // "Your task library" section + quick-add form. Both should now be
    // missing.
    await page.getByRole('link', { name: /create/i }).click();
    await expect(page.getByRole('heading', { name: 'Create', level: 1 })).toBeVisible();
    await expect(page.getByText(/your task library/i)).not.toBeVisible();
    // The quick-add form's submit was titled "Add to library" on the
    // hub; with the form removed, the button shouldn't be present here.
    await expect(page.getByRole('button', { name: /add to library/i })).not.toBeVisible();
  });
});
