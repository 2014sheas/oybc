import { test, expect } from '@playwright/test';

/**
 * Playground smoke test — a sanity check that the dev server + Playwright
 * harness boot cleanly on the unauthenticated `/playground` route. The
 * auth-gated routes are covered by the other specs in this folder via the
 * `_fixtures/bypass` test-auth fixture.
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
