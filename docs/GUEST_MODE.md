# Guest Mode

Use OYBC without creating an account, with a one-tap path to convert to a real
account later without losing your boards. Cross-platform (web + iOS) — a
**rule-6 convergence**, not one of the documented iOS-only exceptions.

## Model: anonymous-auth-backed (why it's cheap)

A guest is signed in via **Firebase anonymous auth** (`signInAnonymously()`), which
mints a **real but hidden uid**. Because `userId` is *always* the Firebase uid and
is uniformly threaded through every create path and every user-scoped table
(`boards`, `tasks`, `taskEvents`, `pools`, `coreBoardDefaults`,
`recurringBoardTemplates`, `defaultPools`, and the `users` row), a guest is just
"a user whose Firebase account happens to be anonymous" — the entire app (boards,
tasks, completion events, preferences, notifications, streaks, tutorial) works
**unchanged**. Firestore rules are uid-only, so an anonymous user passes them; the
iOS `FOREIGN KEY(userId) REFERENCES users(id)` is satisfied because `upsertLocalUser`
creates the row.

The payoff is the upgrade: converting a guest to a permanent account is a Firebase
**account link** (`user.link(with:)` / `linkWithCredential`), which **preserves the
uid**. So there is **zero data re-keying** — every board/task/event already carries
the right `userId`. (The rejected fully-local alternative — a synthetic placeholder
uid, no Firebase — would have required a risky net-new re-key migration across all
tables plus iOS FK-ordering and sync-queue reconciliation.)

## Sync semantics

Sync **runs** for a guest (real uid → the safety-net loop / listeners start as
usual) and backs data up to the anonymous-owned Firestore tree. But an anonymous
account is device-local — it cannot be signed into on another device — so there is
**no cross-device sync** until the guest upgrades. The UI says "Backed up on this
device · Sign in to sync across devices", never "not synced".

## The one offline-first exception

Minting the anonymous uid requires **one network round-trip**. There is no fully
offline first launch (a fabricated local uid would need the re-key migration we're
avoiding). The entry points detect the offline/network error specifically and show
honest copy ("Connect once to start as a guest — then it works offline"), never a
silent broken half-state. After that first connect the anonymous session persists
locally (IndexedDB / iOS Keychain) and the app is fully offline-first thereafter.

## Entry points

- **iOS** — onboarding "Continue as guest" (was "Maybe later"), and a "Continue as
  guest" button on `LoginView` (so guest mode is reachable after first-run and after
  a sign-out). Both call `AuthService.signInAnonymously()`.
- **Web** — "Continue without an account" in `SignInModal` (canonical), optionally
  surfaced from `SignedOutHome`. Calls `useAuth().signInAnonymously()`.

## In-app guest treatment (`isAnonymous === true`)

`isAnonymous` is a **session-derived** flag (`firebaseUser.isAnonymous`) exposed on
both platforms (iOS `AuthService.@Published isAnonymous`; web `useAuth().isAnonymous`).
It is **never** persisted to the shared `User` type. Because linking fires no
auth-state event, it is recomputed after an upgrade (iOS `refreshProviderState()`;
web `refreshAfterUpgrade()`).

Guest surfaces:
- Profile account card shows **"Guest"** (email is empty for anon).
- "Account & security" and the plain **"Sign Out"** are replaced by a single
  **"Save your account"** upgrade CTA. A plain sign-out is intentionally withheld —
  for an anonymous user it orphans the Firestore tree and is irreversible data loss.
- Sync status shows the "sign in to sync across devices" line.

## Upgrade (guest → account)

Presented from the "Save your account" CTA (iOS `UpgradeAccountSheet`, web
`UpgradeModal`), offering Apple / Google / email+password. Each option calls the
existing link layer (iOS `AuthService.linkGoogle/linkApple/linkPassword`; web
`firebase/accountSecurity.ts` `linkGoogle/linkApple/linkPassword`) on the anonymous
`currentUser`.

**Post-link reconcile (the top defect to avoid):** `link*` mutates `currentUser` in
place and does **not** fire `onAuthStateChanged`, so the local `User` row would keep
`email:''`/no name unless we reconcile explicitly. iOS does this inside
`linkCredential` (re-upsert); web calls `refreshAfterUpgrade()` (→
`refreshLocalUserFromFirebase`) after each link.

**Collision (`credential-already-in-use` / `email-already-in-use`):** if the guest
links to an identity that already owns an account, the link fails. Merging two
Firestore trees is out of scope; the policy is **switch to the existing account**,
and the ordering is **verify before destroy**: on confirm, sign into the existing
account **first** while still anonymous. A wrong password or cancelled OAuth throws
harmlessly and leaves the guest session + local data intact — the naïve "delete the
anon account first, then sign in" order could wipe guest data and *then* fail on a
wrong password (the password the guest typed to create the email credential rarely
matches the pre-existing account's). Only on a successful switch do we clear the
stale anon sync queue (iOS `AuthService.clearPendingSyncQueue`; web
`clearSyncQueue`) so its pending pushes don't fail the owner check under the new
uid. The near-empty anonymous account orphans server-side (acceptable on a rare
collision — the alternative is data loss), and the guest's local rows are
`userId`-filtered out of every view under the signed-in account.

## Deletion / discard (Apple 5.1.1(v))

A guest has no "account" to delete until they upgrade, but their local data must be
purgeable. The guest Profile's destructive **"Discard guest data"** action (which
replaces "Sign Out") routes through the existing `deleteAccount()` →
`user.delete()` → the **`onUserDeleted`** Cloud Function, which is an
`auth.user().onDelete` trigger that fires for **anonymous** users too and recursively
purges the anon-owned tree. No function change was needed. (Anonymous `user.delete()`
requires no recent-login reauth.)

## Ops prerequisite

The **Anonymous** sign-in provider must be enabled in the Firebase console
(`oybc-dev-e2668`, and the prod project when the ROADMAP A4 split lands). Without it,
guest sign-in throws `auth/operation-not-allowed`. Every declined-upgrade collision
mints then deletes an anon uid; steady-state guests each hold one anon account
against the auth quota. No scheduled anon-account cleanup function is in scope — a
follow-up if orphan accrual ever matters.

## App Store rationale

- **5.1.1(i)** — don't force account creation for features that don't need one:
  guest mode is the affordance that satisfies this.
- **5.1.1(v)** — in-app account deletion: covered for guests via "Discard guest
  data" → `deleteAccount()` (same path as a real account).
