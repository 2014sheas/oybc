import SwiftUI

/// ContentView - Application root.
///
/// Wraps all content behind `AuthGateView`, which resolves the Firebase auth
/// state before rendering. Authenticated users land on `MainTabView`; unauthenticated
/// users see the login form.
///
/// The pre-unification debug screenshot harnesses (`CompositeBuildPreview`,
/// `BoardWizardTasksPreview`) were dropped in Phase 8 — their fixtures
/// consumed retired CompositeTask / CompositeNode / TaskStep shapes. The
/// snapshot test target (`OYBCSnapshotTests`) is the new visual-verification
/// surface.
struct ContentView: View {
    var body: some View {
        AuthGateView {
            MainTabView()
        }
    }
}

#Preview {
    ContentView()
}
