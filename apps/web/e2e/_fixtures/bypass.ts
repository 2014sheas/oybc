import { test as base, type Page } from '@playwright/test';

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

/** The bypass user's id — exported so tests that seed user-scoped
 *  rows (templates, boards, tasks) can reference it without
 *  duplicating the literal. Mirror of `BYPASS_USER_ID` in
 *  `src/firebase/AuthContext.tsx`. */
export const BYPASS_USER_ID = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb';

/** Shape of a `RecurringBoardTemplate` row, kept loose (Record-typed)
 *  so this fixture file doesn't import the shared Zod-generated type
 *  (which would pull `@oybc/shared` into the e2e module graph and
 *  trigger a chain of bundler concerns). Tests seed plain objects
 *  that match the schema — the seed function below validates the
 *  required keys. */
export interface SeedTemplate {
  id: string;
  name: string;
  timeframe: 'daily' | 'weekly' | 'monthly' | 'yearly';
  boardSize: 3 | 4 | 5;
  centerSquareType: 'free' | 'custom_free' | 'none';
  centerSquareCustomName?: string;
  isRandomized: boolean;
  seedTaskIds: string[];
  isActive: boolean;
  // Optional sync metadata; sensible defaults filled in below.
  lastSpawnedWindowKey?: string | null;
  createdAt?: string;
  updatedAt?: string;
  version?: number;
  isDeleted?: boolean;
}

/**
 * Inserts a `RecurringBoardTemplate` row directly into Dexie via the
 * raw IndexedDB API. Bypasses the create-input Zod schema (so
 * malformed seed data won't be caught — assert your shape at the
 * call site), but matches the at-rest table layout.
 *
 * Why raw IDB rather than Dexie's API: Dexie's module-level singleton
 * lives in the app bundle, not the test harness; importing it here
 * would re-instantiate the connection in a fresh Dexie context that
 * conflicts with the page's own connection. Raw IDB sidesteps that.
 *
 * The template's `userId` is fixed to `BYPASS_USER_ID` so it appears
 * in the bypass user's slice (matches what `useRecurringBoardTemplates`
 * filters for).
 */
export async function seedTemplate(page: Page, template: SeedTemplate): Promise<void> {
  const now = new Date().toISOString();
  const row = {
    userId: BYPASS_USER_ID,
    centerSquareCustomName: undefined,
    lastSpawnedWindowKey: null,
    createdAt: now,
    updatedAt: now,
    version: 1,
    isDeleted: false,
    ...template,
  };
  await page.evaluate(async (rowToInsert) => {
    return new Promise<void>((resolve, reject) => {
      // Open the existing `oybc` Dexie database at its current version.
      // We pass no version arg so IDB just opens whatever's there
      // (Dexie has already migrated to v6+ as part of the page mount).
      const openReq = indexedDB.open('oybc');
      openReq.onerror = () => reject(openReq.error);
      openReq.onsuccess = () => {
        const db = openReq.result;
        const tx = db.transaction(['recurringBoardTemplates'], 'readwrite');
        tx.oncomplete = () => {
          db.close();
          resolve();
        };
        tx.onerror = () => reject(tx.error);
        tx.objectStore('recurringBoardTemplates').put(rowToInsert);
      };
    });
  }, row);
}

/**
 * Clears all rows from the `recurringBoardTemplates` table without
 * tearing down the Dexie connection. Use in tests that need a known
 * empty starting state for the templates list.
 */
export async function clearTemplates(page: Page): Promise<void> {
  await page.evaluate(async () => {
    return new Promise<void>((resolve, reject) => {
      const openReq = indexedDB.open('oybc');
      openReq.onerror = () => reject(openReq.error);
      openReq.onsuccess = () => {
        const db = openReq.result;
        const tx = db.transaction(['recurringBoardTemplates'], 'readwrite');
        tx.oncomplete = () => {
          db.close();
          resolve();
        };
        tx.onerror = () => reject(tx.error);
        tx.objectStore('recurringBoardTemplates').clear();
      };
    });
  });
}

export { expect } from '@playwright/test';
