import SwiftUI

/// ContentView - Application root.
///
/// On first launch, shows `OnboardingView` (three intro slides + sign-in panel).
/// Once the user has completed or skipped onboarding — or on every subsequent
/// launch — falls through to `AuthGateView`, which resolves the Firebase auth
/// state before rendering. Authenticated users land on `MainTabView`;
/// unauthenticated users see the login form.
///
/// First-run gate: `UserDefaults.hasSeenOnboarding` (key `oybc-onboarding-seen`).
/// Onboarding sets this to `true` on any dismiss path (sign-in, skip,
/// Maybe later). Developers can reset it via a "Replay onboarding" tweak
/// in ProfileView.
///
/// The pre-unification debug screenshot harnesses (`CompositeBuildPreview`,
/// `BoardWizardTasksPreview`) were dropped in Phase 8 — their fixtures
/// consumed retired CompositeTask / CompositeNode / TaskStep shapes. The
/// snapshot test target (`OYBCSnapshotTests`) is the new visual-verification
/// surface.
struct ContentView: View {

    /// Shared auth service — owned here so both `AuthGateView` and
    /// `OnboardingView` hold a reference to the same instance. The notif-
    /// priming step in `OnboardingView` (Phase 7) needs to write to
    /// `UserPreferences` and call `notificationService.reconcile` on behalf
    /// of the freshly-signed-in user; that requires the same `AuthService`
    /// instance that Firebase's auth-state listener has bootstrapped.
    @StateObject private var authService = AuthService()

    /// Whether the onboarding overlay is still visible. Initialised from
    /// `UserDefaults.hasSeenOnboarding` so it's false for returning users
    /// and true for first-run users.
    @State private var showOnboarding: Bool = !UserDefaults.hasSeenOnboarding

    var body: some View {
        ZStack {
            AuthGateView(authService: authService) {
                MainTabView()
            }

            if showOnboarding {
                OnboardingView(authService: authService) {
                    // Mark onboarding complete and remove the overlay.
                    UserDefaults.hasSeenOnboarding = true
                    withAnimation(.easeInOut(duration: 0.35)) {
                        showOnboarding = false
                    }
                }
                .zIndex(1)
                .transition(.opacity)
            }
        }
        .animation(.easeInOut(duration: 0.35), value: showOnboarding)
    }
}

#Preview {
    ContentView()
}
