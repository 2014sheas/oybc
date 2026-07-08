/**
 * Raw Dexie singleton — the local database instance and the offline-first
 * source of truth.
 *
 * ⚠️ INTERNAL to the data layer (B3, issue #284). The ONLY modules allowed
 * to import this are:
 *   - `db/**`         (operations)
 *   - `hooks/**`      (reactive read hooks)
 *   - `firebase/**`   (the sync layer reads/writes raw)
 *   - test files      (`**\/__tests__/**`, `**\/*.test.ts`)
 *
 * Every other module (components, pages) must go through an operations
 * function (`db/operations/*`) or a hook (`hooks/*`). This boundary is
 * enforced structurally: `db/database.ts` no longer exports the instance,
 * so this is the single import site, and the `no-restricted-imports` rule
 * in `eslint.config.js` (plus the boundary test in
 * `db/operations/__tests__/dbBoundary.test.ts`) fail the build if a
 * disallowed module imports it.
 */
import { AppDatabase } from './database';

/** Singleton instance */
export const db = new AppDatabase();

// Enable debug logging in development
if (import.meta.env.DEV) {
  db.on('ready', () => {
    console.log('✅ Dexie database initialized');
  });

  // Log all database operations
  db.on('populate', () => {
    console.log('📊 Database populated with initial data');
  });

  // Uncomment to log all transactions (verbose)
  // db.on('changes', (changes) => {
  //   console.log('Database changes:', changes);
  // });
}
