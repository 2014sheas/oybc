/**
 * Web wrapper around the shared LWW conflict resolver.
 *
 * The comparison logic itself lives in `@oybc/shared`
 * (`packages/shared/src/algorithms/lwwResolve.ts`) so it's the single
 * source of truth cross-checked against iOS's hand-mirrored Swift
 * implementation via a shared vector fixture (workstream C4 / issue
 * #261 — see that file's header for the full story). Re-exported here
 * so existing imports of `./conflictResolver` elsewhere in this app
 * don't need to change.
 */
export { resolveConflict, type SyncableEntity, type ConflictResult } from '@oybc/shared';
