import { z } from 'zod';

/**
 * Zod schema for the server-authoritative `entitlements/{uid}` doc (monetization,
 * docs/MONETIZATION.md) — used by the RevenueCat webhook Cloud Function on write
 * and by tests/clients on decode. Mirrors `Entitlement` in
 * `../types/entitlement.ts`.
 *
 * Lives in its own file (not schemas.ts) because schemas.ts is a frozen
 * god-file at its size cap (ROADMAP B6). `updatedAt` is a plain string (not
 * `.datetime()`) so the free-default's empty-string value and the webhook's
 * event timestamps both validate.
 */
export const ProProductSchema = z.union([
  z.literal('monthly'),
  z.literal('yearly'),
  z.literal('lifetime'),
]);

export const EntitlementStoreSchema = z.union([
  z.literal('app_store'),
  z.literal('play_store'),
  z.literal('stripe'),
  z.literal('promotional'),
]);

export const EntitlementSchema = z.object({
  tier: z.union([z.literal('free'), z.literal('pro')]),
  isPro: z.boolean(),
  product: ProProductSchema.optional(),
  expiresAt: z.string().datetime().nullable().optional(),
  willRenew: z.boolean().optional(),
  store: EntitlementStoreSchema.optional(),
  updatedAt: z.string(),
  source: z.union([z.literal('revenuecat-webhook'), z.literal('default')]),
});
