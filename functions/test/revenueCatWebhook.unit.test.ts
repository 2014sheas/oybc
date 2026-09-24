/**
 * Pure unit tests for the RevenueCat webhook's decision helpers
 * (functions/src/revenueCatWebhook.ts) — one vector per 2026-09 hardening
 * rule. The HTTP wiring of the same rules is covered end-to-end in
 * `revenueCatWebhook.test.ts` against the Functions emulator.
 */
import { describe, it, expect } from "vitest";
import {
  deriveEntitlement,
  isAllowedEnvironment,
  isValidAppUserId,
  safeEqual,
} from "../src/revenueCatWebhook";

const DAY = 24 * 60 * 60 * 1000;

function event(overrides: Record<string, unknown> = {}) {
  return {
    id: "evt1",
    type: "INITIAL_PURCHASE",
    app_user_id: "AbCdEfGhIjKlMnOpQrStUvWxYz12",
    product_id: "com.oybc.pro.monthly",
    entitlement_ids: ["oybc_pro"],
    expiration_at_ms: Date.now() + 30 * DAY,
    event_timestamp_ms: Date.now(),
    store: "APP_STORE",
    environment: "PRODUCTION",
    ...overrides,
  };
}

describe("isAllowedEnvironment (sandbox gate)", () => {
  it("rejects SANDBOX when the allow-list is PRODUCTION only (prod config)", () => {
    expect(isAllowedEnvironment("SANDBOX", "PRODUCTION")).toBe(false);
  });
  it("accepts PRODUCTION under the prod config", () => {
    expect(isAllowedEnvironment("PRODUCTION", "PRODUCTION")).toBe(true);
  });
  it("accepts SANDBOX under the default (dev) config, tolerating spaces", () => {
    expect(isAllowedEnvironment("SANDBOX", "PRODUCTION, SANDBOX")).toBe(true);
  });
  it("rejects a non-string environment", () => {
    expect(isAllowedEnvironment(42, "PRODUCTION,SANDBOX")).toBe(false);
  });
});

describe("isValidAppUserId", () => {
  it("accepts a Firebase-uid-shaped id", () => {
    expect(isValidAppUserId("AbCdEfGhIjKlMnOpQrStUvWxYz12")).toBe(true);
  });
  it.each([
    ["RevenueCat anonymous id", "$RCAnonymousID:0123456789abcdef0123456789abcdef"],
    ["path traversal", "../users/AbCdEfGhIjKlMnOpQrSt"],
    ["too short", "abc123"],
    ["too long", "a".repeat(129)],
    ["non-string", 12345678901234567890],
  ])("rejects %s", (_label, uid) => {
    expect(isValidAppUserId(uid)).toBe(false);
  });
});

describe("deriveEntitlement hardening", () => {
  it("does NOT grant (let alone lifetime) on a CANCELLATION with a null expiry", () => {
    expect(
      deriveEntitlement(event({ type: "CANCELLATION", expiration_at_ms: null, cancel_reason: "UNSUBSCRIBE" })),
    ).toBeNull();
  });

  it("does NOT grant on an INITIAL_PURCHASE of a non-lifetime product with a null expiry", () => {
    expect(deriveEntitlement(event({ expiration_at_ms: null }))).toBeNull();
  });

  it("still grants lifetime on an INITIAL_PURCHASE of the lifetime product with a null expiry", () => {
    const d = deriveEntitlement(event({ product_id: "com.oybc.pro.lifetime", expiration_at_ms: null }));
    expect(d).toMatchObject({ tier: "pro", product: "lifetime", expiresAt: null });
  });

  it("still grants lifetime on NON_RENEWING_PURCHASE with a null expiry", () => {
    const d = deriveEntitlement(
      event({ type: "NON_RENEWING_PURCHASE", product_id: "com.oybc.pro.lifetime", expiration_at_ms: null }),
    );
    expect(d).toMatchObject({ tier: "pro", product: "lifetime", expiresAt: null });
  });

  it("keeps a plain UNSUBSCRIBE CANCELLATION as pro until expiry (willRenew false)", () => {
    const d = deriveEntitlement(event({ type: "CANCELLATION", cancel_reason: "UNSUBSCRIBE" }));
    expect(d).toMatchObject({ tier: "pro", willRenew: false });
    expect(typeof d?.expiresAt).toBe("string");
  });

  it("revokes on a refund CANCELLATION (cancel_reason CUSTOMER_SUPPORT)", () => {
    expect(
      deriveEntitlement(event({ type: "CANCELLATION", cancel_reason: "CUSTOMER_SUPPORT" })),
    ).toMatchObject({ tier: "free", isPro: false });
  });

  it("revokes a refunded lifetime purchase (CUSTOMER_SUPPORT, null expiry)", () => {
    expect(
      deriveEntitlement(
        event({
          type: "CANCELLATION",
          cancel_reason: "CUSTOMER_SUPPORT",
          product_id: "com.oybc.pro.lifetime",
          expiration_at_ms: null,
        }),
      ),
    ).toMatchObject({ tier: "free", isPro: false });
  });

  it("does NOT grant when entitlement ids are absent", () => {
    expect(deriveEntitlement(event({ entitlement_ids: null, entitlement_id: null }))).toBeNull();
  });

  it("still revokes on EXPIRATION without entitlement ids", () => {
    expect(
      deriveEntitlement(event({ type: "EXPIRATION", entitlement_ids: null, entitlement_id: null })),
    ).toMatchObject({ tier: "free", isPro: false });
  });
});

describe("safeEqual (digest compare)", () => {
  it("is true for equal strings", () => {
    expect(safeEqual("test-rc-webhook-secret", "test-rc-webhook-secret")).toBe(true);
  });
  it("is false for same-length different strings", () => {
    expect(safeEqual("test-rc-webhook-secreT", "test-rc-webhook-secret")).toBe(false);
  });
  it("is false (and does not throw) for different-length strings", () => {
    expect(safeEqual("short", "test-rc-webhook-secret")).toBe(false);
    expect(safeEqual("", "test-rc-webhook-secret")).toBe(false);
  });
});
