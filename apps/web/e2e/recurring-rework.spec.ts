import {
  test,
  expect,
  openCreateHub,
} from './_fixtures/bypass';

/**
 * E2E coverage for the Phase 6.2 UX rework.
 *
 * Covers the consolidation work — the wizard now hosts both one-off
 * and recurring board creation as a Setup-step toggle.
 *
 * (This file originally also covered the standalone Profile "Recurring
 * templates" sub-page — empty state + seeded-row Edit deep-link. P7
 * (Task Pools + Recurring Boards Rework) retired that page in favor of
 * `/profile/board-settings`'s "Repeating boards" roster; see
 * `board-settings.spec.ts` for its smoke coverage.)
 *
 * Notably NOT covered here (yet):
 * - End-to-end create-and-spawn flow (requires task seeding + 3 wizard
 *   steps of clicks + assertions on a spawned board appearing). Worth
 *   adding when a test that walks the full happy path catches a real
 *   regression; until then the manual QA in PR #52's test plan
 *   covers it.
 * - Tasks-step pool-flex count suffix ("X / N exact" vs "X / N min")
 *   — needs task seeding too. Add later if the suffix copy regresses.
 */

test.describe('Phase 6.2 rework', () => {
  // P4 (Task Pools + Recurring Boards Rework) retired the separate
  // "Create a recurring board" Create-hub entry point: there's now ONE
  // "Start a new board" CTA, and recurrence is chosen via Step 1's
  // "Repeats" segmented (Once/Daily/Weekly/Monthly/Yearly). The
  // load-bearing invariant survives — recurring boards can't use the
  // CUSTOM timeframe — so these two tests now assert it via that
  // segmented instead of a separate entry point.

  test('one-off board wizard offers the Custom timeframe', async ({ page }) => {
    await openCreateHub(page);
    await page.getByRole('button', { name: /start a new board/i }).click();
    await expect(page.getByLabel(/board name/i)).toBeVisible();

    // "Once" (the default) shows the full Timeframe segmented, including
    // Custom.
    await expect(
      page.getByRole('group', { name: 'Timeframe' }).getByRole('button', { name: 'Custom', exact: true }),
    ).toBeVisible();
  });

  test('choosing a Repeats cadence omits the Custom timeframe', async ({ page }) => {
    await openCreateHub(page);
    await page.getByRole('button', { name: /start a new board/i }).click();
    await expect(page.getByLabel(/board name/i)).toBeVisible();

    // Pick a cadence from the "Repeats" segmented (scoped so this doesn't
    // collide with the separate Timeframe segmented's own "Weekly" button,
    // both visible while repeats === null).
    await page.getByRole('group', { name: 'Repeats' }).getByRole('button', { name: 'Weekly', exact: true }).click();

    // The cadence IS the window now — the whole Timeframe segmented
    // (including Custom) is hidden entirely.
    await expect(page.getByRole('group', { name: 'Timeframe' })).toHaveCount(0);
    await expect(page.getByRole('button', { name: 'Custom', exact: true })).toHaveCount(0);
  });
});
