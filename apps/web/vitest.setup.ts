/**
 * Global Vitest setup for `@oybc/web`. Installs `indexedDB` / `IDBKeyRange`
 * globals via `fake-indexeddb/auto` so Dexie (and therefore every
 * `db/operations/*` module, which import the real Dexie singleton from
 * `src/db/database.ts`) works unmodified under Node — no DB code needs to
 * be aware it's running in a test.
 */
import 'fake-indexeddb/auto';
