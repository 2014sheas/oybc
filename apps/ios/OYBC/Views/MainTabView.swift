import SwiftUI

/// MainTabView - Root tab bar for authenticated users.
///
/// Three tabs:
/// - Boards: browse and manage the user's bingo boards.
/// - Create: build tasks, assemble a pool, and generate a new board.
/// - Profile: account settings, app configuration, and sign-out.
///
/// Each tab wraps its root view in a `NavigationStack` so tabs maintain
/// independent navigation stacks and title bars.
///
/// **Cross-tab navigation**: after the Create-tab wizard finishes, we
/// jump the user directly to the board they just created — same UX as
/// web's post-activation `navigate('/boards/<id>')`. Implemented via a
/// `selectedTab` binding + a `NavigationPath` on the Boards tab that
/// `CreateHubView.onBoardCompleted` pushes the new board id into.
struct MainTabView: View {
    @EnvironmentObject var authService: AuthService

    @State private var selectedTab: Int = 0
    @State private var boardsPath: NavigationPath = NavigationPath()

    /// Resolves `preferences.theme` into the SwiftUI `preferredColorScheme`
    /// value. `system` returns `nil`, which yields OS appearance; any other
    /// value forces a specific scheme across the whole tab tree.
    private var forcedColorScheme: ColorScheme? {
        switch authService.userPreferences.theme {
        case .light: return .light
        case .dark: return .dark
        case .system: return nil
        }
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $boardsPath) {
                BoardListView()
                    .navigationDestination(for: String.self) { boardId in
                        BoardPlayView(boardId: boardId)
                    }
            }
            .tabItem {
                Label("Boards", systemImage: "square.grid.3x3")
            }
            .tag(0)

            NavigationStack {
                ScrollView {
                    if let userId = authService.currentUser?.id {
                        // No outer padding here — `CreateHubView` pads its
                        // hub content internally, and the wizard's step
                        // views each apply their own `.padding(16)`.
                        // Wrapping at this level would double-pad the
                        // wizard and visibly shrink its task rows
                        // (~22% of screen width lost on iPhone-class
                        // widths before this was removed).
                        CreateHubView(
                            userId: userId,
                            preferences: authService.userPreferences,
                            onBoardCompleted: { boardId, _ in
                                // Match web: after activate OR save-draft,
                                // the user lands on the board they just
                                // created. Reset the Boards stack first
                                // so the new board is the only thing on
                                // top of the list.
                                boardsPath = NavigationPath()
                                boardsPath.append(boardId)
                                selectedTab = 0
                            }
                        )
                    }
                }
            }
            .tabItem {
                Label("Create", systemImage: "plus.circle")
            }
            .tag(1)

            NavigationStack {
                ProfileView()
            }
            .tabItem {
                Label("Profile", systemImage: "person.circle")
            }
            .tag(2)
        }
        .preferredColorScheme(forcedColorScheme)
    }
}

#Preview {
    MainTabView()
        .environmentObject(AuthService())
}
