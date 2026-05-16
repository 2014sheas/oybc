import {
  test,
  expect,
  seedBoard,
  seedTask,
  seedBoardTask,
  seedCompoundChild,
  readCompoundChild,
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

  test('+ Create task opens the sheet; submitting closes it and the new row appears', async ({ page }) => {
    // After PR #57's first iteration, the quick-add form dominated the
    // Tasks tab. The refactor moves it behind a sheet so the library
    // is the primary surface. This locks the open/submit/close cycle
    // + the live-query refresh path that gets the row into the list.
    await page.getByRole('link', { name: /tasks/i }).click();

    // The form should NOT be rendered inline anymore — only the trigger.
    await expect(page.getByPlaceholder(/enter task title/i)).not.toBeVisible();
    await page.getByRole('button', { name: /\+ Create task/i }).click();

    const sheet = page.getByRole('dialog', { name: 'New task' });
    await expect(sheet).toBeVisible();
    await sheet.getByPlaceholder(/enter task title/i).fill('Brushed teeth');
    await sheet.getByRole('button', { name: /add to library/i }).click();

    // Sheet auto-dismisses on success.
    await expect(sheet).not.toBeVisible();
    // useLiveQuery picks up the new row; it should appear in the list
    // without any explicit refresh.
    await expect(page.getByText('Brushed teeth')).toBeVisible();
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

  test('search matches description text, not just title', async ({ page }) => {
    // The wizard's filter only checks `title`; the Tasks tab extends
    // matching to `description` so power users can find things by note.
    // Seed an extra task with description-only signal.
    const DESC_ID = 'dddddddd-0009-0000-0000-000000000009';
    await seedTask(page, {
      id: DESC_ID,
      title: 'Plain title',
      description: 'Includes the word goldfinch',
      type: 'normal',
    });

    await page.getByRole('link', { name: /tasks/i }).click();
    await page.getByPlaceholder(/search tasks/i).fill('goldfinch');

    // Only the description-matched task should remain.
    await expect(page.getByText('Plain title')).toBeVisible();
    await expect(page.getByText('Read for 30 minutes')).not.toBeVisible();
    await expect(page.getByText('Run miles')).not.toBeVisible();
  });

  test('sort: Title A→Z reorders the list alphabetically', async ({ page }) => {
    await page.getByRole('link', { name: /tasks/i }).click();

    // Sort lives behind the Filters disclosure now — open it first.
    await page.getByRole('button', { name: /^Filters/ }).click();

    // Default sort is "Recently updated" — seeds went in in the
    // beforeEach order, so we can't make a strong claim about the
    // initial order. What we can verify: after switching to title-asc,
    // the rows appear in alphabetic order regardless.
    await page.getByLabel('Sort').selectOption('title-asc');

    // Read the rendered task names in DOM order via aria-labels.
    const rowNames = await page
      .locator('ul[aria-label="Task list"] button')
      .evaluateAll((nodes) => nodes.map((n) => n.getAttribute('aria-label') ?? ''));
    // Strip the aria-label scaffolding to just the title.
    const titles = rowNames.map((s) =>
      s.replace(/^Open /, '').replace(/ details$/, '').replace(/^"|"$/g, ''),
    );
    const sortedTitles = [...titles].sort((a, b) => a.localeCompare(b));
    expect(titles).toEqual(sortedTitles);
  });

  test('usage filter "Unused" hides tasks placed on any board', async ({ page }) => {
    await page.getByRole('link', { name: /tasks/i }).click();
    // Usage lives behind the Filters disclosure now — open it first.
    await page.getByRole('button', { name: /^Filters/ }).click();
    // Stretch is the placed task; the others (Read, Run miles) are unplaced.
    await page.getByLabel('Usage').selectOption('unused');

    await expect(page.getByText('Read for 30 minutes')).toBeVisible();
    await expect(page.getByText('Run miles')).toBeVisible();
    await expect(page.getByText('Stretch')).not.toBeVisible();
  });

  test('edit cancel leaves the task untouched', async ({ page }) => {
    await page.getByRole('link', { name: /tasks/i }).click();
    await page.getByRole('button', { name: /open read for 30 minutes details/i }).click();
    await page.getByRole('button', { name: 'Edit' }).click();

    // Change the title but cancel — list should still show the original.
    const dialog = page.getByRole('dialog', { name: 'Edit task' });
    await dialog.getByLabel(/title/i).fill('THIS SHOULD NOT PERSIST');
    await dialog.getByRole('button', { name: 'Cancel' }).click();

    // Sheet closes; detail still shows the original title.
    await expect(page.getByRole('heading', { name: 'Read for 30 minutes' })).toBeVisible();

    // Round-trip via the list to confirm Dexie didn't get the update.
    await page.getByRole('link', { name: '‹ Tasks' }).click();
    await expect(page.getByText('Read for 30 minutes')).toBeVisible();
    await expect(page.getByText('THIS SHOULD NOT PERSIST')).not.toBeVisible();
  });

  test('navigating to a bogus task id redirects back to /tasks', async ({ page }) => {
    // Regression: a previous implementation relied on `useLiveQuery`
    // returning null for missing keys, but it returns `undefined` for
    // BOTH "still loading" and "no row matches" — so the redirect
    // effect short-circuited and the user got stuck on a Loading…
    // spinner. The fix uses a parallel one-shot `db.tasks.get(id)` to
    // distinguish loading from missing.
    await page.goto('/tasks/bogus-id-that-does-not-exist?__oybc_test_bypass=1');
    await expect(page).toHaveURL(/\/tasks$/);
    await expect(page.getByRole('heading', { name: 'Tasks', level: 1 })).toBeVisible();
  });

  test('Filters disclosure: hides Sort/Status/Usage by default, badge + Clear all', async ({ page }) => {
    await page.getByRole('link', { name: /tasks/i }).click();

    // Defaults: secondary controls collapsed, no badge.
    await expect(page.getByLabel('Sort')).not.toBeVisible();
    await expect(page.getByLabel('Status')).not.toBeVisible();
    await expect(page.getByLabel('Usage')).not.toBeVisible();
    const filtersButton = page.getByRole('button', { name: /^Filters/ });
    await expect(filtersButton).toBeVisible();
    // The "Filters active" badge sibling is a span with aria-label;
    // when no filter is active it shouldn't render.
    await expect(page.getByLabel('Filters active')).not.toBeVisible();

    // Open the panel.
    await filtersButton.click();
    await expect(page.getByLabel('Sort')).toBeVisible();
    await expect(page.getByLabel('Status')).toBeVisible();
    await expect(page.getByLabel('Usage')).toBeVisible();

    // Change one filter — badge should appear once the panel is
    // closed AND a Clear all button shows inside the panel.
    await page.getByLabel('Status').selectOption('completed');
    await expect(
      page.getByRole('button', { name: /clear all/i }),
    ).toBeVisible();

    // Close, confirm the badge sticks.
    await filtersButton.click();
    await expect(page.getByLabel('Filters active')).toBeVisible();

    // Re-open and Clear all → badge disappears, dropdowns hide again.
    await filtersButton.click();
    await page.getByRole('button', { name: /clear all/i }).click();
    await filtersButton.click(); // collapse panel
    await expect(page.getByLabel('Filters active')).not.toBeVisible();
  });

  test('board square → Open in library opens TaskDetailSheet over BoardPlay', async ({ page }) => {
    // The placed task "Stretch" sits on Test Board. Right-clicking the
    // square opens the FloatingContextMenu, which gained an "Open in
    // library" item that mounts TaskDetailSheet — preserving board
    // context (no navigation away from /boards/:id).
    await page.goto(`/boards/${BOARD_ID}?__oybc_test_bypass=1`);
    await expect(page.getByRole('heading', { name: 'Test Board' })).toBeVisible();

    // The placed square's aria-label is the task title. Right-click to
    // open the FloatingContextMenu.
    const square = page.getByRole('button', { name: 'Stretch' }).first();
    await square.click({ button: 'right' });

    // The new menu item is the only place "Open in library" appears.
    await page.getByRole('button', { name: /open in library/i }).click();

    // TaskDetailSheet mounts over BoardPlay — the task title appears as
    // the detail heading. URL stays on the board (sheet is overlay state,
    // not navigation).
    await expect(page).toHaveURL(new RegExp(`/boards/${BOARD_ID}`));
    await expect(
      page.getByRole('heading', { name: 'Stretch', level: 1 }),
    ).toBeVisible();

    // The sheet shows the Usage section listing this board.
    await expect(page.getByText('Total completions:')).toBeVisible();
  });

  test('detail page shows parent-compound back-ref when task is a child', async ({ page }) => {
    // Set up: a compound parent "Workout routine" with one child "Pushups".
    // From the child's detail page, the new "Subtask of" section should
    // surface the parent compound.
    const PARENT_ID = 'eeeeeeee-0011-0000-0000-000000000011';
    const CHILD_ID = 'eeeeeeee-0012-0000-0000-000000000012';
    const LINK_ID = 'eeeeeeee-aaaa-0000-0000-000000000011';
    await seedTask(page, { id: PARENT_ID, title: 'Workout routine', type: 'compound', isOrdered: false });
    await seedTask(page, { id: CHILD_ID, title: 'Pushups', type: 'normal' });
    await seedCompoundChild(page, {
      id: LINK_ID,
      compoundTaskId: PARENT_ID,
      childTaskId: CHILD_ID,
      childIndex: 0,
    });

    await page.getByRole('link', { name: /tasks/i }).click();
    await page.getByRole('button', { name: /open pushups details/i }).click();

    // The "Subtask of" section renders a chip linking back to the parent.
    await expect(page.getByRole('heading', { name: /^subtask of$/i })).toBeVisible();
    await expect(
      page.getByRole('button', { name: /open parent task: workout routine/i }),
    ).toBeVisible();
  });

  test('row shows "Last completed" relative time after a toggle', async ({ page }) => {
    // Toggle the placed task complete on the board, then return to the
    // library — the row's meta line gains "Last completed just now".
    await page.goto(`/boards/${BOARD_ID}?__oybc_test_bypass=1`);
    await page.getByRole('button', { name: 'Stretch' }).first().click();

    // Navigate back to the Tasks tab and find the Stretch row.
    await page.getByRole('link', { name: /tasks/i }).click();
    const stretchRow = page.getByRole('button', { name: /open stretch details/i });
    await expect(stretchRow).toBeVisible();
    // The meta line is rendered inside the row button. "Last completed"
    // appears when completedAt is set; for a fresh toggle it's "just now".
    await expect(stretchRow).toContainText(/last completed/i);
  });

  test('compound cascade: deleting a parent severs all child-link rows', async ({ page }) => {
    // Build a compound parent + two child tasks linked via compound_children
    // rows. The cascade impact dialog should report 2 subtasks; after
    // confirm, both link rows should be soft-deleted but the child Tasks
    // themselves remain in the library.
    const PARENT_ID = 'eeeeeeee-0001-0000-0000-000000000001';
    const CHILD_A_ID = 'eeeeeeee-0002-0000-0000-000000000002';
    const CHILD_B_ID = 'eeeeeeee-0003-0000-0000-000000000003';
    const LINK_A_ID = 'eeeeeeee-aaaa-0000-0000-000000000001';
    const LINK_B_ID = 'eeeeeeee-aaaa-0000-0000-000000000002';

    await seedTask(page, { id: PARENT_ID, title: 'Workout routine', type: 'compound', isOrdered: false });
    await seedTask(page, { id: CHILD_A_ID, title: 'Pushups', type: 'normal' });
    await seedTask(page, { id: CHILD_B_ID, title: 'Squats', type: 'normal' });
    await seedCompoundChild(page, {
      id: LINK_A_ID,
      compoundTaskId: PARENT_ID,
      childTaskId: CHILD_A_ID,
      childIndex: 0,
    });
    await seedCompoundChild(page, {
      id: LINK_B_ID,
      compoundTaskId: PARENT_ID,
      childTaskId: CHILD_B_ID,
      childIndex: 1,
    });

    await page.getByRole('link', { name: /tasks/i }).click();
    await page.getByRole('button', { name: /open workout routine details/i }).click();
    await page.getByRole('button', { name: 'Delete' }).click();

    const dialog = page.getByRole('alertdialog', { name: 'Confirm delete' });
    await expect(dialog).toBeVisible();
    await expect(dialog.getByText(/Releases 2 subtasks/i)).toBeVisible();
    await dialog.getByRole('button', { name: 'Delete' }).click();

    // Back on the list — the compound parent is gone, but Pushups + Squats
    // remain as standalone library tasks.
    await expect(page).toHaveURL(/\/tasks$/);
    await expect(page.getByText('Workout routine')).not.toBeVisible();
    await expect(page.getByText('Pushups')).toBeVisible();
    await expect(page.getByText('Squats')).toBeVisible();

    // The compound_children link rows themselves should have isDeleted=true
    // (soft-delete) — verify directly via IndexedDB. The web cascade only
    // *flags* the rows; it doesn't remove them from the table so the sync
    // queue can drain the tombstone to Firestore.
    const linkA = await readCompoundChild(page, LINK_A_ID);
    const linkB = await readCompoundChild(page, LINK_B_ID);
    expect(linkA?.isDeleted).toBe(true);
    expect(linkB?.isDeleted).toBe(true);
  });
});
