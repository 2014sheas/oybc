import SwiftUI

/// Owns the app-wide `TutorialCoordinator` for the signed-in user and injects it
/// as an environment object (replaces the device-local `TutorialProgressStore`
/// that `AuthGateView` used to create). Progress lives in the user's synced
/// preferences, so a change that arrives from another device flows in through
/// `.onChange` below.
struct TutorialScope<Content: View>: View {
    @ObservedObject var authService: AuthService
    @StateObject private var coach: TutorialCoordinator
    let content: () -> Content

    init(authService: AuthService, userId: String, content: @escaping () -> Content) {
        self.authService = authService
        self.content = content
        _coach = StateObject(wrappedValue: TutorialCoordinator(
            userId: userId,
            progress: authService.userPreferences.tutorialProgress
        ))
    }

    var body: some View {
        content()
            .environmentObject(coach)
            .onChange(of: authService.userPreferences.tutorialProgress) { _, remote in
                coach.refresh(from: remote)
            }
    }
}
