/**
 * Last-Write-Wins (LWW) conflict resolution — the core comparison used by
 * both platforms' sync layers to decide whether a local or remote copy of
 * an entity wins when both have changed since the last sync.
 *
 * Per `docs/SYNC_STRATEGY.md`:
 *  1. Higher `version` wins.
 *  2. Same version → newer `updatedAt` wins.
 *  3. Exact tie (or unparsable timestamps) → remote wins (server authority).
 *
 * This logic originally lived only in
 * `apps/web/src/firebase/conflictResolver.ts`, but it never touched
 * Firestore/Dexie types — it's pure — so it moved here verbatim
 * (workstream C4 / issue #261) to be the single source of truth. Web now
 * re-exports from this module so existing imports don't need to change.
 *
 * iOS cannot import TypeScript, so its own Swift `resolveConflict` in
 * `SyncService.swift` mirrors this logic by hand. Both implementations
 * are cross-checked against the same hand-authored vector fixture,
 * `packages/shared/tests/fixtures/lwwVectors.json`, exercised by
 * `packages/shared/tests/algorithms/lwwResolve.test.ts` (this function)
 * and `apps/ios/OYBCTests/LwwVectorTests.swift` (the Swift mirror).
 */

/**
 * A syncable entity — any record with version and updatedAt fields.
 * All OYBC entities (Board, Task, BoardTask, etc.) satisfy this interface.
 */
export interface SyncableEntity {
  id: string;
  version: number;
  updatedAt: string;
  isDeleted: boolean;
  [key: string]: unknown;
}

/**
 * Result of a conflict resolution between local and remote versions.
 *
 * @property winner - Which version won ('local' or 'remote')
 * @property data - The winning entity's data
 */
export interface ConflictResult {
  winner: 'local' | 'remote';
  data: SyncableEntity;
}

/**
 * Resolves a conflict between local and remote versions of an entity
 * using Last-Write-Wins (LWW) strategy.
 *
 * Per SYNC_STRATEGY.md:
 * 1. Higher `version` wins
 * 2. Same version → newer `updatedAt` wins
 * 3. Exact tie → remote wins (server authority)
 *
 * @param local - The local entity from Dexie
 * @param remote - The remote entity from Firestore
 * @returns ConflictResult indicating the winner and its data
 */
export function resolveConflict(
  local: SyncableEntity,
  remote: SyncableEntity,
): ConflictResult {
  // Higher version wins
  if (local.version > remote.version) {
    return { winner: 'local', data: local };
  }
  if (remote.version > local.version) {
    return { winner: 'remote', data: remote };
  }

  // Same version — newer updatedAt wins
  const localTime = new Date(local.updatedAt).getTime();
  const remoteTime = new Date(remote.updatedAt).getTime();

  if (localTime > remoteTime) {
    return { winner: 'local', data: local };
  }

  // Tie or remote is newer — remote wins (server authority)
  return { winner: 'remote', data: remote };
}
