import { defineConfig, devices } from '@playwright/test';

/**
 * Playwright config for the OYBC web app.
 *
 * **Scope**: covers the unauthenticated `/playground` route and the
 * auth-gated flows (Boards / Create / Profile tabs, the wizard,
 * the Profile recurring-templates page) via the dev-only auth bypass
 * in `AuthContext` (gated on `import.meta.env.DEV` + a session-storage
 * flag set by `e2e/_fixtures/bypass.ts`'s shared `test`). The bypass
 * does NOT ship in production builds — Vite dead-strips `import.meta.env.DEV`
 * branches at build time.
 *
 * Two emulator-based options were considered but deferred:
 *   - Firebase Auth/Firestore emulator suite — heavier, matches prod
 *     code paths exactly. Worth revisiting once the bypass-based
 *     coverage proves insufficient.
 *   - Real test credentials in `.env.test` — fragile (shared secrets,
 *     rate limits) and not a great fit for CI. Rejected.
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
