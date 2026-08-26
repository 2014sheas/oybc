import {
  FREE_TIER_LIMITS,
  GRACE_PERIOD_DAYS,
  PRO_ENTITLEMENT_ID,
  canCreateBoard,
  isEntitlementActive,
  isFeatureGated,
  isOverFreeLimit,
  isPro,
} from '../../src/constants/proGating';
import { DEFAULT_ENTITLEMENT, mergeEntitlement, type Entitlement } from '../../src/types/entitlement';

const NOW = Date.parse('2026-08-23T12:00:00.000Z');
const DAY = 24 * 60 * 60 * 1000;

function pro(overrides: Partial<Entitlement> = {}): Entitlement {
  return mergeEntitlement({
    tier: 'pro',
    product: 'monthly',
    expiresAt: new Date(NOW + 30 * DAY).toISOString(),
    source: 'revenuecat-webhook',
    updatedAt: new Date(NOW).toISOString(),
    ...overrides,
  });
}

describe('isEntitlementActive / isPro', () => {
  it('is false for the free default', () => {
    expect(isEntitlementActive(DEFAULT_ENTITLEMENT, NOW)).toBe(false);
    expect(isPro(DEFAULT_ENTITLEMENT, NOW)).toBe(false);
  });

  it('is true for an active subscription', () => {
    expect(isPro(pro(), NOW)).toBe(true);
  });

  it('is true for lifetime (null expiresAt)', () => {
    expect(isPro(pro({ product: 'lifetime', expiresAt: null }), NOW)).toBe(true);
  });

  it('honors the grace window after expiry', () => {
    const expiredWithinGrace = pro({
      expiresAt: new Date(NOW - 1 * DAY).toISOString(), // expired 1 day ago
    });
    const expiredPastGrace = pro({
      expiresAt: new Date(NOW - (GRACE_PERIOD_DAYS + 1) * DAY).toISOString(),
    });
    expect(isPro(expiredWithinGrace, NOW)).toBe(true); // within 3-day grace
    expect(isPro(expiredPastGrace, NOW)).toBe(false); // past grace
  });

  it('fails open on a malformed expiry for a pro doc (never hard-lock a payer)', () => {
    const bad = mergeEntitlement({ tier: 'pro', product: 'monthly', expiresAt: 'not-a-date' });
    expect(isPro(bad, NOW)).toBe(true);
  });
});

describe('isOverFreeLimit / canCreateBoard', () => {
  it('free is capped at maxActiveBoards active boards', () => {
    const free = DEFAULT_ENTITLEMENT;
    expect(isOverFreeLimit('unlimited-boards', FREE_TIER_LIMITS.maxActiveBoards - 1, free, NOW)).toBe(false);
    expect(isOverFreeLimit('unlimited-boards', FREE_TIER_LIMITS.maxActiveBoards, free, NOW)).toBe(true);
    expect(canCreateBoard(FREE_TIER_LIMITS.maxActiveBoards - 1, free, NOW)).toBe(true);
    expect(canCreateBoard(FREE_TIER_LIMITS.maxActiveBoards, free, NOW)).toBe(false);
  });

  it('pro is never over the limit', () => {
    expect(isOverFreeLimit('unlimited-boards', 999, pro(), NOW)).toBe(false);
    expect(canCreateBoard(999, pro(), NOW)).toBe(true);
  });
});

describe('isFeatureGated', () => {
  it('locks recurring/achievement/compound for free, unlocks for pro', () => {
    for (const f of ['recurring-boards', 'achievement-tasks', 'compound-tasks'] as const) {
      expect(isFeatureGated(f, DEFAULT_ENTITLEMENT, NOW)).toBe(true);
      expect(isFeatureGated(f, pro(), NOW)).toBe(false);
    }
  });

  it('locks features once a subscription lapses past grace', () => {
    const lapsed = pro({ expiresAt: new Date(NOW - (GRACE_PERIOD_DAYS + 5) * DAY).toISOString() });
    expect(isFeatureGated('recurring-boards', lapsed, NOW)).toBe(true);
  });
});

describe('constants', () => {
  it('exposes the RevenueCat entitlement id and cap', () => {
    expect(PRO_ENTITLEMENT_ID).toBe('oybc_pro');
    expect(FREE_TIER_LIMITS.maxActiveBoards).toBe(5);
    expect(GRACE_PERIOD_DAYS).toBe(3);
  });
});
