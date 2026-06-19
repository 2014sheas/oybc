# Notifications (Phase 7)

Local, OS-scheduled reminder notifications. **iOS only** at the feature level; web is a separately-scoped follow-up. This document is the canonical design reference; CLAUDE.md §Notifications is the quick summary.

## Why this didn't violate the offline-first non-goal

Notifications were a documented non-goal during Phases 1–6 ("no notifications / no `BGTaskScheduler` / lazy detection only"). The constraint conflated two different things:

1. **Background execution that writes to the DB** — still a hard non-goal. The offline-first invariant ("the local DB is the source of truth; no ambient process writes to it without user action") depends on it.
2. **Notifications** — these don't require (1).

iOS `UNUserNotificationCenter` lets the app *schedule* a notification while it's in the foreground; the OS then delivers it at the scheduled time even when the app is fully closed — **no background task, no DB write, no entitlement**. A fired notification creates no board and changes no state; it's a reminder. So local scheduled notifications relax only the "no notifications" line while preserving every load-bearing invariant. Push (which would need a backend, APNs, and `aps-environment`) remains a non-goal.

## The reconcile model

There is no background scheduler. Instead, the app **reconciles** the OS pending-notification set whenever it's foregrounded — the same lazy, on-app-open posture as recurring-board detection.

```
NotificationPlanner.desiredNotifications(boards, prefs, now)  →  [PlannedNotification]   (pure)
NotificationService.reconcile(userId)                          →  diff vs OS pending set  (effectful)
```

1. **`NotificationPlanner`** (`apps/ios/OYBC/Services/NotificationPlanner.swift`) is a pure function over the local boards + prefs + an injected `now`. No `UserNotifications` dependency, so it's fully unit-tested (`OYBCTests/NotificationPlannerTests.swift`). It returns plain `PlannedNotification` value types.
2. **`NotificationService`** (`Services/NotificationService.swift`, `@MainActor ObservableObject`, owned by `AuthService` like `SyncService`) reads boards+prefs off-main in one snapshot, runs the planner, fetches `pendingNotificationRequests()`, and **diffs by deterministic identifier**: removes `(pending − desired)`, re-adds the desired set (add replaces in place). Idempotent — re-running is a no-op when nothing changed. Reentrancy-guarded (one in-flight reconcile; a request mid-run schedules exactly one re-run).

`reconcile` is invoked from `MainTabView` on: app becomes `.active` (scenePhase), tab switches (catches a board just created on the Create tab), app launch (`.task`), and after any notification pref changes (from the settings view). A single `now` is captured per reconcile so the plan is internally consistent.

Known bounded-staleness: editing/deleting a board *while staying foregrounded on the Boards tab* (no tab switch, no background) doesn't reconcile until the next of those triggers. The window is small and the failure mode is benign — a stale reminder for a board whose deadline moved, cleared on the next reconcile; a tap on a since-deleted board's notification loads a mostly-empty view, no crash. A board-table `ValueObservation`-driven reconcile is a deferred refinement if this proves noticeable.

### Deterministic identifiers

- `expiry-<boardId>` — one per eligible board
- `recurring-window-<timeframe>-<nextWindowStartISO>` — one per eligible weekly/monthly/yearly window
- `daily-play-reminder` — the single repeating reminder

## Triggers (v1)

| Trigger | Fires | Eligibility | Backing pref |
| --- | --- | --- | --- |
| Board expiring soon | 9am the day before `endDate` | active, non-deleted, **non-daily** (weekly/monthly/yearly/custom with an `endDate`); fire date in `(now, now+30d]` | `expiringReminders` (default on) |
| New recurring window | 9am on the next window's first day | weekly/monthly/yearly only (**daily excluded** — would fire at midnight and duplicate the daily reminder); suppressed if a core board already exists for that window | `recurringWindowReminders` (default on) + per-timeframe `recurring*Enabled` |
| Daily play reminder | user-chosen time, repeating daily | — | `dailyPlayReminderEnabled` (default off) + `dailyPlayReminderTime` (default "20:00") |

All fire times use **9am local** for the one-shots (not the raw midnight window/endDate boundary, which is poor UX). Bingo/Greenlog moments are intentionally **not** notifications — they're foreground events already served by celebration overlays.

## The 64-pending cap

iOS keeps only the soonest ~64 pending requests per app and silently drops the rest. The app never relies on that opaque truncation — the **planner caps the desired set deterministically** before the diff:

- **Horizon**: expiry notifications more than 30 days out are not scheduled yet (re-armed on a later reconcile once they enter the horizon). The dominant lever.
- **Per-category budget**: expiry ≤ 50 (sorted soonest-first, tie-break by board id for stable truncation), recurring-window ≤ 3 (weekly/monthly/yearly), daily-reminder = 1 (a repeating trigger occupies one slot). Total ≤ 54, comfortably under 64.

## Permission (in-context priming)

- Master `notificationsEnabled` pref defaults **false**.
- Turning it on in settings shows an in-app priming explanation first, then calls `requestAuthorization(options: [.alert, .sound, .badge])`. The system prompt is never fired at launch (Apple-discouraged; burns the one-shot).
- `authorizationStatus` is refreshed on the settings page appearing and on app-active, so a permission change made in iOS Settings is reflected.
- `.denied` shows an inline "Open Settings" affordance (`UIApplication.openSettingsURLString`); the app does not nag or re-prompt. When unauthorized, `reconcile` computes an empty desired set, so it doubles as cleanup.

## Cold-launch deep-link

`NotificationDelegate.shared` (`Services/NotificationDelegate.swift`) is an app-lifetime `UNUserNotificationCenterDelegate` registered in `OYBCApp.init()` — **not** lazily after auth — because the system dispatches a cold-launch-from-tap notification before Firebase resolves the auth state; a late delegate would miss `didReceive`. It has no auth/DB dependency: it just buffers the tapped target into `@Published pendingDeepLink`. `MainTabView` drains that once signed-in (deep-links to the board for an `expiry-` tap via `userInfo["boardId"]`; otherwise surfaces the Boards tab). `willPresent` shows the banner while foregrounded.

## Entitlements / Info.plist

**Nothing required** for local-only notifications: no `aps-environment` entitlement, no Info.plist keys, no usage-description string. For contrast, *push* would need the Push Notifications capability + `aps-environment`, APNs registration, and `UIBackgroundModes = remote-notification` — none of which this design uses.

## App Store compliance (Guideline 4.5.4 and related)

Compliant by construction: opt-in (master default false + in-context priming), not required for app function, per-category + master user-disable, graceful `.denied`. **Notification copy stays strictly functional** — no marketing or re-engagement language.

## Preferences (synced)

Four new fields on `UserPreferences` (shared type + Zod schema + iOS struct), all additive/forward-compatible (no migration; JSON blob on iOS, `.optional()` in Zod, filled by `mergeUserPreferences`):

- `notificationsEnabled: boolean` (default false) — master opt-in
- `recurringWindowReminders: boolean` (default true)
- `dailyPlayReminderEnabled: boolean` (default false)
- `dailyPlayReminderTime: string` `"HH:mm"` (default "20:00")

Plus the previously-dead `expiringReminders` (default true), now live. They ride the existing user-prefs LWW sync path (no new collection). Each device schedules its own local notifications from the synced prefs; dedup is inherent (local delivery + deterministic identifiers).

## Files

- `Services/NotificationPlanner.swift` — pure planner (+ `OYBCTests/NotificationPlannerTests.swift`)
- `Services/NotificationService.swift` — OS scheduling + reconcile, auth-owned
- `Services/NotificationDelegate.swift` — app-lifetime delegate, cold-launch buffer
- `Views/ProfileTab/NotificationPreferencesView.swift` — settings (thin container + `NotificationPreferencesContent` leaf; the leaf is snapshot-tested in `OYBCSnapshotTests/NotificationPreferencesSnapshotTests.swift`)
- Wiring: `OYBCApp.swift` (delegate register), `AuthService.swift` (owns service + `clearAll` on sign-out), `AuthGateView.swift` (env injection), `MainTabView.swift` (reconcile + deep-link drain), `ProfileView.swift` (nav row). `expiringReminders` moved out of `BoardPreferencesView`.

## Verification that can't be unit-tested (relay to user)

Per the project's no-sim-driving convention, these need manual on-device checks: the permission prompt + grant/deny → Settings link; an expiry notification firing while the app is closed; a new-window notification; the daily reminder at the set time; the foreground banner; the **cold-launch-from-tap deep-link** (highest-risk); and no duplicate recurring-window banners across reconciles.

## Deferred

Web notifications (PWA + service worker + FCM/VAPID + backend scheduler); bingo/greenlog-moment notifications; streaks (no domain model exists); `autoArchiveCompleted` wiring; server push of any kind.
