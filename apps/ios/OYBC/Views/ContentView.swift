import SwiftUI

/// ContentView - Application root.
///
/// Wraps all content behind `AuthGateView`, which resolves the Firebase auth
/// state before rendering. Authenticated users land on `MainTabView`; unauthenticated
/// users see the login form.
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
