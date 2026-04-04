// ─── Types ────────────────────────────────────────────────────────────────────

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

// ─── Resolver ─────────────────────────────────────────────────────────────────

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
