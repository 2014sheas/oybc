import SwiftUI
import FirebaseCore

/// Main app entry point for OYBC iOS app
@main
struct OYBCApp: App {
    /// Initialize database and Firebase synchronously before the UI appears.
    ///
    /// Database migration runs first so the local store is ready before any
    /// Firebase auth state callbacks fire. Both complete during the launch
    /// screen before any interactive UI is shown.
    init() {
        _ = AppDatabase.shared

        // Skip Firebase bootstrap under XCTest. The test host embeds this
        // App struct, but `FirebaseApp.configure()` fatals-out on missing
        // `GoogleService-Info.plist` — which is gitignored and absent in
        // CI. Production and local simulator runs still configure
        // normally. Detected via XCTest's own env var rather than a
        // `#if TEST` build flag so test targets don't need a custom
        // configuration.
        if ProcessInfo.processInfo.environment["XCTestConfigurationFilePath"] == nil {
            FirebaseApp.configure()
        }
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
