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
        FirebaseApp.configure()
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
