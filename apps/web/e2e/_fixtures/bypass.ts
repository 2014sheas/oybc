import { test as base } from '@playwright/test';

/**
 * Playwright fixture that auto-engages the dev-only auth bypass.
 *
 * The bypass mechanism lives in `src/firebase/AuthContext.tsx` —
 * see its `isTestBypassActive` doc-comment for the full gating story.
 * Production builds dead-strip the bypass branch entirely.
 *
 * **No DB wipe between tests.** The bypass user is idempotent
 * (`AuthContext.ensureBypassUserRow` uses `put`), and the test cases
 * here are read-only against the bypass user's slice. If a future
 * test mutates state in a way that affects subsequent tests,
 * introduce per-test cleanup either by wiping specific tables via
 * Dexie's API (NOT `indexedDB.deleteDatabase`, which closes the
 * live Dexie connection mid-flight) or by parameterizing the bypass
 * user id via a per-test query param.
 *
 * Usage:
 *
 * ```ts
 * import { test, expect } from './_fixtures/bypass';
 *
 * test('boards page renders empty state', async ({ page }) => {
 *   await page.goto('/');
 *   await expect(page.getByRole('heading', { name: 'Boards' })).toBeVisible();
 * });
 * ```
 *
 * The fixture sets `__oybc_test_bypass=1` via the URL on the first
 * navigation so AuthContext promotes it to sessionStorage; subsequent
 * in-app navigation keeps the bypass live until the browser context
 * tears down (sessionStorage is per-tab).
 */
export const test = base.extend<{}>({
  page: async ({ page }, use) => {
    // Surface AuthContext's `[auth-bypass]` error logs in the test
    // runner's stdout when the bootstrap fails. Other console output
    // is intentionally suppressed to keep the test runner output
    // focused.
    page.on('console', (msg) => {
      if (msg.type() === 'error' && msg.text().includes('[auth-bypass]')) {
        // eslint-disable-next-line no-console
        console.log(`[browser] ${msg.text()}`);
      }
    });

    // Visit the root with the bypass query param. AuthContext promotes
    // the param to sessionStorage immediately, so any in-app
    // navigation the test does keeps the bypass live.
    await page.goto('/?__oybc_test_bypass=1');
    await use(page);
  },
});

export { expect } from '@playwright/test';
