/**
 * User profile (cached from Firebase Auth)
 */
export interface User {
  // Identity
  id: string;                    // Firebase UID
  email: string;
  displayName?: string;
  photoURL?: string;

  // Timestamps
  createdAt: string;             // ISO8601
  updatedAt: string;             // ISO8601

  // Sync metadata
  lastSyncedAt?: string;         // ISO8601
  version: number;               // Optimistic locking
}
