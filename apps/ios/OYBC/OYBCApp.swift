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
        // Skip ALL production bootstrap (AppDatabase.shared on-disk
        // initialisation, Firebase) when the process is a test host.
        // The test bundle embeds this App struct, but:
        //   • FirebaseApp.configure() fatalErrors on missing
        //     `GoogleService-Info.plist` (gitignored, absent in CI).
        //   • AppDatabase.shared tries to create an on-disk SQLite at
        //     ~/Library/Application Support/, which can surface its own
        //     sandbox / permission edge cases on the simulator.
        // Tests construct isolated resources via
        // `AppDatabase.makeTestInstance()` and never need the shared
        // singleton. So the safest CI stance is: the test host runs
        // exactly zero production-side init.
        //
        // Detection via `NSClassFromString("XCTest")` checks for the
        // XCTest framework actually being loaded in the process, which
        // is stricter than the env-var check — the framework is only
        // present under `xcodebuild test`, never under a normal app
        // launch (even a Debug one).
        let isRunningTests = NSClassFromString("XCTest") != nil
        guard !isRunningTests else { return }

        _ = AppDatabase.shared
        FirebaseApp.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
