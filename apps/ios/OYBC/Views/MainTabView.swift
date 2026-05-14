import SwiftUI

/// MainTabView - Root tab bar for authenticated users.
///
/// Four tabs:
/// - Boards: browse and manage the user's bingo boards.
/// - Tasks: dedicated library surface — filter / sort / search / detail.
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
    @State private var tasksPath: NavigationPath = NavigationPath()
    /// Phase 6.1: when the user taps Create on the Boards-tab Recurring
    /// Boards banner, BoardListView calls back here to (a) switch to the
    /// Create tab and (b) stash the timeframe. CreateHubView reads this
    /// on appear, enters wizard mode with the timeframe prefilled, and
    /// resets the binding to nil so a wizard cancel + manual re-entry
    /// doesn't re-arm the prefill.
    @State private var pendingRecurringTimeframe: Timeframe? = nil

    /// Phase 6.2 UX rework: cross-tab edit deep-link from the Profile
    /// → Recurring templates page. RecurringTemplatesView writes the
    /// template id and switches `selectedTab` to Create; CreateHubView
    /// fetches + hydrates the wizard in template-edit mode, then clears
    /// the binding. Same pattern as `pendingRecurringTimeframe`.
    @State private var pendingEditTemplateId: String? = nil

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
                BoardListView(
                    onCreateRecurring: { timeframe in
                        // Cross-tab: stash the timeframe and switch to
                        // the Create tab. CreateHubView reads
                        // `pendingRecurringTimeframe` on appear and
                        // enters wizard mode with prefill.
                        pendingRecurringTimeframe = timeframe
                        selectedTab = 2
                    }
                )
                .navigationDestination(for: String.self) { boardId in
                    BoardPlayView(boardId: boardId)
                }
            }
            .tabItem {
                Label("Boards", systemImage: "square.grid.3x3")
            }
            .tag(0)

            NavigationStack(path: $tasksPath) {
                if let userId = authService.currentUser?.id {
                    TasksTabView(userId: userId, path: $tasksPath)
                }
            }
            .tabItem {
                Label("Tasks", systemImage: "list.bullet")
            }
            .tag(1)

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
                            pendingRecurringTimeframe: $pendingRecurringTimeframe,
                            pendingEditTemplateId: $pendingEditTemplateId,
                            onBoardCompleted: { boardId, _ in
                                // Match web: after activate OR save-draft,
                                // the user lands on the board they just
                                // created. Reset the Boards stack first
                                // so the new board is the only thing on
                                // top of the list.
                                boardsPath = NavigationPath()
                                boardsPath.append(boardId)
                                selectedTab = 0
                            },
                            onTemplateCompleted: { _ in
                                // Phase 6.2: recurring-template completions
                                // without a spawned board (skip OR edit) —
                                // route the user to the Profile tab so they
                                // land near the templates list.
                                selectedTab = 3
                            }
                        )
                    }
                }
            }
            .tabItem {
                Label("Create", systemImage: "plus.circle")
            }
            .tag(2)

            NavigationStack {
                ProfileView(
                    onEditRecurringTemplate: { templateId in
                        // Phase 6.2 UX rework: cross-tab edit. The
                        // Profile tab's RecurringTemplatesView wires
                        // its row Edit buttons here; we stash the id
                        // and switch to Create. CreateHubView consumes
                        // the binding and opens the wizard hydrated.
                        pendingEditTemplateId = templateId
                        selectedTab = 2
                    }
                )
            }
            .tabItem {
                Label("Profile", systemImage: "person.circle")
            }
            .tag(3)
        }
        .preferredColorScheme(forcedColorScheme)
    }
}

#Preview {
    MainTabView()
        .environmentObject(AuthService())
}
