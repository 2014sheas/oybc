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
  // Recurring boards (Phase 6.1) — when enabled, the Boards tab surfaces a
  // banner inviting the user to create a board for the current window. Disabled
  // by default so existing users see no behavior change until they opt in.
  recurringDailyEnabled: boolean;
  recurringWeeklyEnabled: boolean;
  recurringMonthlyEnabled: boolean;
  recurringYearlyEnabled: boolean;
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
  // Phase 6.1: default to true so the core boards (daily/weekly/monthly/
  // yearly) are immediately discoverable on a fresh account. Per the
  // forward-compat decoder, users who already explicitly toggled these
  // to false on the prefs page keep their explicit choice — only users
  // whose stored prefs are missing these fields auto-upgrade to true.
  recurringDailyEnabled: true,
  recurringWeeklyEnabled: true,
  recurringMonthlyEnabled: true,
  recurringYearlyEnabled: true,
};

/**
 * Merge a partial (possibly untrusted) preferences object with defaults,
 * returning a complete `UserPreferences` value. Used when decoding records
 * that pre-date the `preferences` field or come from a misbehaving peer.
 *
 * Every field is validated against its allowed value set before being
 * accepted; any field whose value is missing, the wrong type, or out of
 * range falls back to the default. This mirrors the Swift
 * `UserPreferences.init(from:)` forward-compatible decoder so a bad
 * remote payload can't poison the local record.
 */
export function mergeUserPreferences(
  partial: Partial<UserPreferences> | null | undefined
): UserPreferences {
  if (!partial) return { ...DEFAULT_USER_PREFERENCES };

  const weekStartDay: WeekStartDay =
    partial.weekStartDay === 'monday' || partial.weekStartDay === 'sunday'
      ? partial.weekStartDay
      : DEFAULT_USER_PREFERENCES.weekStartDay;

  const defaultBoardSize: BoardSize =
    partial.defaultBoardSize === 3 ||
    partial.defaultBoardSize === 4 ||
    partial.defaultBoardSize === 5
      ? partial.defaultBoardSize
      : DEFAULT_USER_PREFERENCES.defaultBoardSize;

  const defaultCenterType: DefaultCenterSquareType =
    partial.defaultCenterType === CenterSquareType.FREE ||
    partial.defaultCenterType === CenterSquareType.NONE
      ? partial.defaultCenterType
      : DEFAULT_USER_PREFERENCES.defaultCenterType;

  const validTimeframes: Timeframe[] = [
    Timeframe.DAILY,
    Timeframe.WEEKLY,
    Timeframe.MONTHLY,
    Timeframe.YEARLY,
    Timeframe.CUSTOM,
  ];
  const defaultTimeframe: Timeframe =
    partial.defaultTimeframe !== undefined &&
    validTimeframes.includes(partial.defaultTimeframe)
      ? partial.defaultTimeframe
      : DEFAULT_USER_PREFERENCES.defaultTimeframe;

  const defaultRandomize: boolean =
    typeof partial.defaultRandomize === 'boolean'
      ? partial.defaultRandomize
      : DEFAULT_USER_PREFERENCES.defaultRandomize;

  const defaultCenterCustomName: string =
    typeof partial.defaultCenterCustomName === 'string' &&
    partial.defaultCenterCustomName.length <= 100
      ? partial.defaultCenterCustomName
      : DEFAULT_USER_PREFERENCES.defaultCenterCustomName;

  const theme: ThemePreference =
    partial.theme === 'light' ||
    partial.theme === 'dark' ||
    partial.theme === 'system'
      ? partial.theme
      : DEFAULT_USER_PREFERENCES.theme;

  const recurringDailyEnabled: boolean =
    typeof partial.recurringDailyEnabled === 'boolean'
      ? partial.recurringDailyEnabled
      : DEFAULT_USER_PREFERENCES.recurringDailyEnabled;

  const recurringWeeklyEnabled: boolean =
    typeof partial.recurringWeeklyEnabled === 'boolean'
      ? partial.recurringWeeklyEnabled
      : DEFAULT_USER_PREFERENCES.recurringWeeklyEnabled;

  const recurringMonthlyEnabled: boolean =
    typeof partial.recurringMonthlyEnabled === 'boolean'
      ? partial.recurringMonthlyEnabled
      : DEFAULT_USER_PREFERENCES.recurringMonthlyEnabled;

  const recurringYearlyEnabled: boolean =
    typeof partial.recurringYearlyEnabled === 'boolean'
      ? partial.recurringYearlyEnabled
      : DEFAULT_USER_PREFERENCES.recurringYearlyEnabled;

  return {
    weekStartDay,
    defaultBoardSize,
    defaultCenterType,
    defaultTimeframe,
    defaultRandomize,
    defaultCenterCustomName,
    theme,
    recurringDailyEnabled,
    recurringWeeklyEnabled,
    recurringMonthlyEnabled,
    recurringYearlyEnabled,
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
