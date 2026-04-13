import {
  UserPreferencesSchema,
  UserSchema,
} from '../../src/validation/schemas';
import {
  DEFAULT_USER_PREFERENCES,
  mergeUserPreferences,
} from '../../src/types/user';
import { CenterSquareType } from '../../src/constants/enums';

describe('UserPreferencesSchema', () => {
  it('accepts the default preferences object', () => {
    expect(() => UserPreferencesSchema.parse(DEFAULT_USER_PREFERENCES)).not.toThrow();
  });

  it.each([
    ['weekStartDay', { weekStartDay: 'tuesday' }],
    ['defaultBoardSize (6)', { defaultBoardSize: 6 }],
    ['defaultCenterType (CHOSEN)', { defaultCenterType: CenterSquareType.CHOSEN }],
    ['defaultCenterType (CUSTOM_FREE)', { defaultCenterType: CenterSquareType.CUSTOM_FREE }],
  ])('rejects invalid %s', (_label, override) => {
    expect(() =>
      UserPreferencesSchema.parse({ ...DEFAULT_USER_PREFERENCES, ...override })
    ).toThrow();
  });

  it('requires all three fields', () => {
    expect(() => UserPreferencesSchema.parse({ weekStartDay: 'monday' })).toThrow();
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

  it('returns a fresh object (not the defaults reference)', () => {
    const merged = mergeUserPreferences(undefined);
    expect(merged).not.toBe(DEFAULT_USER_PREFERENCES);
  });
});
