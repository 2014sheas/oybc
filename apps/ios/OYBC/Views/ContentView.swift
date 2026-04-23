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
        #if DEBUG
        if ProcessInfo.processInfo.arguments.contains("-previewCompositeBuild") {
            // Mount the composite wizard's Build step directly with mock
            // data so we can screenshot layout/density changes without
            // driving the full wizard flow.
            //
            // Launch:
            //   xcrun simctl launch <device> com.oybc.OYBC -previewCompositeBuild YES
            CompositeBuildPreviewHarness()
        } else {
            AuthGateView {
                MainTabView()
            }
        }
        #else
        AuthGateView {
            MainTabView()
        }
        #endif
    }
}

#Preview {
    ContentView()
}
