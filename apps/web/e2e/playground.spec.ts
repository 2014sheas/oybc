import { test, expect } from '@playwright/test';

/**
 * Playground smoke test — the only Playwright coverage that runs today.
 *
 * The web app's auth-gated routes (where the Phase 6.2 UX rework lives —
 * the wizard's Setup-step recurring toggle, the Profile templates page)
 * cannot be exercised without sign-in. The `/playground` route is
 * unauthenticated and serves as a sanity check that the dev server +
 * Playwright harness boot cleanly.
 *
 * See `playwright.config.ts` for the follow-up plan to enable
 * meaningful auth-gated coverage.
 */
test.describe('playground (unauthenticated route)', () => {
  test('renders without throwing', async ({ page }) => {
    const consoleErrors: string[] = [];
    page.on('pageerror', (err) => {
      consoleErrors.push(err.message);
    });

    await page.goto('/playground');

    // The playground page has tab navigation; verify the heading
    // surfaces as a smoke check that React mounted.
    await expect(page.getByRole('heading', { name: /playground/i })).toBeVisible();

    // No uncaught render errors reached the console.
    expect(consoleErrors, 'Page error reached the window').toEqual([]);
  });
});
