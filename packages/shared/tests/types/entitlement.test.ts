import {
  DEFAULT_ENTITLEMENT,
  mergeEntitlement,
  type Entitlement,
} from '../../src/types/entitlement';
import { EntitlementSchema } from '../../src/validation/schemas';

describe('mergeEntitlement', () => {
  it('returns the free default for null/undefined', () => {
    expect(mergeEntitlement(null)).toEqual(DEFAULT_ENTITLEMENT);
    expect(mergeEntitlement(undefined)).toEqual(DEFAULT_ENTITLEMENT);
  });

  it('decodes an active monthly subscription', () => {
    const result = mergeEntitlement({
      tier: 'pro',
      isPro: true,
      product: 'monthly',
      expiresAt: '2026-09-23T00:00:00.000Z',
      willRenew: true,
      store: 'app_store',
      updatedAt: '2026-08-23T00:00:00.000Z',
      source: 'revenuecat-webhook',
    });
    expect(result).toEqual<Entitlement>({
      tier: 'pro',
      isPro: true,
      product: 'monthly',
      expiresAt: '2026-09-23T00:00:00.000Z',
      willRenew: true,
      store: 'app_store',
      updatedAt: '2026-08-23T00:00:00.000Z',
      source: 'revenuecat-webhook',
    });
  });

  it('forces expiresAt to null for a lifetime product (never expires)', () => {
    const result = mergeEntitlement({
      tier: 'pro',
      isPro: true,
      product: 'lifetime',
      // A misbehaving writer sent an expiry for a lifetime purchase — must be dropped.
      expiresAt: '2026-09-23T00:00:00.000Z',
      store: 'stripe',
      updatedAt: '2026-08-23T00:00:00.000Z',
      source: 'revenuecat-webhook',
    });
    expect(result.product).toBe('lifetime');
    expect(result.expiresAt).toBeNull();
  });

  it('recomputes isPro from tier — never trusts a spoofed isPro', () => {
    // tier:free but isPro:true (spoof) → isPro must be forced false.
    expect(mergeEntitlement({ tier: 'free', isPro: true }).isPro).toBe(false);
    // tier:pro but isPro:false → isPro must be forced true.
    expect(mergeEntitlement({ tier: 'pro', isPro: false, product: 'yearly' }).isPro).toBe(true);
  });

  it('drops free-tier metadata (no product/expiry/renewal leaks onto free)', () => {
    const result = mergeEntitlement({
      tier: 'free',
      product: 'monthly',
      expiresAt: '2026-09-23T00:00:00.000Z',
      willRenew: true,
    } as Partial<Entitlement>);
    expect(result).toEqual<Entitlement>({
      tier: 'free',
      isPro: false,
      updatedAt: '',
      source: 'default',
    });
  });

  it('falls back to free for an unknown tier and to default source', () => {
    const result = mergeEntitlement({ tier: 'platinum' as unknown as 'pro' });
    expect(result.tier).toBe('free');
    expect(result.source).toBe('default');
  });

  it('drops invalid product/store values while keeping the pro tier', () => {
    const result = mergeEntitlement({
      tier: 'pro',
      product: 'weekly' as unknown as 'monthly',
      store: 'paypal' as unknown as 'stripe',
      updatedAt: '2026-08-23T00:00:00.000Z',
      source: 'revenuecat-webhook',
    });
    expect(result.tier).toBe('pro');
    expect(result.product).toBeUndefined();
    expect(result.store).toBeUndefined();
  });

  it('preserves an explicit null expiresAt for a non-lifetime product', () => {
    const result = mergeEntitlement({ tier: 'pro', product: 'monthly', expiresAt: null });
    expect(result.expiresAt).toBeNull();
  });
});

describe('EntitlementSchema', () => {
  it('accepts the free default', () => {
    expect(() => EntitlementSchema.parse(DEFAULT_ENTITLEMENT)).not.toThrow();
  });

  it('accepts a merged pro entitlement', () => {
    const pro = mergeEntitlement({
      tier: 'pro',
      product: 'yearly',
      expiresAt: '2027-08-23T00:00:00.000Z',
      willRenew: true,
      store: 'app_store',
      updatedAt: '2026-08-23T00:00:00.000Z',
      source: 'revenuecat-webhook',
    });
    expect(() => EntitlementSchema.parse(pro)).not.toThrow();
  });

  it('accepts a lifetime entitlement with null expiresAt', () => {
    const lifetime = mergeEntitlement({
      tier: 'pro',
      product: 'lifetime',
      updatedAt: '2026-08-23T00:00:00.000Z',
      source: 'revenuecat-webhook',
    });
    expect(() => EntitlementSchema.parse(lifetime)).not.toThrow();
  });

  it('rejects an unknown tier', () => {
    expect(() => EntitlementSchema.parse({ ...DEFAULT_ENTITLEMENT, tier: 'gold' })).toThrow();
  });
});
