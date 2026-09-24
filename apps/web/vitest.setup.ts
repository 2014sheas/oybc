/**
 * Global Vitest setup for `@oybc/web`. Installs `indexedDB` / `IDBKeyRange`
 * globals via `fake-indexeddb/auto` so Dexie (and therefore every
 * `db/operations/*` module, which import the real Dexie singleton from
 * `src/db/internal.ts`) works unmodified under Node — no DB code needs to
 * be aware it's running in a test.
 */
import 'fake-indexeddb/auto';

/*
 * DAG-tolerant key conversion for `IDBKeyRange` factories.
 *
 * Root cause: for a compound index like `[status+priority+createdAt]`,
 * Dexie's virtual-index middleware serves `where('status').equals(S)` as
 * `IDBKeyRange.bound([S, -Infinity, -Infinity], [S, maxKey, maxKey])`, and it
 * reuses the SAME `[[]]` maxKey object in both tail positions.
 * fake-indexeddb's spec-literal `valueToKey` keeps a `seen` set that it never
 * pops, so the repeated (acyclic) reference is reported as a cycle and the
 * call throws a DataError. Chromium, WebKit and Gecko pop the stack and accept
 * the key, so this is a test-environment artifact, not a production bug.
 *
 * Emulate the browsers by deep-copying array arguments so every nested array
 * is a distinct object before delegating. This is a recursive array copy, not
 * `structuredClone`: the structured-clone algorithm memoizes references, so it
 * would reproduce the shared `[[]]` (and the DataError). Leaf keys (strings,
 * numbers incl. ±Infinity, Dates, binary) pass through unchanged.
 */
type KeyRangeFactory = (...args: unknown[]) => IDBKeyRange;
const cloneArrayKey = (value: unknown): unknown =>
  Array.isArray(value) ? value.map(cloneArrayKey) : value;
for (const name of ['bound', 'lowerBound', 'upperBound', 'only'] as const) {
  const original = (IDBKeyRange[name] as KeyRangeFactory).bind(IDBKeyRange);
  (IDBKeyRange as unknown as Record<string, KeyRangeFactory>)[name] = (...args) =>
    original(...args.map(cloneArrayKey));
}
