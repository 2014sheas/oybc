import {
  Purchases,
  type CustomerInfo,
  type Offerings,
  type Package,
  type PurchaseResult,
} from '@revenuecat/purchases-js';
import { PRO_ENTITLEMENT_ID } from '@oybc/shared';

/**
 * Thin wrapper over `@revenuecat/purchases-js` (RevenueCat Web Billing). The
 * Pro entitlement is server-authoritative (`entitlements/{uid}` via the webhook,
 * docs/MONETIZATION.md); RevenueCat's cached `CustomerInfo` here is the fast,
 * offline-capable DISPLAY signal and the checkout surface — never a security
 * boundary. `appUserId` is the Firebase uid, so purchases resolve to the same
 * entitlement across web + iOS.
 *
 * The publishable Web Billing key is a client key (safe to ship); it's read from
 * `VITE_REVENUECAT_WEB_KEY`. When absent (e.g. a build without the var), the
 * wrapper degrades to a no-op / free — the paywall just won't be purchasable.
 */
const WEB_API_KEY = import.meta.env.VITE_REVENUECAT_WEB_KEY as string | undefined;

/** The uid RevenueCat is currently identified as, to skip redundant changeUser calls. */
let identifiedUid: string | null = null;
let warnedMissingKey = false;

/** Whether a Web Billing key is configured (paywall purchasing is possible). */
export function isRevenueCatAvailable(): boolean {
  return Boolean(WEB_API_KEY);
}

function warnMissingKeyOnce(): void {
  if (!warnedMissingKey) {
    warnedMissingKey = true;
    console.warn('[entitlement] VITE_REVENUECAT_WEB_KEY not set — web purchasing disabled.');
  }
}

/**
 * Point RevenueCat at `uid` (the Firebase uid). Configures on first call, else
 * switches the signed-in user. Idempotent for the same uid. Call on sign-in and
 * after a guest→account upgrade (uid preserved → cheap no-op).
 */
export async function identifyRevenueCat(uid: string): Promise<void> {
  if (!WEB_API_KEY) {
    warnMissingKeyOnce();
    return;
  }
  if (identifiedUid === uid && Purchases.isConfigured()) return;
  if (!Purchases.isConfigured()) {
    Purchases.configure(WEB_API_KEY, uid);
  } else {
    await Purchases.getSharedInstance().changeUser(uid);
  }
  identifiedUid = uid;
}

/**
 * Detach the signed-in user on sign-out by switching to a fresh RevenueCat
 * anonymous id, so no stale user context lingers. (Purchasing requires a real
 * account, so an anonymous RC id never owns Pro.)
 */
export async function resetRevenueCatUser(): Promise<void> {
  identifiedUid = null;
  if (!WEB_API_KEY || !Purchases.isConfigured()) return;
  await Purchases.getSharedInstance().changeUser(Purchases.generateRevenueCatAnonymousAppUserId());
}

/** Current cached/fetched CustomerInfo, or null if not configured. */
export async function getWebCustomerInfo(): Promise<CustomerInfo | null> {
  if (!Purchases.isConfigured()) return null;
  return Purchases.getSharedInstance().getCustomerInfo();
}

/** Whether RevenueCat considers the Pro entitlement active for this CustomerInfo. */
export function isProFromCustomerInfo(info: CustomerInfo | null): boolean {
  return Boolean(info?.entitlements.active[PRO_ENTITLEMENT_ID]);
}

/** Current offerings (packages) for the paywall, or null if not configured. */
export async function getWebOfferings(): Promise<Offerings | null> {
  if (!Purchases.isConfigured()) return null;
  return Purchases.getSharedInstance().getOfferings();
}

/** Present RevenueCat Web Billing's hosted checkout for a package. */
export async function purchaseWebPackage(rcPackage: Package): Promise<PurchaseResult> {
  return Purchases.getSharedInstance().purchase({ rcPackage });
}
