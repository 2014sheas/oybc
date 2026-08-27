import SwiftUI
import FirebaseCore

/// Main app entry point for OYBC iOS app
@main
struct OYBCApp: App {
    /// True when the XCTest framework is loaded in the current process.
    /// iOS tests are hosted by the app target, so `OYBCApp.init` and
    /// `OYBCApp.body` both run during test bootstrap. We need to short
    /// out everything production does so the test bundle can launch
    /// cleanly without `GoogleService-Info.plist` or a writable
    /// application-support directory.
    ///
    /// `NSClassFromString("XCTest")` is a stricter detector than
    /// `XCTestConfigurationFilePath` — it checks the actual framework
    /// load, which is only true under `xcodebuild test`.
    private static let isRunningTests = NSClassFromString("XCTest") != nil

    /// Initialize database and Firebase synchronously before the UI appears.
    ///
    /// Database migration runs first so the local store is ready before any
    /// Firebase auth state callbacks fire. Both complete during the launch
    /// screen before any interactive UI is shown.
    ///
    /// Skipped entirely under XCTest: `FirebaseApp.configure()` fatalErrors
    /// on missing `GoogleService-Info.plist` (gitignored, absent in CI),
    /// and the shared AppDatabase singleton isn't used by tests anyway —
    /// they call `AppDatabase.makeTestInstance()` for isolated DBs.
    init() {
        guard !Self.isRunningTests else { return }

        _ = AppDatabase.shared
        FirebaseApp.configure()
        EntitlementService.configureRevenueCat()

        // Register the notification delegate synchronously at launch (NOT
        // lazily after auth) so a cold-launch-from-tap is captured before
        // Firebase resolves the auth state. See NotificationDelegate.
        NotificationDelegate.shared.register()
    }

    var body: some Scene {
        WindowGroup {
            // The test host bootstraps the full App struct — that includes
            // evaluating `body` and constructing the root view. Our
            // `ContentView → AuthGateView → @StateObject AuthService() →
            // SyncService` chain eagerly calls `Firestore.firestore()` as a
            // stored-property default, which throws FIRIllegalStateException
            // without a prior `FirebaseApp.configure()` (which `init`
            // deliberately skips under tests).
            //
            // Short-circuit to an inert view under XCTest so the view tree
            // never touches Firestore. Tests run against in-memory
            // `AppDatabase.makeTestInstance()` instances and don't need
            // any of the production singletons.
            if Self.isRunningTests {
                EmptyView()
            } else {
                ContentView()
            }
        }
    }
}
