import {
  test,
  expect,
  openCreateHub,
  seedPool,
  seedTask,
  startOneOffWizard,
} from './_fixtures/bypass';

/**
 * P3 (Task Pools + Recurring Boards Rework, docs/POOLS_RECURRING.md
 * §Surfaces item 5 "Wizard step 2") — e2e coverage for the wizard's
 * Tasks step (step 2) "PULL IN A POOL" card: pulling a pool unions its
 * tasks into the selection with "from <pool>" provenance; untoggling
 * removes only the non-manual tasks; a hand-picked task survives an
 * untoggle; and "Save these N as a new pool…" mints a new pool that
 * then appears as a new pull-chip.
 *
 * Uses the one-off ("Start a one-off board") entry point — the pull-card
 * behavior is identical for one-off and recurring boards.
 */

test.describe('Wizard Tasks step — PULL IN A POOL (P3)', () => {
  test('pulling a pool unions its tasks with provenance; untoggling removes only non-manual tasks; saving as a new pool mints a pullable chip', async ({
    page,
  }) => {
    // 8 tasks so pulling the pool exactly satisfies a 3×3-FREE board
    // (fillableCellCount = 8) — makes the "Selected: 8 / 8" satisfied
    // state visible in the same flow.
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
    await page.getByLabel(/board name/i).fill('Pool Pull Test Board');
    await page.getByRole('button', { name: '3×3', exact: true }).click();
    await page
      .getByRole('group', { name: 'Timeframe' })
      .getByRole('button', { name: 'Daily', exact: true })
      .click();
    await page.getByRole('button', { name: /^Next/ }).click();

    // Step 2 mounted — the pull-card renders the seeded pool as a chip.
    // Web inline-editing port PR-1 (pool-first restructure): the pool is
    // no longer a flat selectable library list — selected tasks live in
    // the separate `PoolList` ("ON YOUR BOARD") section, and the header's
    // "Selected: N / M" text became a `TasksPoolHeader` count badge
    // exposed via `aria-label` for stable e2e targeting.
    const poolChip = page.getByRole('button', { name: 'Morning Kickstart', exact: true });
    await expect(poolChip).toBeVisible();
    await expect(poolChip).toHaveAttribute('aria-pressed', 'false');
    await page.waitForTimeout(200); // let the chip's CSS transition settle before capturing
    await page.screenshot({ path: '.playwright-mcp/pool-pull-01-card-untouched.png' });

    // Pull it in: all 8 tasks join the selection, satisfying the 3×3
    // floor, and each pool task's row (now in the Pool List) shows
    // "from Morning Kickstart".
    await poolChip.click();
    await expect(poolChip).toHaveAttribute('aria-pressed', 'true');
    await expect(page.getByLabel('Selected 8 of 8 tasks')).toBeVisible();

    const firstPoolTaskRow = page.getByRole('listitem').filter({ hasText: 'Pool Task 1' });
    await expect(firstPoolTaskRow).toBeVisible();
    await expect(firstPoolTaskRow).toContainText('from Morning Kickstart');
    await page.waitForTimeout(200);
    await page.screenshot({ path: '.playwright-mcp/pool-pull-02-pulled-with-provenance.png' });

    // Manually add an unrelated (already-existing) task via the quick-add
    // row's library-poll dropdown — the pool-first restructure's real
    // "add an existing task by hand" path when the library sheet isn't
    // already open. Its Pool List row shows "added by hand".
    await page.getByLabel('New normal task title').fill('Manual Task');
    const manualMatch = page
      .getByRole('list', { name: 'Matching library tasks' })
      .getByRole('button', { name: /Manual Task/ });
    await expect(manualMatch).toBeVisible();
    await manualMatch.click();

    const manualRow = page.getByRole('listitem').filter({ hasText: 'Manual Task' });
    await expect(manualRow).toBeVisible();
    await expect(manualRow).toContainText('added by hand');
    await expect(page.getByLabel('Selected 9 of 8 tasks')).toBeVisible();
    await page.waitForTimeout(200);
    await page.screenshot({ path: '.playwright-mcp/pool-pull-03-manual-add.png' });

    // Untoggle the pool: only the 8 pool-sourced tasks drop; the manual
    // task survives (manual layer is never touched by a pool toggle).
    await poolChip.click();
    await expect(poolChip).toHaveAttribute('aria-pressed', 'false');
    await expect(firstPoolTaskRow).toHaveCount(0);
    await expect(manualRow).toBeVisible();
    await expect(manualRow).toContainText('added by hand');
    await expect(page.getByLabel('Selected 1 of 8 tasks')).toBeVisible();
    await page.waitForTimeout(200);
    await page.screenshot({ path: '.playwright-mcp/pool-pull-04-untoggled-manual-survives.png' });

    // "Save these N as a new pool…" — only the Manual Task is selected
    // right now (N=1).
    const saveAsPoolButton = page.getByRole('button', { name: /Save these 1 as a new pool/ });
    await expect(saveAsPoolButton).toBeEnabled();
    await saveAsPoolButton.click();

    const poolSheet = page.getByRole('dialog', { name: /new pool/i });
    await expect(poolSheet).toBeVisible();
    // Pre-seeded from the current selection (Manual Task).
    await expect(poolSheet.getByText('Manual Task')).toBeVisible();
    await poolSheet.getByLabel(/^name$/i).fill('Saved From Wizard');
    await page.waitForTimeout(200);
    await page.screenshot({ path: '.playwright-mcp/pool-pull-05-save-as-pool-sheet.png' });
    await poolSheet.getByRole('button', { name: 'Create pool', exact: true }).click();
    await expect(poolSheet).toBeHidden();

    // Independent of the board: saving didn't touch selectedTaskIds
    // (still just the Manual Task).
    await expect(page.getByLabel('Selected 1 of 8 tasks')).toBeVisible();

    // The new pool is immediately pullable — the live `usePools` query
    // surfaces it in the card without a reload.
    const newPoolChip = page.getByRole('button', { name: 'Saved From Wizard', exact: true });
    await expect(newPoolChip).toBeVisible();
    await newPoolChip.scrollIntoViewIfNeeded();
    await page.waitForTimeout(200);
    await page.screenshot({ path: '.playwright-mcp/pool-pull-06-new-pool-pullable.png' });
  });

  test('shows the empty-state line when the user has no pools yet', async ({ page }) => {
    await openCreateHub(page);
    await startOneOffWizard(page);
    await page.getByLabel(/board name/i).fill('No Pools Yet Board');
    await page
      .getByRole('group', { name: 'Timeframe' })
      .getByRole('button', { name: 'Daily', exact: true })
      .click();
    await page.getByRole('button', { name: /^Next/ }).click();

    await expect(page.getByText(/you don.t have any pools yet/i)).toBeVisible();
  });
});
