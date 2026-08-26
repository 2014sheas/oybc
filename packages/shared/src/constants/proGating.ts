import type { Entitlement } from '../types/entitlement';

/**
 * Pro gating — the SINGLE cross-platform definition of "what's Pro" and the
 * free-tier caps. Mirrored in Swift by `apps/ios/OYBC/Constants/ProGating.swift`;
 * keep the two in lock-step (like the sync contract).
 *
 * Pure functions only (no I/O, no side effects) per `packages/shared` conventions,
 * so web + iOS share ONE gating decision and can't drift. The UI just routes to the
 * paywall when a gate returns true.
 *
 * **Client gates are UX only, never a security boundary** — anything abuse-sensitive
 * must re-check server-side. See docs/MONETIZATION.md and ../types/entitlement.ts.
 *
 * Product model (configured in App Store Connect / RevenueCat, not here):
 *   monthly · yearly · lifetime (limited-time early-adopter), 7-day trial on subs.
 * Free = one-off boards (≤ `maxActiveBoards`) + normal/counting tasks + full
 * streaks/greenlog/bingo. Pro = unlimited boards + all recurring/core boards +
 * achievement + compound tasks.
 */

/** The RevenueCat entitlement identifier that grants Pro. Same string both platforms. */
export const PRO_ENTITLEMENT_ID = 'oybc_pro';

/**
 * Pro-only capabilities. Free users see these locked (with a Pro badge), never
 * hidden. `unlimited-boards` is enforced as a count cap (`isOverFreeLimit`); the
 * rest are boolean gates (`isFeatureGated`).
 */
export type ProFeature =
  | 'unlimited-boards'
  | 'recurring-boards' // all recurring/core: daily, weekly, monthly, yearly, templates, custom
  | 'achievement-tasks'
  | 'compound-tasks';

export const FREE_TIER_LIMITS = {
  /**
   * Max concurrently-ACTIVE boards on free. Sealed / past-window boards do NOT
   * count, so a user isn't penalized for history — only live boards occupy a slot.
   */
  maxActiveBoards: 5,
} as const;

/**
 * Grace window (days) applied after an entitlement's expiry before a user is
 * treated as free. Covers store billing-retry windows and brief offline staleness
 * so a paying user is never hard-locked on a transient blip.
 */
export const GRACE_PERIOD_DAYS = 3;

const DAY_MS = 24 * 60 * 60 * 1000;

/**
 * Whether an entitlement grants **active** Pro access at `nowMs`, applying the
 * grace window. This is the authoritative client-side "is Pro" check — prefer it
 * over the denormalized `entitlement.isPro`.
 *
 * - free tier → false
 * - lifetime (no `expiresAt`) → true
 * - subscription → active until `expiresAt` + grace
 * - a pro doc with an unparseable `expiresAt` → true (fail OPEN: never hard-lock a
 *   payer over a malformed timestamp; the server remains the real authority)
 *
 * `nowMs` is an explicit parameter (not `Date.now()` internally) so the function
 * stays pure and deterministically testable, matching the package's algorithm style.
 */
export function isEntitlementActive(entitlement: Entitlement, nowMs: number): boolean {
  if (entitlement.tier !== 'pro') return false;
  if (entitlement.expiresAt == null) return true; // lifetime / non-expiring
  const expiryMs = Date.parse(entitlement.expiresAt);
  if (Number.isNaN(expiryMs)) return true; // fail open on a malformed expiry
  return nowMs <= expiryMs + GRACE_PERIOD_DAYS * DAY_MS;
}

/** Convenience alias for the active-Pro check used across gates. */
export function isPro(entitlement: Entitlement, nowMs: number): boolean {
  return isEntitlementActive(entitlement, nowMs);
}

/**
 * Whether a boolean Pro feature is locked for this entitlement. Use for
 * `recurring-boards`, `achievement-tasks`, `compound-tasks`. (`unlimited-boards`
 * is a count cap — use `isOverFreeLimit`.) Locked iff the user is not active-Pro.
 */
export function isFeatureGated(
  _feature: Exclude<ProFeature, 'unlimited-boards'>,
  entitlement: Entitlement,
  nowMs: number
): boolean {
  return !isPro(entitlement, nowMs);
}

/**
 * Whether creating one more of a count-limited resource would exceed the free cap.
 * Pro is never over a limit. Today only `unlimited-boards` is count-based;
 * `currentCount` is the user's current ACTIVE (non-sealed, non-deleted) board count.
 */
export function isOverFreeLimit(
  feature: ProFeature,
  currentCount: number,
  entitlement: Entitlement,
  nowMs: number
): boolean {
  if (isPro(entitlement, nowMs)) return false;
  switch (feature) {
    case 'unlimited-boards':
      return currentCount >= FREE_TIER_LIMITS.maxActiveBoards;
    default:
      return false;
  }
}

/**
 * Convenience for the board-creation gate: can a user with `activeBoardCount`
 * active boards create another? Pro → always; free → under the cap.
 */
export function canCreateBoard(
  activeBoardCount: number,
  entitlement: Entitlement,
  nowMs: number
): boolean {
  return !isOverFreeLimit('unlimited-boards', activeBoardCount, entitlement, nowMs);
}
