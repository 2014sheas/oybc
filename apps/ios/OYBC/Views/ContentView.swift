import SwiftUI

/// ContentView - Application root.
///
/// Wraps all content behind `AuthGateView`, which resolves the Firebase auth
/// state before rendering. Authenticated users land on `MainTabView`; unauthenticated
/// users see the login form.
///
/// Debug-only screenshot harnesses (gated by launch args, never compiled in Release)
/// short-circuit the auth gate to mount a specific view in isolation — see the
/// `-previewCompositeBuild` branch below.
struct ContentView: View {
    var body: some View {
        // CompositeBuildPreviewHarness + BoardWizardTasksPreviewHarness were
        // gated post-compound-tasks-unification (their mock fixtures used
        // legacy CompositeTask / CompositeNode / TaskStep types). Phase 8
        // will rebuild and re-enable the `-previewCompositeBuild` and
        // `-previewBoardTasks` launch args.
        AuthGateView {
            MainTabView()
        }
    }
}

#Preview {
    ContentView()
}
