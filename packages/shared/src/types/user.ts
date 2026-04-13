import type { WeekStartDay } from '../algorithms/calendarBoundaries';
import type { BoardSize } from '../constants';
import { CenterSquareType, Timeframe } from '../constants/enums';

/**
 * Synced, per-user preferences that ride along with the `User` record.
 *
 * These are UI/board-creation defaults that belong to the user (not the
 * device), so they live inside the `users` Firestore document and replicate
 * under standard last-write-wins conflict resolution.
 *
 * - `defaultCenterType` is restricted to the values a user can pick as a
 *   blanket default (FREE or NONE). CHOSEN / CUSTOM_FREE require per-board
 *   context and don't make sense as a global default — CUSTOM_FREE's custom
 *   text is captured by `defaultCenterCustomName` below.
 * - `theme` is `'system'` by default so the app follows the OS appearance
 *   unless the user explicitly overrides it.
 */
export type DefaultCenterSquareType = CenterSquareType.FREE | CenterSquareType.NONE;

export type ThemePreference = 'light' | 'dark' | 'system';

export interface UserPreferences {
  weekStartDay: WeekStartDay;
  defaultBoardSize: BoardSize;
  defaultCenterType: DefaultCenterSquareType;
  defaultTimeframe: Timeframe;
  defaultRandomize: boolean;
  defaultCenterCustomName: string;
  theme: ThemePreference;
}

/**
 * Default preferences for newly created users and missing / partial records.
 */
export const DEFAULT_USER_PREFERENCES: UserPreferences = {
  weekStartDay: 'monday',
  defaultBoardSize: 5,
  defaultCenterType: CenterSquareType.FREE,
  defaultTimeframe: Timeframe.CUSTOM,
  defaultRandomize: true,
  defaultCenterCustomName: '',
  theme: 'system',
};

/**
 * Merge a partial (possibly untrusted) preferences object with defaults,
 * returning a complete `UserPreferences` value. Used when decoding records
 * that pre-date the `preferences` field or come from a misbehaving peer.
 */
export function mergeUserPreferences(
  partial: Partial<UserPreferences> | null | undefined
): UserPreferences {
  if (!partial) return { ...DEFAULT_USER_PREFERENCES };
  return {
    weekStartDay: partial.weekStartDay ?? DEFAULT_USER_PREFERENCES.weekStartDay,
    defaultBoardSize: partial.defaultBoardSize ?? DEFAULT_USER_PREFERENCES.defaultBoardSize,
    defaultCenterType: partial.defaultCenterType ?? DEFAULT_USER_PREFERENCES.defaultCenterType,
    defaultTimeframe: partial.defaultTimeframe ?? DEFAULT_USER_PREFERENCES.defaultTimeframe,
    defaultRandomize: partial.defaultRandomize ?? DEFAULT_USER_PREFERENCES.defaultRandomize,
    defaultCenterCustomName:
      partial.defaultCenterCustomName ?? DEFAULT_USER_PREFERENCES.defaultCenterCustomName,
    theme: partial.theme ?? DEFAULT_USER_PREFERENCES.theme,
  };
}

/**
 * User profile (cached from Firebase Auth)
 */
export interface User {
  // Identity
  id: string;                    // Firebase UID
  email: string;
  displayName?: string;
  photoURL?: string;

  // Synced preferences (optional for backward-compatible decodes of pre-v5 rows)
  preferences?: UserPreferences;

  // Timestamps
  createdAt: string;             // ISO8601
  updatedAt: string;             // ISO8601

  // Sync metadata
  lastSyncedAt?: string;         // ISO8601
  version: number;               // Optimistic locking
}
