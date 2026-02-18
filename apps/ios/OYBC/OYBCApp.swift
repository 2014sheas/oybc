import SwiftUI

/// Main app entry point for OYBC iOS app
@main
struct OYBCApp: App {
    /// Initialize database synchronously before the UI appears.
    ///
    /// Running migration during init() means it completes during the launch screen,
    /// before any interactive UI is shown. This avoids I/O contention while the
    /// user is interacting with the app (e.g. tapping a TextField / showing keyboard).
    init() {
        _ = AppDatabase.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
