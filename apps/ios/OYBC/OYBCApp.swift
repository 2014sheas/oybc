import SwiftUI

/// Main app entry point for OYBC iOS app
@main
struct OYBCApp: App {
    /// Initialize database on app launch
    init() {
        // Database initialization happens in AppDatabase singleton
        _ = AppDatabase.shared
    }

    var body: some Scene {
        WindowGroup {
            ContentView()
        }
    }
}
