import { test, expect } from './_fixtures/bypass';

/**
 * Smoke coverage for `/profile/board-settings` (Task Pools + Recurring
 * Boards Rework, P7, docs/POOLS_RECURRING.md §Surfaces item 9). This page
 * replaced BOTH retired Profile sub-pages — "Recurring templates"
 * (`/profile/recurring-templates`) and "Default pools"
 * (`/profile/default-pools[/:timeframe]`) — which is why
 * `recurring-ux.spec.ts` / `recurring-rework.spec.ts` had those routes'
 * tests removed rather than updated in place.
 *
 * Kept deliberately minimal: just confirm the page renders its two core
 * sections (Core-board defaults rows + the Repeating boards roster) rather
 * than timing out on a deleted route. Deeper roster-editing behavior is
 * covered by unit tests (`components/boardSettings/__tests__/`).
 */
test.describe('Board settings page', () => {
  test('renders the Board settings heading, core-defaults rows, and repeating-boards section', async ({
    page,
  }) => {
    await page.goto('/profile/board-settings?__oybc_test_bypass=1');

    await expect(page.getByRole('heading', { name: 'Board settings' })).toBeVisible();

    // Core-board defaults: one row per core timeframe.
    await expect(page.getByText('Core-board defaults')).toBeVisible();
    await expect(page.getByRole('button', { name: /Daily/ })).toBeVisible();
    await expect(page.getByRole('button', { name: /Weekly/ })).toBeVisible();
    await expect(page.getByRole('button', { name: /Monthly/ })).toBeVisible();
    await expect(page.getByRole('button', { name: /Yearly/ })).toBeVisible();

    // Repeating-boards roster: no templates seeded, so the empty state
    // renders (never a hang on a missing route).
    await expect(page.getByText('Repeating boards', { exact: true })).toBeVisible();
    await expect(page.getByText(/no repeating boards yet/i)).toBeVisible();
  });
});
