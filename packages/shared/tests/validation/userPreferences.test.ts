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
    ['defaultCenterType (CUSTOM_FREE)', { defaultCenterType: CenterSquareType.CUSTOM_FREE }],
    ['defaultTimeframe (nonsense)', { defaultTimeframe: 'fortnightly' }],
    ['defaultRandomize (string)', { defaultRandomize: 'yes' }],
    ['defaultCenterCustomName (too long)', { defaultCenterCustomName: 'x'.repeat(101) }],
    ['theme (invalid)', { theme: 'sepia' }],
  ])('rejects invalid %s', (_label, override) => {
    expect(() =>
      UserPreferencesSchema.parse({ ...DEFAULT_USER_PREFERENCES, ...override })
    ).toThrow();
  });

  it('requires every field to be present', () => {
    // Iteratively omit each key from a valid object; every omission must reject.
    const keys = Object.keys(DEFAULT_USER_PREFERENCES) as (keyof typeof DEFAULT_USER_PREFERENCES)[];
    for (const key of keys) {
      const partial = { ...DEFAULT_USER_PREFERENCES };
      delete (partial as Record<string, unknown>)[key];
      expect(() => UserPreferencesSchema.parse(partial)).toThrow();
    }
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

  it('preserves every new field when provided', () => {
    const full = {
      weekStartDay: 'sunday' as const,
      defaultBoardSize: 4 as const,
      defaultCenterType: CenterSquareType.NONE as const,
      defaultTimeframe: Timeframe.WEEKLY,
      defaultRandomize: false,
      defaultCenterCustomName: 'Wild Card',
      theme: 'dark' as const,
    };
    expect(mergeUserPreferences(full)).toEqual(full);
  });

  it('preserves falsy-but-valid values (empty string, false) instead of falling back to defaults', () => {
    const partial = { defaultRandomize: false, defaultCenterCustomName: '' };
    const merged = mergeUserPreferences(partial);
    expect(merged.defaultRandomize).toBe(false);
    expect(merged.defaultCenterCustomName).toBe('');
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
      defaultCenterCustomName: 'x'.repeat(101),
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
