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
    @EnvironmentObject var notificationService: NotificationService
    @EnvironmentObject var notificationDelegate: NotificationDelegate
    @Environment(\.scenePhase) private var scenePhase

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

    /// Phase B: paired with `pendingRecurringTimeframe`. Non-nil when
    /// the core-board browser launched the wizard for a non-current
    /// window (e.g. tomorrow's daily). CreateHubView reads + clears
    /// both on the same `.onAppear` and threads the date into
    /// `BoardWizardView.targetWindowDate`. Stays nil for the legacy
    /// banner-click path (today's window).
    @State private var pendingTargetWindowDate: Date? = nil

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

    /// Cross-tab navigation: jump to a specific board. Used by Tasks-tab
    /// detail Usage section ("tap a board name → go there") and by the
    /// task-detail sheet over BoardPlayView (board-to-board jump).
    /// Resets boardsPath to a single entry so the user lands on a clean
    /// stack — same intent as `onBoardCompleted` from the wizard.
    private func openBoard(_ boardId: String) {
        boardsPath = NavigationPath()
        boardsPath.append(boardId)
        selectedTab = 0
    }

    var body: some View {
        TabView(selection: $selectedTab) {
            NavigationStack(path: $boardsPath) {
                BoardListView(
                    onCreateForWindow: { timeframe, windowDate in
                        // Cross-tab: the browser's Create-cell taps
                        // land here so the wizard launches with the
                        // picked window. Stash both bindings + flip
                        // to the Create tab; CreateHubView consumes
                        // both on appear.
                        pendingRecurringTimeframe = timeframe
                        pendingTargetWindowDate = windowDate
                        selectedTab = 2
                    },
                    onBrowseTimeframe: { timeframe in
                        // Push the per-timeframe Core Board Browser
                        // onto the Boards-tab stack. Used by both the
                        // Core Boards section (whole-row tap) and the
                        // pending-recurring banner if it re-enables.
                        boardsPath.append(CoreBrowserRoute(timeframe: timeframe))
                    },
                    onOpenCoreWindow: { timeframe, windowStart in
                        // Core board row tap → per-window pager.
                        boardsPath.append(CoreWindowRoute(timeframe: timeframe, windowStart: windowStart))
                    },
                    onCreateBoard: {
                        // Riso header + button tapped: switch to Create
                        // tab with no pre-fill (fresh board flow).
                        selectedTab = 2
                    }
                )
                .navigationDestination(for: CoreBrowserRoute.self) { route in
                    CoreBoardBrowserView(
                        timeframe: route.timeframe,
                        onCreate: { tf, date in
                            pendingRecurringTimeframe = tf
                            pendingTargetWindowDate = date
                            selectedTab = 2
                        },
                        onOpenBoard: { boardId in
                            // Push the board onto the same Boards-tab
                            // stack so back returns to the browser,
                            // not the list.
                            boardsPath.append(boardId)
                        }
                    )
                }
                .navigationDestination(for: CoreWindowRoute.self) { route in
                    // Per-window core-board pager. Prev/next page by
                    // mutating the VM in place, so no .id() is needed
                    // on this destination.
                    CoreBoardWindowView(
                        timeframe: route.timeframe,
                        seedWindowStart: route.windowStart,
                        userId: authService.currentUser?.id ?? "",
                        weekStartDay: authService.userPreferences.weekStartDay.rawValue,
                        onCreateForWindow: { tf, date in
                            pendingRecurringTimeframe = tf
                            pendingTargetWindowDate = date
                            selectedTab = 2
                        },
                        onBrowseTimeframe: { tf in
                            boardsPath.append(CoreBrowserRoute(timeframe: tf))
                        },
                        onOpenBoard: { boardId in
                            boardsPath.append(boardId)
                        }
                    )
                }
                .navigationDestination(for: String.self) { boardId in
                    BoardPlayView(
                        boardId: boardId,
                        onOpenBoard: { newId in openBoard(newId) }
                    )
                    // Force a fresh view identity per boardId. Without
                    // this, NavigationStack reuses the same BoardPlayView
                    // when boardsPath swaps from [A] to [B], keeping all
                    // @State (board, boardTasks, etc.) and never firing
                    // .onAppear — so the user sees the original board's
                    // data after a cross-board jump from a Task detail
                    // sheet's Usage section.
                    .id(boardId)
                }
            }
            .tabItem {
                Label("Boards", systemImage: "square.grid.3x3")
            }
            .tag(0)

            NavigationStack(path: $tasksPath) {
                if let userId = authService.currentUser?.id {
                    TasksTabView(
                        userId: userId,
                        path: $tasksPath,
                        onOpenBoard: { boardId in openBoard(boardId) }
                    )
                }
            }
            .tabItem {
                Label("Tasks", systemImage: "list.bullet")
            }
            .tag(1)

            NavigationStack {
                if let userId = authService.currentUser?.id {
                    // Mount CreateHubView directly (no outer ScrollView, no
                    // outer padding) — exactly like the other tabs' roots.
                    // The hub content and each wizard step provide their own
                    // scrolling + `.padding(16)`. An outer ScrollView here
                    // gave the hub's `RisoPaperBackground` unbounded height,
                    // so it collapsed to content height and the system white
                    // showed through below it; it also double-scrolled and
                    // shrank the wizard's task rows (~22% width on iPhone).
                    CreateHubView(
                            userId: userId,
                            preferences: authService.userPreferences,
                            pendingRecurringTimeframe: $pendingRecurringTimeframe,
                            pendingTargetWindowDate: $pendingTargetWindowDate,
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
                // Phase B — Browse links inside BoardPreferencesView
                // push CoreBrowserRoute onto this stack. Same view
                // tree as the Boards-tab browser; only the cross-tab
                // launch closure differs (Profile-tab pushes still
                // need to hop to the Create tab on a Create-cell tap).
                .navigationDestination(for: CoreBrowserRoute.self) { route in
                    CoreBoardBrowserView(
                        timeframe: route.timeframe,
                        onCreate: { tf, date in
                            pendingRecurringTimeframe = tf
                            pendingTargetWindowDate = date
                            selectedTab = 2
                        },
                        onOpenBoard: { boardId in
                            // Jump cross-tab to the Boards stack so
                            // the user lands on the play view.
                            openBoard(boardId)
                        }
                    )
                }

            }
            .tabItem {
                Label("Profile", systemImage: "person.circle")
            }
            .tag(3)
        }
        .preferredColorScheme(forcedColorScheme)
        // Phase 7 — reconcile the OS notification set whenever we have fresh
        // data: at launch, on every foreground, and on tab switches (which
        // catches a board just created on the Create tab). No background work.
        .task {
            await reconcileNotifications()
            routePendingDeepLink()
        }
        .onChange(of: scenePhase) { _, newPhase in
            guard newPhase == .active else { return }
            _Concurrency.Task { await reconcileNotifications() }
        }
        .onChange(of: selectedTab) { _, _ in
            _Concurrency.Task { await reconcileNotifications() }
        }
        .onChange(of: notificationDelegate.pendingDeepLink) { _, _ in
            routePendingDeepLink()
        }
    }

    /// Re-syncs scheduled local notifications with current local state.
    private func reconcileNotifications() async {
        guard let userId = authService.currentUser?.id else { return }
        await notificationService.reconcile(userId: userId)
    }

    /// Routes a buffered notification-tap target into the tab tree, then
    /// clears it. A board target deep-links to that board; anything else just
    /// surfaces the Boards tab.
    private func routePendingDeepLink() {
        guard let link = notificationDelegate.pendingDeepLink else { return }
        if let boardId = link.boardId {
            openBoard(boardId)
        } else {
            selectedTab = 0
        }
        notificationDelegate.pendingDeepLink = nil
    }
}

#Preview {
    MainTabView()
        .environmentObject(AuthService())
        .environmentObject(NotificationService())
        .environmentObject(NotificationDelegate.shared)
}
