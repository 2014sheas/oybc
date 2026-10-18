import FirebaseCrashlytics

/// Crash reporting policy (ROADMAP Track L0). Crashlytics is the only
/// diagnostics SDK in the app: no FirebaseAnalytics, no user id, no custom
/// keys or logs, so a report carries a stack trace and device / OS info only.
enum CrashReporting {
    /// Whether this build sends crash reports: `false` in DEBUG (developer
    /// builds and the hosted test suites must never report), `true` otherwise
    /// (TestFlight / App Store).
    static let isCollectionEnabled: Bool = {
        #if DEBUG
        return false
        #else
        return true
        #endif
    }()

    /// Applies ``isCollectionEnabled`` to Crashlytics. Call on every launch,
    /// right after `FirebaseApp.configure()`: Crashlytics persists the last
    /// value across launches, and a TestFlight install can replace a DEBUG
    /// install while keeping its container, so the stored flag cannot be trusted.
    static func configure() {
        Crashlytics.crashlytics().setCrashlyticsCollectionEnabled(isCollectionEnabled)
    }
}
