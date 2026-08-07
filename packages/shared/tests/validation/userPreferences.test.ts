import {
  UserPreferencesSchema,
  UserSchema,
} from '../../src/validation/schemas';
import {
  DEFAULT_USER_PREFERENCES,
  mergeUserPreferences,
} from '../../src/types/user';
import { CenterSquareType, Timeframe } from '../../src/constants/enums';

describe('UserPreferencesSchema', () => {
  it('accepts the default preferences object', () => {
    expect(() => UserPreferencesSchema.parse(DEFAULT_USER_PREFERENCES)).not.toThrow();
  });

  it.each([
    ['weekStartDay', { weekStartDay: 'tuesday' }],
    ['defaultBoardSize (6)', { defaultBoardSize: 6 }],
    ['defaultCenterType (CHOSEN)', { defaultCenterType: CenterSquareType.CHOSEN }],
    ['defaultTimeframe (nonsense)', { defaultTimeframe: 'fortnightly' }],
    ['defaultRandomize (string)', { defaultRandomize: 'yes' }],
    ['theme (invalid)', { theme: 'sepia' }],
  ])('rejects invalid %s', (_label, override) => {
    expect(() =>
      UserPreferencesSchema.parse({ ...DEFAULT_USER_PREFERENCES, ...override })
    ).toThrow();
  });

  it('requires every legacy field to be present', () => {
    // Iteratively omit each LEGACY key from a valid object; every omission
    // must reject. The 4 recurring*Enabled fields are intentionally optional
    // for forward-compat with peers that pre-date Phase 6.1 — they're tested
    // separately below.
    const optionalKeys = new Set([
      'recurringDailyEnabled',
      'recurringWeeklyEnabled',
      'recurringMonthlyEnabled',
      'recurringYearlyEnabled',
      // Board Preferences (Riso 5a) — optional for forward-compat too.
      'celebrationIntensity',
      'haptics',
      'expiringReminders',
      // Notifications (Phase 7) — optional for forward-compat too.
      'notificationsEnabled',
      'recurringWindowReminders',
      'dailyPlayReminderEnabled',
      'dailyPlayReminderTime',
    ]);
    const keys = (Object.keys(DEFAULT_USER_PREFERENCES) as (keyof typeof DEFAULT_USER_PREFERENCES)[])
      .filter((k) => !optionalKeys.has(k));
    for (const key of keys) {
      const partial = { ...DEFAULT_USER_PREFERENCES };
      delete (partial as Record<string, unknown>)[key];
      expect(() => UserPreferencesSchema.parse(partial)).toThrow();
    }
  });

  // The 4 recurring*Enabled fields are .optional() in the Zod schema so a
  // peer running an older client (whose user-prefs doc pre-dates Phase 6.1)
  // doesn't get its sync push rejected by safeParse on the pull path.
  // mergeUserPreferences fills in the post-6.1d `true` defaults afterward
  // (auto-upgrading missing fields so the feature becomes discoverable).
  it.each([
    'recurringDailyEnabled',
    'recurringWeeklyEnabled',
    'recurringMonthlyEnabled',
    'recurringYearlyEnabled',
    'celebrationIntensity',
    'haptics',
    'expiringReminders',
    'notificationsEnabled',
    'recurringWindowReminders',
    'dailyPlayReminderEnabled',
    'dailyPlayReminderTime',
  ] as const)('treats %s as optional (forward-compat for older peers)', (key) => {
    const partial = { ...DEFAULT_USER_PREFERENCES };
    delete (partial as Record<string, unknown>)[key];
    expect(() => UserPreferencesSchema.parse(partial)).not.toThrow();
  });

  it.each([
    ['recurringDailyEnabled (string)', { recurringDailyEnabled: 'yes' }],
    ['recurringWeeklyEnabled (number)', { recurringWeeklyEnabled: 1 }],
    ['recurringMonthlyEnabled (null)', { recurringMonthlyEnabled: null }],
    ['recurringYearlyEnabled (object)', { recurringYearlyEnabled: {} }],
    ['celebrationIntensity (out of range)', { celebrationIntensity: 99 }],
    ['celebrationIntensity (non-integer)', { celebrationIntensity: 5.5 }],
    ['haptics (string)', { haptics: 'on' }],
    ['expiringReminders (number)', { expiringReminders: 0 }],
    ['notificationsEnabled (string)', { notificationsEnabled: 'yes' }],
    ['recurringWindowReminders (number)', { recurringWindowReminders: 1 }],
    ['dailyPlayReminderEnabled (null)', { dailyPlayReminderEnabled: null }],
    ['dailyPlayReminderTime (non-HH:mm)', { dailyPlayReminderTime: '8pm' }],
    ['dailyPlayReminderTime (out of range)', { dailyPlayReminderTime: '24:00' }],
    ['dailyPlayReminderTime (number)', { dailyPlayReminderTime: 2000 }],
  ])('still rejects invalid type for %s when present', (_label, override) => {
    expect(() =>
      UserPreferencesSchema.parse({ ...DEFAULT_USER_PREFERENCES, ...override })
    ).toThrow();
  });
});

describe('UserSchema preferences integration', () => {
  const baseUser = {
    id: 'uid-123',
    email: 'user@example.com',
    createdAt: '2026-01-01T00:00:00.000Z',
    updatedAt: '2026-01-01T00:00:00.000Z',
    version: 1,
  };

  it('accepts a user without preferences (backward compatibility)', () => {
    expect(() => UserSchema.parse(baseUser)).not.toThrow();
  });

  it('accepts a user with valid preferences', () => {
    expect(() =>
      UserSchema.parse({ ...baseUser, preferences: DEFAULT_USER_PREFERENCES })
    ).not.toThrow();
  });

  it('rejects a user with malformed preferences', () => {
    expect(() =>
      UserSchema.parse({ ...baseUser, preferences: { weekStartDay: 'friday' } })
    ).toThrow();
  });
});

describe('mergeUserPreferences', () => {
  it('returns defaults for null / undefined / empty', () => {
    expect(mergeUserPreferences(undefined)).toEqual(DEFAULT_USER_PREFERENCES);
    expect(mergeUserPreferences(null)).toEqual(DEFAULT_USER_PREFERENCES);
    expect(mergeUserPreferences({})).toEqual(DEFAULT_USER_PREFERENCES);
  });

  it('fills only missing fields from defaults', () => {
    expect(mergeUserPreferences({ weekStartDay: 'sunday' })).toEqual({
      ...DEFAULT_USER_PREFERENCES,
      weekStartDay: 'sunday',
    });
  });

  it('clamps celebrationIntensity into the 1–10 range', () => {
    expect(mergeUserPreferences({ celebrationIntensity: 99 }).celebrationIntensity).toBe(10);
    expect(mergeUserPreferences({ celebrationIntensity: -5 }).celebrationIntensity).toBe(1);
    expect(mergeUserPreferences({ celebrationIntensity: 4 }).celebrationIntensity).toBe(4);
  });

  it('preserves every field when provided', () => {
    const full = {
      weekStartDay: 'sunday' as const,
      defaultBoardSize: 4 as const,
      defaultCenterType: CenterSquareType.NONE as const,
      defaultTimeframe: Timeframe.WEEKLY,
      defaultRandomize: false,
      theme: 'dark' as const,
      recurringDailyEnabled: true,
      recurringWeeklyEnabled: true,
      recurringMonthlyEnabled: true,
      recurringYearlyEnabled: true,
      celebrationIntensity: 7,
      haptics: true,
      expiringReminders: true,
      notificationsEnabled: true,
      recurringWindowReminders: false,
      dailyPlayReminderEnabled: true,
      dailyPlayReminderTime: '07:30',
    };
    expect(mergeUserPreferences(full)).toEqual(full);
  });

  // Forward-compat: a payload from a peer that pre-dates Phase 6.1 (or a
  // user whose stored prefs are missing these fields entirely) auto-upgrades
  // to the new defaults — `true` for all 4 — so core boards become
  // discoverable on first open. Users who explicitly toggled them off keep
  // their explicit choice (covered by the next test).
  it('fills missing recurring*Enabled with the new true defaults', () => {
    const legacy = {
      weekStartDay: 'monday' as const,
      defaultBoardSize: 5 as const,
      defaultCenterType: CenterSquareType.FREE as const,
      defaultTimeframe: Timeframe.CUSTOM,
      defaultRandomize: true,
      theme: 'system' as const,
    };
    const merged = mergeUserPreferences(legacy);
    expect(merged.recurringDailyEnabled).toBe(true);
    expect(merged.recurringWeeklyEnabled).toBe(true);
    expect(merged.recurringMonthlyEnabled).toBe(true);
    expect(merged.recurringYearlyEnabled).toBe(true);
  });

  // Timeframe.INDEFINITE is a valid `defaultTimeframe` value even though
  // neither platform's preferences UI currently exposes it as a picker
  // option — it can still arrive from a peer / future UI. iOS's
  // `DefaultTimeframe` enum mirror must accept it too (previously it lacked
  // an `.indefinite` case and silently degraded to `.custom` on decode).
  it('accepts and preserves defaultTimeframe INDEFINITE', () => {
    const merged = mergeUserPreferences({ defaultTimeframe: Timeframe.INDEFINITE });
    expect(merged.defaultTimeframe).toBe(Timeframe.INDEFINITE);
  });

  it('preserves recurring*Enabled false values (explicit user opt-out wins over default)', () => {
    const merged = mergeUserPreferences({
      recurringDailyEnabled: false,
      recurringMonthlyEnabled: false,
    });
    expect(merged.recurringDailyEnabled).toBe(false);
    expect(merged.recurringWeeklyEnabled).toBe(true);  // missing → default true
    expect(merged.recurringMonthlyEnabled).toBe(false);
    expect(merged.recurringYearlyEnabled).toBe(true);  // missing → default true
  });

  it('rejects non-boolean recurring*Enabled values and falls back to the new true defaults', () => {
    const merged = mergeUserPreferences({
      recurringDailyEnabled: 'true' as unknown as boolean,
      recurringWeeklyEnabled: 1 as unknown as boolean,
    });
    expect(merged.recurringDailyEnabled).toBe(true);
    expect(merged.recurringWeeklyEnabled).toBe(true);
  });

  // Notifications (Phase 7) — same forward-compat + quarantine guarantees.
  it('fills missing notification fields with their defaults', () => {
    const merged = mergeUserPreferences({ weekStartDay: 'sunday' });
    expect(merged.notificationsEnabled).toBe(false);
    expect(merged.recurringWindowReminders).toBe(true);
    expect(merged.dailyPlayReminderEnabled).toBe(false);
    expect(merged.dailyPlayReminderTime).toBe('20:00');
  });

  // Compound forward-compat: a complete old-client blob missing ALL four
  // Phase-7 fields must pass safeParse AND merge to the correct defaults — this
  // guards the schema-optional + merge-return-literal interaction together
  // (a per-field test wouldn't catch a field dropped from merge's return).
  it('old-client prefs missing all notification fields pass safeParse and merge cleanly', () => {
    const oldPrefs = { ...DEFAULT_USER_PREFERENCES } as Record<string, unknown>;
    for (const k of [
      'notificationsEnabled',
      'recurringWindowReminders',
      'dailyPlayReminderEnabled',
      'dailyPlayReminderTime',
    ]) {
      delete oldPrefs[k];
    }
    expect(() => UserPreferencesSchema.parse(oldPrefs)).not.toThrow();
    const merged = mergeUserPreferences(oldPrefs as Partial<typeof DEFAULT_USER_PREFERENCES>);
    expect(merged.notificationsEnabled).toBe(false);
    expect(merged.recurringWindowReminders).toBe(true);
    expect(merged.dailyPlayReminderEnabled).toBe(false);
    expect(merged.dailyPlayReminderTime).toBe('20:00');
  });

  it('preserves valid notification values when provided', () => {
    const merged = mergeUserPreferences({
      notificationsEnabled: true,
      recurringWindowReminders: false,
      dailyPlayReminderEnabled: true,
      dailyPlayReminderTime: '06:05',
    });
    expect(merged.notificationsEnabled).toBe(true);
    expect(merged.recurringWindowReminders).toBe(false);
    expect(merged.dailyPlayReminderEnabled).toBe(true);
    expect(merged.dailyPlayReminderTime).toBe('06:05');
  });

  it.each([
    ['8pm', '20:00'],          // not HH:mm
    ['24:00', '20:00'],        // hour out of range
    ['12:60', '20:00'],        // minute out of range
    ['7:30', '20:00'],         // missing leading zero
    [' 9:00', '20:00'],        // leading space (regex is anchored)
    [2000 as unknown as string, '20:00'], // wrong type
  ])('rejects malformed dailyPlayReminderTime %p and falls back to default', (bad, expected) => {
    expect(
      mergeUserPreferences({ dailyPlayReminderTime: bad }).dailyPlayReminderTime
    ).toBe(expected);
  });

  it('preserves falsy-but-valid values (empty string, false) instead of falling back to defaults', () => {
    const partial = { defaultRandomize: false };
    const merged = mergeUserPreferences(partial);
    expect(merged.defaultRandomize).toBe(false);
  });

  // mergeUserPreferences is the quarantine layer between Firestore payloads
  // and local state — a misbehaving peer or a stale cached record shouldn't
  // be able to smuggle an out-of-range value past it.
  it('rejects invalid runtime values and falls back to defaults per-field', () => {
    const garbage = {
      weekStartDay: 'friday',
      defaultBoardSize: 6,
      defaultCenterType: CenterSquareType.CHOSEN,
      defaultTimeframe: 'fortnightly',
      defaultRandomize: 'yes',
      theme: 'sepia',
    } as unknown as Parameters<typeof mergeUserPreferences>[0];
    expect(mergeUserPreferences(garbage)).toEqual(DEFAULT_USER_PREFERENCES);
  });

  it('keeps valid fields and only substitutes the invalid ones', () => {
    const mixed = {
      weekStartDay: 'sunday' as const,       // valid
      defaultBoardSize: 6 as unknown as 3,   // invalid (out of range)
      theme: 'dark' as const,                // valid
      defaultRandomize: 'nope' as unknown as boolean, // invalid
    };
    const merged = mergeUserPreferences(mixed);
    expect(merged.weekStartDay).toBe('sunday');
    expect(merged.theme).toBe('dark');
    expect(merged.defaultBoardSize).toBe(DEFAULT_USER_PREFERENCES.defaultBoardSize);
    expect(merged.defaultRandomize).toBe(DEFAULT_USER_PREFERENCES.defaultRandomize);
  });

  it('returns a fresh object (not the defaults reference)', () => {
    const merged = mergeUserPreferences(undefined);
    expect(merged).not.toBe(DEFAULT_USER_PREFERENCES);
  });
});
