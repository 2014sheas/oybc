import {
  test,
  expect,
  openCreateHub,
  seedPool,
  seedTask,
  startOneOffWizard,
} from './_fixtures/bypass';

/**
 * Board Sources P4 (docs/BOARD_SOURCES.md §Surfaces items 1–2) — e2e
 * coverage for the wizard's Tasks-step sources model: pulling a pool via
 * the "Add a pool or board" sheet creates a source ROW (not a flat task
 * union), the header counts CAPACITY, the expanded panel's member ✕
 * excludes a task for this board only (UNDO restores), a hand-added task
 * survives removing the source, and the sheet shows its empty state when
 * nothing is pullable.
 *
 * Uses the one-off ("Start a one-off board") entry point — the sources
 * behavior is identical for one-off and recurring boards.
 */

test.describe('Wizard Tasks step — sources (Board Sources P4)', () => {
  test('pulling a pool adds a source row; exclude/UNDO adjust capacity; a hand-added task survives source removal', async ({
    page,
  }) => {
    // 8 tasks so pulling the pool exactly satisfies a 3×3-FREE board
    // (fillableCellCount = 8) — makes the "8/8" satisfied state visible.
    const poolTaskIds = Array.from(
      { length: 8 },
      (_, i) => `aaaaaaaa-0000-0000-0000-00000000000${i}`,
    );
    for (const [i, id] of poolTaskIds.entries()) {
      await seedTask(page, { id, title: `Pool Task ${i + 1}`, type: 'normal' });
    }
    const manualTaskId = 'bbbbbbbb-0000-0000-0000-000000000001';
    await seedTask(page, { id: manualTaskId, title: 'Manual Task', type: 'normal' });

    await seedPool(page, {
      id: 'cccccccc-0000-0000-0000-000000000001',
      name: 'Morning Kickstart',
      taskIds: poolTaskIds,
    });

    // Enter the one-off wizard, force 3×3 + Daily (avoids the CUSTOM
    // default's start/end date requirement), then advance to step 2.
    await openCreateHub(page);
    await startOneOffWizard(page);
    await page.getByLabel(/board name/i).fill('Sources Test Board');
    await page.getByRole('button', { name: '3×3', exact: true }).click();
    await page
      .getByRole('group', { name: 'Timeframe' })
      .getByRole('button', { name: 'Daily', exact: true })
      .click();
    await page.getByRole('button', { name: /^Next/ }).click();

    // Step 2 mounted — the dashed "Add a pool or board" entry opens the
    // source sheet with the seeded pool as a toggleable row.
    await page.getByRole('button', { name: 'Add a pool or board' }).click();
    const sourceSheet = page.getByRole('dialog', { name: 'Add a pool or board' });
    await expect(sourceSheet).toBeVisible();
    const sheetPoolRow = sourceSheet.getByRole('button', { name: /Morning Kickstart/ });
    await expect(sheetPoolRow).toHaveAttribute('aria-pressed', 'false');
    await page.waitForTimeout(200);
    await page.screenshot({ path: '.playwright-mcp/sources-01-sheet-open.png' });

    // Pull it: the row checks, and after Done the source renders as ONE
    // row in "On your board" with a live subtitle; the header counts
    // CAPACITY (sum of source maxes + hand-added) — 8/8 satisfied.
    await sheetPoolRow.click();
    await expect(sheetPoolRow).toHaveAttribute('aria-pressed', 'true');
    await sourceSheet.getByRole('button', { name: 'Done', exact: true }).click();
    await expect(sourceSheet).toBeHidden();

    const sourceRow = page.getByRole('button', { name: /Morning Kickstart, 8 tasks/ });
    await expect(sourceRow).toBeVisible();
    await expect(page.getByLabel('Capacity 8 of 8 tasks')).toBeVisible();

    // P5 lock — the retired affordances are GONE: no pull-chip card, no
    // "Save these N as a pool…", no provenance subtitles.
    await expect(page.getByText('Pull in a pool')).toHaveCount(0);
    await expect(page.getByRole('button', { name: /Save these .* as a new pool/ })).toHaveCount(0);
    await expect(page.getByText(/from Morning Kickstart/)).toHaveCount(0);
    await expect(page.getByText('added by hand')).toHaveCount(0);
    await page.waitForTimeout(200);
    await page.screenshot({ path: '.playwright-mcp/sources-02-source-row.png' });

    // Expand the row: the range block + member rows appear. Exclude one
    // member for this board only — the subtitle gains "1 excluded", the
    // capacity drops to 7/8, and the red gate line appears.
    await sourceRow.click();
    await expect(sourceRow).toHaveAttribute('aria-expanded', 'true');
    await page
      .getByRole('button', { name: 'Exclude Pool Task 1 for this board' })
      .click();
    await expect(
      page.getByRole('button', { name: /Morning Kickstart, 8 tasks · 1 excluded/ }),
    ).toBeVisible();
    await expect(page.getByLabel('Capacity 7 of 8 tasks')).toBeVisible();
    await expect(page.getByText('! Add 1 more')).toBeVisible();
    await page.waitForTimeout(200);
    await page.screenshot({ path: '.playwright-mcp/sources-03-excluded.png' });

    // UNDO restores the member; capacity returns to 8/8.
    await page.getByRole('button', { name: 'Undo excluding Pool Task 1' }).click();
    await expect(page.getByLabel('Capacity 8 of 8 tasks')).toBeVisible();

    // Hand-add an unrelated existing task via the quick-add row's
    // library-poll dropdown; it renders as its own task row and bumps
    // capacity to 9/8.
    await page.getByLabel('New normal task title').fill('Manual Task');
    const manualMatch = page
      .getByRole('list', { name: 'Matching library tasks' })
      .getByRole('button', { name: /Manual Task/ });
    await expect(manualMatch).toBeVisible();
    await manualMatch.click();

    const manualRow = page.getByRole('listitem').filter({ hasText: 'Manual Task' });
    await expect(manualRow).toBeVisible();
    await expect(page.getByLabel('Capacity 9 of 8 tasks')).toBeVisible();
    await page.waitForTimeout(200);
    await page.screenshot({ path: '.playwright-mcp/sources-04-manual-add.png' });

    // Remove the source via the row's ✕: the source's tasks drop; the
    // hand-added task survives (the manual layer is never touched by a
    // source removal).
    await page.getByRole('button', { name: 'Remove Morning Kickstart' }).click();
    await expect(sourceRow).toHaveCount(0);
    await expect(manualRow).toBeVisible();
    await expect(page.getByLabel('Capacity 1 of 8 tasks')).toBeVisible();
    await page.waitForTimeout(200);
    await page.screenshot({ path: '.playwright-mcp/sources-05-source-removed.png' });
  });

  test('shows the sheet empty state when the user has nothing to pull from', async ({
    page,
  }) => {
    await openCreateHub(page);
    await startOneOffWizard(page);
    await page.getByLabel(/board name/i).fill('No Sources Yet Board');
    await page
      .getByRole('group', { name: 'Timeframe' })
      .getByRole('button', { name: 'Daily', exact: true })
      .click();
    await page.getByRole('button', { name: /^Next/ }).click();

    await page.getByRole('button', { name: 'Add a pool or board' }).click();
    const sourceSheet = page.getByRole('dialog', { name: 'Add a pool or board' });
    await expect(sourceSheet.getByText('Nothing to pull from yet')).toBeVisible();
    await expect(
      sourceSheet.getByText('Boards you make and pools you save will show up here.'),
    ).toBeVisible();
  });
});
