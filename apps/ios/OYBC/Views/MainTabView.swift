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
struct MainTabView: View {
    var body: some View {
        TabView {
            NavigationStack {
                BoardListView()
            }
            .tabItem {
                Label("Boards", systemImage: "square.grid.3x3")
            }

            NavigationStack {
                CreateView()
            }
            .tabItem {
                Label("Create", systemImage: "plus.circle")
            }

            NavigationStack {
                ProfileView()
            }
            .tabItem {
                Label("Profile", systemImage: "person.circle")
            }
        }
    }
}

#Preview {
    MainTabView()
        .environmentObject(AuthService())
}
