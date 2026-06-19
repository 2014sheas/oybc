import Foundation
import UserNotifications

// MARK: - NotificationDeepLink

/// Where a notification tap should route. Carried from the notification's
/// `userInfo` through to the tab tree. A nil `boardId` means "just open the
/// Boards tab" (recurring-window / daily-reminder taps).
struct NotificationDeepLink: Equatable {
    let boardId: String?
}

// MARK: - NotificationDelegate

/// App-lifetime `UNUserNotificationCenterDelegate`. Registered in
/// `OYBCApp.init()` — NOT lazily after auth — because the system dispatches a
/// cold-launch-from-tap notification very early, before Firebase resolves the
/// auth state. A late-registered delegate would miss that `didReceive`.
///
/// Its only job is to BUFFER the tapped target into `pendingDeepLink`; the
/// auth-owned UI (`MainTabView`) drains it once signed-in and the tab tree
/// exists. It has no auth/DB dependency by design, so it can safely outlive
/// sign-in/out cycles.
///
/// See docs/NOTIFICATIONS.md.
final class NotificationDelegate: NSObject, UNUserNotificationCenterDelegate, ObservableObject {

    /// Shared instance — there is exactly one notification delegate per app.
    static let shared = NotificationDelegate()

    /// Set when the user taps a notification; observed + cleared by the UI.
    @Published var pendingDeepLink: NotificationDeepLink?

    private override init() { super.init() }

    /// Installs `self` as the notification-center delegate. Call once, at app
    /// launch, before any auth work.
    func register() {
        UNUserNotificationCenter.current().delegate = self
    }

    // MARK: - UNUserNotificationCenterDelegate

    /// Present the banner (and play the sound) even while the app is
    /// foregrounded — otherwise an active-app reminder would be silently
    /// swallowed.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        willPresent notification: UNNotification
    ) async -> UNNotificationPresentationOptions {
        [.banner, .sound]
    }

    /// Buffer the tap target. Routing happens in the UI layer once it's ready.
    func userNotificationCenter(
        _ center: UNUserNotificationCenter,
        didReceive response: UNNotificationResponse
    ) async {
        let info = response.notification.request.content.userInfo
        let boardId = info["boardId"] as? String
        await MainActor.run {
            self.pendingDeepLink = NotificationDeepLink(boardId: boardId)
        }
    }
}
