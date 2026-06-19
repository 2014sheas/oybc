import Foundation
import UserNotifications
@preconcurrency import GRDB

// MARK: - NotificationService
//
// Owns the OS side of Phase 7 local notifications. Auth-owned (created by
// `AuthService`, like `SyncService`) and injected into the view tree via
// `.environmentObject`. The pure scheduling decisions live in
// `NotificationPlanner`; this type only:
//   • requests / refreshes the OS authorization status,
//   • reconciles the OS pending-notification set against the planner's
//     desired set (idempotent add/remove diff by identifier),
//   • clears everything on sign-out.
//
// No background execution: `reconcile` is called while the app is foregrounded
// (scenePhase active, tab switches, after a pref change). Nothing here writes
// to the DB. See docs/NOTIFICATIONS.md.

@MainActor
final class NotificationService: ObservableObject {

    /// Latest OS authorization status, refreshed on app-active and after a
    /// permission request. Drives the settings UI's denied / not-determined
    /// affordances.
    @Published private(set) var authorizationStatus: UNAuthorizationStatus = .notDetermined

    private let center = UNUserNotificationCenter.current()

    // Reconcile reentrancy guard — scenePhase, tab-switch, and pref-change
    // triggers can stack; we never run two reconciles concurrently, but a
    // request that arrives mid-run schedules exactly one re-run afterward so
    // the final state always reflects the latest data.
    private var isReconciling = false
    private var rerunRequested = false

    // MARK: - Authorization

    /// Requests notification permission (alert + sound + badge). Returns
    /// whether it was granted. The in-context priming UI is the caller's
    /// responsibility — this only invokes the system prompt.
    @discardableResult
    func requestAuthorization() async -> Bool {
        let granted = (try? await center.requestAuthorization(options: [.alert, .sound, .badge])) ?? false
        await refreshAuthorizationStatus()
        return granted
    }

    /// Re-reads the current OS authorization status into `authorizationStatus`.
    func refreshAuthorizationStatus() async {
        let settings = await center.notificationSettings()
        authorizationStatus = settings.authorizationStatus
    }

    /// Whether the current status permits delivering notifications.
    private var isAuthorized: Bool {
        authorizationStatus == .authorized || authorizationStatus == .provisional
    }

    // MARK: - Reconcile

    /// Brings the OS pending-notification set in line with the planner's
    /// desired set for `userId`. Safe to call frequently — it's an idempotent
    /// diff. When notifications are off (master pref) or unauthorized, the
    /// desired set is empty, so this also doubles as the cleanup path.
    func reconcile(userId: String) async {
        if isReconciling {
            rerunRequested = true
            return
        }
        isReconciling = true
        repeat {
            rerunRequested = false
            await performReconcile(userId: userId)
        } while rerunRequested
        isReconciling = false
    }

    private func performReconcile(userId: String) async {
        await refreshAuthorizationStatus()

        // Read prefs + boards in one consistent snapshot. The read closure
        // runs on GRDB's serial reader queue (not the main actor), so the DB
        // work itself doesn't block main.
        let snapshot: (prefs: UserPreferences, boards: [Board])? = try? await AppDatabase.shared.read { db in
            let prefs = try User.fetchOne(db, key: userId)?.decodedPreferences ?? .defaults
            let boards = try Board
                .filter(Column("userId") == userId && Column("isDeleted") == false)
                .fetchAll(db)
            return (prefs, boards)
        }
        guard let snapshot else { return }

        // Capture `now` once so the plan is internally consistent.
        let desired: [PlannedNotification] = isAuthorized
            ? NotificationPlanner.desiredNotifications(
                boards: snapshot.boards, prefs: snapshot.prefs, now: Date()
              )
            : []

        let pending = await center.pendingNotificationRequests()
        let pendingIds = Set(pending.map { $0.identifier })
        let desiredIds = Set(desired.map { $0.identifier })

        // Every pending request the app holds is one we scheduled, so removing
        // (pending − desired) is safe and never touches a foreign notification.
        let toRemove = pendingIds.subtracting(desiredIds)
        if !toRemove.isEmpty {
            center.removePendingNotificationRequests(withIdentifiers: Array(toRemove))
        }

        // Re-adding by identifier replaces in place, so adding the full desired
        // set is idempotent (≤54 items — well under the OS cap).
        for planned in desired {
            try? await center.add(makeRequest(planned))
        }
    }

    /// Maps a `PlannedNotification` to a concrete `UNNotificationRequest`.
    private func makeRequest(_ planned: PlannedNotification) -> UNNotificationRequest {
        let content = UNMutableNotificationContent()
        content.title = planned.title
        content.body = planned.body
        content.sound = .default
        content.userInfo = planned.userInfo

        let trigger: UNNotificationTrigger
        switch planned.trigger {
        case .calendar(let date):
            let comps = Calendar.current.dateComponents(
                [.year, .month, .day, .hour, .minute], from: date
            )
            trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: false)
        case .dailyTime(let hour, let minute):
            var comps = DateComponents()
            comps.hour = hour
            comps.minute = minute
            trigger = UNCalendarNotificationTrigger(dateMatching: comps, repeats: true)
        }

        return UNNotificationRequest(
            identifier: planned.identifier, content: content, trigger: trigger
        )
    }

    // MARK: - Teardown

    /// Cancels every scheduled + delivered notification. Called on sign-out so
    /// one account's reminders never linger into another's session.
    func clearAll() {
        center.removeAllPendingNotificationRequests()
        center.removeAllDeliveredNotifications()
    }
}
