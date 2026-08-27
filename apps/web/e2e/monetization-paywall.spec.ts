import {
  test,
  expect,
  seedBoard,
  openCreateHub,
  startOneOffWizard,
  startRecurringWizard,
  type SeedBoard,
} from './_fixtures/bypass';
import type { Page } from '@playwright/test';

/**
 * E2E coverage for the monetization Pro gates on the Create hub
 * (docs/MONETIZATION.md). Verifies that a FREE user hitting a gated entry
 * point opens the paywall instead of proceeding, and that an ungated action
 * still flows through.
 *
 * Scope note: the actual purchase (RevenueCat Web Billing / Stripe checkout)
 * can't run in e2e — RevenueCat isn't configured under the auth bypass, so the
 * paywall's plan list shows its "unavailable" state. We assert on the paywall
 * DIALOG appearing (the gate firing), not on the plans. The bypass user is free
 * by default (no `entitlements/{uid}` doc, RevenueCat unavailable), so the
 * shared gating helpers resolve to free-tier regardless of the async
 * entitlement signals — which is exactly the state these gates protect.
 *
 * The compound/achievement task-type gate lives deeper in the wizard's Tasks
 * step; its decision logic is the same shared `isFeatureGated` covered by the
 * `@oybc/shared` unit tests, so it's verified there + manually rather than
 * driven through the full wizard here.
 */

/** The Pro paywall modal (ProPaywall renders `role="dialog" aria-label="OYBC Pro"`). */
function paywall(page: Page) {
  return page.getByRole('dialog', { name: 'OYBC Pro' });
}

/** A valid ACTIVE custom-timeframe board for the free-cap seed. */
function activeBoard(n: number): SeedBoard {
  return {
    id: `aaaaaaaa-0000-0000-0000-00000000000${n}`,
    name: `Active Board ${n}`,
    boardSize: 5,
    timeframe: 'custom',
    status: 'active',
    startDate: '2026-05-01',
    endDate: '2026-05-31',
    centerSquareType: 'free',
    isRandomized: false,
  };
}

test.describe('Monetization — Pro gates on the Create hub', () => {
  test('recurring board CTA opens the paywall for a free user', async ({ page }) => {
    await openCreateHub(page);
    await startRecurringWizard(page);

    // Gated: the paywall opens instead of the recurring wizard.
    await expect(paywall(page)).toBeVisible();
    await expect(page.getByText(/unlock everything/i)).toBeVisible();
    // Did NOT enter the recurring wizard.
    await expect(page.getByText(/new recurring board/i)).toHaveCount(0);
  });

  test('one-off board CTA opens the paywall at the free board cap', async ({ page }) => {
    // Seed exactly the free cap (5) of ACTIVE boards.
    for (let i = 1; i <= 5; i += 1) {
      await seedBoard(page, activeBoard(i));
    }
    await openCreateHub(page);
    await startOneOffWizard(page);

    // Gated: over the cap → paywall, not the wizard.
    await expect(paywall(page)).toBeVisible();
    await expect(page.getByText(/new one-off board/i)).toHaveCount(0);
  });

  test('one-off board CTA proceeds to the wizard under the free cap', async ({ page }) => {
    // No seeded boards → 0 active, under the cap.
    await openCreateHub(page);
    await startOneOffWizard(page);

    // Ungated: the one-off wizard mounts, no paywall.
    await expect(page.getByText(/new one-off board/i)).toBeVisible();
    await expect(paywall(page)).toHaveCount(0);
  });
});
