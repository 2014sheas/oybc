import { defineConfig, devices } from '@playwright/test';

/**
 * Playwright config for the OYBC web app.
 *
 * **Scope (Phase 6.2 UX rework + future)**: today this only exercises the
 * unauthenticated `/playground` route, which validates the harness boots
 * cleanly but does NOT cover the rework's main paths (the wizard, Profile
 * templates page). Meaningful E2E coverage of the auth-gated flows
 * requires one of:
 *   1. A dev-only auth bypass (~30 lines in AuthGate; gated on
 *      `import.meta.env.DEV`). Unblocks all auth-gated tests with no
 *      backend dependencies.
 *   2. Firebase Auth/Firestore emulator suite. Heavier but matches
 *      production code paths exactly.
 *   3. Real test credentials in `.env.test`. Fragile (shared secrets,
 *      rate limits) and not a great fit for CI.
 *
 * Tracked as a follow-up; the choice should be deliberate, not bundled
 * into the Phase 6.2 UX rework PR.
 */
export default defineConfig({
  testDir: './e2e',
  // Tests are short and read-only; short timeout catches hung selectors.
  timeout: 30_000,
  expect: { timeout: 5_000 },
  // Run tests sequentially in CI to keep traces deterministic; locally,
  // parallelize for speed.
  fullyParallel: !process.env.CI,
  forbidOnly: !!process.env.CI,
  retries: process.env.CI ? 1 : 0,
  workers: process.env.CI ? 1 : undefined,
  reporter: process.env.CI ? [['github'], ['html', { open: 'never' }]] : 'list',

  use: {
    baseURL: 'http://localhost:5173',
    trace: 'on-first-retry',
    // Vite's default port is 5173; the dev server below claims it. If
    // the user has another dev server running, the webServer config
    // throws — surfaces the conflict instead of silently using a
    // different port.
  },

  // Auto-boots `vite` for the test run. `reuseExistingServer` lets a
  // local dev server already running on 5173 satisfy the requirement
  // (faster iteration during test authoring).
  webServer: {
    command: 'pnpm dev',
    port: 5173,
    reuseExistingServer: !process.env.CI,
    timeout: 60_000,
    stdout: 'pipe',
    stderr: 'pipe',
  },

  projects: [
    {
      name: 'chromium',
      use: { ...devices['Desktop Chrome'] },
    },
  ],
});
