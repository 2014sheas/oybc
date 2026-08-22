import {
  test,
  expect,
  openCreateHub,
  startOneOffWizard,
  startRecurringWizard,
} from './_fixtures/bypass';

/**
 * E2E coverage for the wizard's per-mode Setup schedule field.
 *
 * Board Creation Split (web PR C) replaced the old single "Start a new
 * board" CTA + mid-wizard "Repeats" segmented (Once/Daily/Weekly/Monthly
 * /Yearly, P4) with two mode-locked entry points: mode is fixed at the
 * Create-hub CTA tap, never toggled inside the wizard. The load-bearing
 * invariant survives — recurring boards can't use the CUSTOM timeframe —
 * so these two tests now assert it per-entry-point instead of via an
 * in-wizard toggle.
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

test.describe('Board Creation Split — per-mode Setup schedule field', () => {
  test('one-off wizard offers the full Timeframe segmented, including Custom', async ({ page }) => {
    await openCreateHub(page);
    await startOneOffWizard(page);
    await expect(page.getByLabel(/board name/i)).toBeVisible();

    await expect(
      page.getByRole('group', { name: 'Timeframe' }).getByRole('button', { name: 'Custom', exact: true }),
    ).toBeVisible();
    // No "Repeats every" cadence field in the one-off flow.
    await expect(page.getByRole('group', { name: 'Repeats every' })).toHaveCount(0);
  });

  test('recurring wizard offers "Repeats every" (Day/Week/Month/Year) and omits the Timeframe/Custom segmented entirely', async ({ page }) => {
    await openCreateHub(page);
    await startRecurringWizard(page);
    await expect(page.getByLabel(/board name/i)).toBeVisible();

    const repeatsGroup = page.getByRole('group', { name: 'Repeats every' });
    await expect(repeatsGroup).toBeVisible();
    await expect(repeatsGroup.getByRole('button', { name: 'Day', exact: true })).toBeVisible();
    await expect(repeatsGroup.getByRole('button', { name: 'Week', exact: true })).toBeVisible();
    await expect(repeatsGroup.getByRole('button', { name: 'Month', exact: true })).toBeVisible();
    await expect(repeatsGroup.getByRole('button', { name: 'Year', exact: true })).toBeVisible();

    // The cadence IS the window now — the whole Timeframe segmented
    // (including Custom) is hidden entirely, and there's no Custom
    // option anywhere in the recurring flow.
    await expect(page.getByRole('group', { name: 'Timeframe' })).toHaveCount(0);
    await expect(page.getByRole('button', { name: 'Custom', exact: true })).toHaveCount(0);
  });
});
