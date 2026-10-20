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
 *   blanket default (FREE or NONE). CHOSEN requires per-board context and
 *   doesn't make sense as a global default.
 * - `theme` is `'system'` by default so the app follows the OS appearance
 *   unless the user explicitly overrides it.
 */
export type DefaultCenterSquareType = CenterSquareType.FREE | CenterSquareType.NONE;

export type ThemePreference = 'light' | 'dark' | 'system';

/**
 * One tutorial lesson's saved state. A lesson that is not started has NO
 * entry (absence = `notStarted`), so the map only carries lessons the user
 * has touched.
 */
export type TutorialLessonProgress =
  | { status: 'inProgress'; step: number }
  | { status: 'done' }
  // A status this client does not know (written by a newer client): kept
  // opaque and round-tripped untouched.
  | { status: string; [key: string]: unknown };

/**
 * Getting Started tutorial progress (iOS tutorial board). Synced inside the
 * user's preferences so it follows the account. Web has no tutorial board and
 * only round-trips the value (`mergeUserPreferences` keeps it verbatim).
 * Lesson ids are open strings so a newer client's lesson survives a pass
 * through an older one.
 */
export interface TutorialProgress {
  lessons: Record<string, TutorialLessonProgress>;
  /** Whether the Boards-tab card was dismissed (allowed once the middle row is done). */
  cardDismissed: boolean;
}

export const DEFAULT_TUTORIAL_PROGRESS: TutorialProgress = {
  lessons: {},
  cardDismissed: false,
};

/** Rank of a lesson entry for the union: done > inProgress (by step) > unrecognised. */
function lessonRank(entry: TutorialLessonProgress): number {
  if (entry.status === 'done') return 1_000_000;
  if (entry.status === 'inProgress') return 1_000 + ((entry as { step: number }).step ?? 0);
  return 1;
}

/**
 * Union of the local and an incoming tutorial progress, applied on a user-doc
 * pull so whole-document last-write-wins can never regress a finished lesson:
 * per lesson `done` beats `inProgress`, a higher step beats a lower one, an
 * unrecognised entry loses to either (ties keep the incoming entry), and
 * `cardDismissed` is an OR. Swift twin: `TutorialProgress.union(local:incoming:)`.
 */
export function unionTutorialProgress(
  local: TutorialProgress | undefined,
  incoming: TutorialProgress | undefined
): TutorialProgress {
  const a = mergeTutorialProgress(local);
  const b = mergeTutorialProgress(incoming);
  const lessons: Record<string, TutorialLessonProgress> = { ...a.lessons };
  for (const [id, entry] of Object.entries(b.lessons)) {
    const existing = lessons[id];
    if (!existing || lessonRank(entry) >= lessonRank(existing)) lessons[id] = entry;
  }
  return { lessons, cardDismissed: a.cardDismissed || b.cardDismissed };
}

/**
 * Forward-compatible decode of a (possibly untrusted) tutorial progress value.
 * Malformed lesson entries are dropped; a malformed container yields the default.
 */
export function mergeTutorialProgress(raw: unknown): TutorialProgress {
  if (typeof raw !== 'object' || raw === null) {
    return { lessons: {}, cardDismissed: false };
  }
  const candidate = raw as { lessons?: unknown; cardDismissed?: unknown };
  const lessons: Record<string, TutorialLessonProgress> = {};
  if (typeof candidate.lessons === 'object' && candidate.lessons !== null) {
    for (const [id, value] of Object.entries(candidate.lessons as Record<string, unknown>)) {
      if (typeof value !== 'object' || value === null) continue;
      const entry = value as { status?: unknown; step?: unknown };
      if (entry.status === 'done') {
        lessons[id] = { status: 'done' };
      } else if (entry.status === 'inProgress') {
        if (typeof entry.step === 'number' && Number.isInteger(entry.step) && entry.step >= 0) {
          lessons[id] = { status: 'inProgress', step: entry.step };
        }
      } else if (typeof entry.status === 'string') {
        // Unknown status from a newer client: keep it opaque (a copy).
        lessons[id] = { ...(value as Record<string, unknown>), status: entry.status };
      }
    }
  }
  return {
    lessons,
    cardDismissed: typeof candidate.cardDismissed === 'boolean' ? candidate.cardDismissed : false,
  };
}

export interface UserPreferences {
  weekStartDay: WeekStartDay;
  defaultBoardSize: BoardSize;
  defaultCenterType: DefaultCenterSquareType;
  defaultTimeframe: Timeframe;
  defaultRandomize: boolean;
  theme: ThemePreference;
  // Recurring boards (Phase 6.1) — when enabled, the Boards and Create tabs
  // surface a prominent "core boards" section inviting the user to create a
  // board for the current window. Default `true` so the feature is
  // discoverable on a fresh account (opt-out semantics — see
  // DEFAULT_USER_PREFERENCES below). Users who explicitly toggled them off
  // keep their explicit choice via the forward-compat decoder in
  // `mergeUserPreferences`.
  recurringDailyEnabled: boolean;
  recurringWeeklyEnabled: boolean;
  recurringMonthlyEnabled: boolean;
  recurringYearlyEnabled: boolean;

  // Riso Phase 5a — Board Preferences sub-page. `celebrationIntensity` and
  // `haptics` (the other two 5a fields) were removed as never-meant-to-be-
  // user-configurable controls (same pattern as the earlier
  // `autoArchiveCompleted` removal) — see docs/SYNC_STRATEGY.md
  // §User Preferences Sync.
  /** Nudge the day before a board expires. */
  expiringReminders: boolean;

  // Notifications (Phase 7 — iOS local reminders). iOS-only at the feature
  // level: iOS schedules local OS-delivered notifications from these prefs;
  // web round-trips them via sync (forward-compat decode) but does not yet
  // act on them. Keep in lock-step with the iOS `UserPreferences` fields.
  /**
   * Master notifications opt-in. Default `false` — flipping it on is what
   * drives the in-context permission priming on iOS. The OS permission is the
   * real capability gate; this is the user's stated intent.
   */
  notificationsEnabled: boolean;
  /** Notify when a new recurring window opens and no core board exists yet. Default true. */
  recurringWindowReminders: boolean;
  /** Whether the daily play reminder fires. Default `false` (opt-in). */
  dailyPlayReminderEnabled: boolean;
  /** Daily play reminder time of day, 24h "HH:mm" (local). Default "20:00". */
  dailyPlayReminderTime: string;

  /**
   * Getting Started tutorial progress (iOS tutorial board). Synced with the
   * account; web only round-trips it.
   */
  tutorialProgress: TutorialProgress;
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
  expiringReminders: true,
  notificationsEnabled: false,
  recurringWindowReminders: true,
  dailyPlayReminderEnabled: false,
  dailyPlayReminderTime: '20:00',
  // A getter so every spread of the defaults gets its OWN nested object.
  get tutorialProgress(): TutorialProgress {
    return { lessons: {}, cardDismissed: false };
  },
};

/** 24-hour "HH:mm" time-of-day, 00:00–23:59. */
const HH_MM_RE = /^([01]\d|2[0-3]):[0-5]\d$/;

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
  partial:
    | (Partial<Omit<UserPreferences, 'tutorialProgress'>> & { tutorialProgress?: unknown })
    | null
    | undefined
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
    Timeframe.INDEFINITE,
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

  const expiringReminders: boolean =
    typeof partial.expiringReminders === 'boolean'
      ? partial.expiringReminders
      : DEFAULT_USER_PREFERENCES.expiringReminders;

  // Notifications (Phase 7) — forward-compat decode.
  const notificationsEnabled: boolean =
    typeof partial.notificationsEnabled === 'boolean'
      ? partial.notificationsEnabled
      : DEFAULT_USER_PREFERENCES.notificationsEnabled;

  const recurringWindowReminders: boolean =
    typeof partial.recurringWindowReminders === 'boolean'
      ? partial.recurringWindowReminders
      : DEFAULT_USER_PREFERENCES.recurringWindowReminders;

  const dailyPlayReminderEnabled: boolean =
    typeof partial.dailyPlayReminderEnabled === 'boolean'
      ? partial.dailyPlayReminderEnabled
      : DEFAULT_USER_PREFERENCES.dailyPlayReminderEnabled;

  // Reject malformed times — a bad value would otherwise produce an invalid
  // schedule on iOS. Falls back to the default rather than a partial parse.
  const dailyPlayReminderTime: string =
    typeof partial.dailyPlayReminderTime === 'string' &&
    HH_MM_RE.test(partial.dailyPlayReminderTime)
      ? partial.dailyPlayReminderTime
      : DEFAULT_USER_PREFERENCES.dailyPlayReminderTime;

  return {
    weekStartDay,
    defaultBoardSize,
    defaultCenterType,
    defaultTimeframe,
    defaultRandomize,
    theme,
    recurringDailyEnabled,
    recurringWeeklyEnabled,
    recurringMonthlyEnabled,
    recurringYearlyEnabled,
    expiringReminders,
    notificationsEnabled,
    recurringWindowReminders,
    dailyPlayReminderEnabled,
    dailyPlayReminderTime,
    tutorialProgress: mergeTutorialProgress(partial.tutorialProgress),
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
