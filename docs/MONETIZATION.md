# Monetization — "Pro" paywall (RevenueCat)

OYBC's paid tier. A **Pro** subscription (monthly / yearly, plus a limited-time
lifetime unlock) gates a set of premium features; everything else stays free and
fully offline-first. RevenueCat unifies the App Store (StoreKit 2) and the web
(RevenueCat Web Billing → Stripe) into a **single, uid-keyed entitlement**.

Shipped in two parts: the **foundation + backend** (PR #451, merged) and the
**client + paywall + gates** (Phase 3, this feature branch).

## The one principle: authority vs. display

OYBC is offline-first — the local DB is the source of truth and everything in
`SYNC_COLLECTIONS` is **client-owned last-write-wins**, freely writable by the
client. That's correct for feature toggles and fatal for a paid flag. So a paid
entitlement **must not** live in `UserPreferences` or any synced collection.

- **Authority** = a **server-authoritative** top-level Firestore collection
  `entitlements/{uid}` — `firestore.rules`: `allow read: if owner; allow write:
  if false`. The **only** writer is the RevenueCat webhook Cloud Function via the
  Admin SDK (which bypasses rules). This is byte-for-byte the `signups` pattern.
  It lives **outside** the sync engine and outside the drift guardrails (it never
  touches `isKnownCollection()`/`requiresUserIdField()`).
- **Display** = RevenueCat's on-device cached `CustomerInfo` (offline-capable) —
  the fast signal the UI reads.
- **Client `isPro` is UX only, never a security boundary.** Anything
  abuse-sensitive must re-check server-side.

## Product model (locked)

| | Free | Pro |
| --- | --- | --- |
| Boards | ≤ 5 **active** one-off (sealed/deleted excluded) | Unlimited |
| Recurring / core boards | — | Daily, weekly, monthly, yearly, templates, custom |
| Tasks | Normal, Counting | + Achievement, Compound |
| Streaks / greenlog / bingo | ✅ full | ✅ |

- **Prices:** $2.99/mo · $21.99/yr · **$39.99 lifetime** (limited-time
  early-adopter) · **7-day free trial** on the subscriptions.
- **Purchasing requires a real account.** Guests see the paywall, but tapping a
  plan routes through the existing guest→account upgrade first. So an entitlement
  is **never created on an anonymous uid** — which is why there is no RevenueCat
  **TRANSFER** handling to write (nothing ever lives on a transferable anon uid).

The single cross-platform definition lives in
`packages/shared/src/constants/proGating.ts` (`PRO_ENTITLEMENT_ID = 'oybc_pro'`,
`FREE_TIER_LIMITS`, `GRACE_PERIOD_DAYS`, and the pure `isEntitlementActive` /
`isFeatureGated` / `canCreateBoard`), mirrored in Swift by
`apps/ios/OYBC/Constants/ProGating.swift`. Keep the two in lock-step.

> ⚠️ The RevenueCat **entitlement identifier is `oybc_pro`** (not `pro`). The
> internal `EntitlementTier` `'pro'`/`'free'` literals are a *separate* concept —
> don't conflate them.

## Data model

`Entitlement` (`packages/shared/src/types/entitlement.ts`, Swift mirror
`Database/Models/Entitlement.swift`): `tier`, `isPro`, `product?`, `expiresAt?`
(null for lifetime), `willRenew?`, `store?`, `updatedAt`, `source`. The tolerant
`mergeEntitlement` decoder **recomputes `isPro` from `tier`** (never trusts a
spoofed value) and forces lifetime to never-expire. Validated by
`EntitlementSchema` (`validation/entitlement.ts` — kept out of the frozen
`schemas.ts` god-file).

## Backend — the webhook

`functions/src/revenueCatWebhook.ts` (`onRequest`, region us-central1) is the sole
writer of `entitlements/{uid}`:

- **Auth:** constant-time compare of the `Authorization` header against the
  `REVENUECAT_WEBHOOK_AUTH` secret (`defineSecret`). **Fails closed** if the
  secret is unconfigured. 405/401/400 guards.
- **Idempotent + monotonic** transactional write (guarded by `event.id` +
  `event_timestamp_ms`) so RevenueCat's at-least-once / out-of-order redelivery
  can't regress a fresh entitlement.
- Maps the event lifecycle → `pro`/`free`; lifetime (`NON_RENEWING_PURCHASE` / no
  expiry) → `expiresAt: null`. No `TRANSFER` branch (see product model).
- **Rules test:** `firestore-rules-tests` (owner-read, no client write). **Webhook
  test:** `functions/test/revenueCatWebhook.test.ts` (emulator; CI-only — the dev
  machine has no Java). Deploys via the existing `functions.yml` /
  `firestore-rules.yml` on merge to `dev`.

Live webhook URL: `https://us-central1-oybc-dev-e2668.cloudfunctions.net/revenueCatWebhook`
(configured in RevenueCat → Integrations → Webhooks with the same secret).

## Client entitlement layer

- **Web:** `entitlement/revenueCat.ts` (`@revenuecat/purchases-js` wrapper —
  configure/`changeUser` keyed to the uid, `getCustomerInfo`/`getOfferings`/
  `purchase`) + `hooks/useEntitlement.ts` (reactive `isPro` = RC cached
  `CustomerInfo` **OR** the live `entitlements/{uid}` `onSnapshot` via
  `isEntitlementActive`). Web Billing key: `VITE_REVENUECAT_WEB_KEY`.
- **iOS:** `Services/EntitlementService.swift` (`@MainActor` `NSObject`
  `ObservableObject`; `@Published isPro` from the `PurchasesDelegate`'s live
  `CustomerInfo` **OR** the Firestore listener). Configured at launch in
  `OYBCApp.init` after `FirebaseApp.configure()`. Apple key is a publishable
  constant.
- **Auth-lifecycle bridge** (identify on sign-in, reset on sign-out, re-identify
  after upgrade, re-identify on the collision account-switch): web in
  `AuthContext.tsx`; iOS in `AuthService` (drives `entitlementService.identify/
  reset` from the auth-state listener + `linkCredential` + `deleteAccount`, exactly
  like `syncService`).

## Paywall + gates

- **Paywall:** web `components/paywall/ProPaywall.tsx`, iOS
  `Views/Paywall/ProPaywallView.swift`. Renders the current RevenueCat offering
  (monthly/yearly/lifetime + trial), **Restore Purchases**, and **Terms/Privacy
  links** (App Store 3.1.2), with a "You're on Pro" state; user-cancels are silent;
  a guest is routed through the upgrade flow first.
- **Gates** (open the paywall at the action-initiation layer):
  - **Board creation** — web `CreateHubPage` / iOS `CreateHubView`: one-off CTA →
    `canCreateBoard(activeBoardCount)`; recurring CTA + core-boards section +
    recurring deep-links → `isFeatureGated('recurring-boards')`.
  - **Task types** — web `CreateNewTaskForm` / iOS `RisoSpecialTaskPanel`: the
    COMPOUND / ACHIEVEMENT picker → `isFeatureGated('compound-tasks' | 'achievement-tasks')`.
- **Offline/grace:** gates read the cached RC signal + last-known authority; Pro
  stays active within `GRACE_PERIOD_DAYS` past expiry so a briefly-offline payer is
  never hard-locked.

## App Store compliance

- **3.1.1:** iOS digital features use StoreKit IAP (via RevenueCat) — never Stripe
  inside the iOS app. **3.1.3(b):** no in-app steering to cheaper web pricing.
- **3.1.2:** the paywall shows price/length + Terms/Privacy links; App Store
  Connect needs the subscription group + a 7-day intro offer + localizations.
- **5.1.1(v):** account deletion already ships (guest + account).

## Known follow-ups

- **Web Billing** provisioning + the web paywall's Stripe-backed checkout are set
  up; if web launches after iOS, nothing about the backend changes.
- **Secondary recurring deep-links not gated yet:** the core-board *browser* page
  and the Boards-tab banner emitters. Client gates are UX-only and these are
  low-traffic; the primary Create-hub flows are gated.
- **Real Terms/Privacy URLs** must replace the placeholder `oybc.com/terms|privacy`
  before App Store submission.
- **Device testing** (StoreKit sandbox + Stripe test mode) is manual on real
  hardware — the emulator tests cover the webhook/rules only.
