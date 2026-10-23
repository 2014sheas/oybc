import SwiftUI

// MARK: - Injected database (environment)

private struct AppDatabaseKey: EnvironmentKey {
    static var defaultValue: AppDatabase { .shared }
}

extension EnvironmentValues {
    /// The database the hosting screen reads and writes — `AppDatabase.shared`
    /// in the app; a test or preview host can inject another. Leaf views that
    /// build their view-models as `@State` (before an init parameter could
    /// reach them) read this instead of reaching for the singleton (ROADMAP B3).
    var appDatabase: AppDatabase {
        get { self[AppDatabaseKey.self] }
        set { self[AppDatabaseKey.self] = newValue }
    }
}
