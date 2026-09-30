import SwiftUI

/// ProfileView — the Profile-home screen (Profile reorg PR2, design handoff
/// `design_handoff_profile_reorg/README.md` §1). Everything touched rarely
/// moved to `SettingsView` (pushed from the gear button, PR1); this screen
/// is left with the two jobs the owner ranked highest — Board settings and
/// Shared counters — plus the Streak tile and the Getting Started
/// onboarding surface.
///
/// Layout (top to bottom, matches the handoff's frame `#4a` / day-one `#4e`):
/// 1. Identity header (avatar/name/email + trailing gear → Settings).
/// 2. Day-one hero (`completedCount == 0`) — ABOVE the tiles, replaces the row.
/// 3. Two tiles — Board settings / Streak (or its empty "no bingo yet" state).
/// 4. Getting Started row (`0 < completedCount < 8`) — BELOW the tiles.
/// 5. Shared counters — up to 2 most-recently-logged counters + "All N ›".
///
/// Container stays thin: identity/tutorial state comes straight from
/// `AuthService`/`TutorialProgressStore` (env objects), DB-backed state
/// (streaks, repeating-board count, counters) comes from the injected
/// `ProfileHomeViewModel`. All visual pieces are their own files under
/// `Components/` so this body stays a thin composition, not a monolith.
struct ProfileView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var tutorialStore: TutorialProgressStore

    // MARK: - Inputs

    /// Opens the Getting Started tutorial board (cross-tab to Boards).
    /// Optional so #Preview / tests can mount ProfileView standalone.
    var onOpenTutorial: (() -> Void)? = nil
    /// Cross-tab: open a board from a Profile sub-page (Counters hub →
    /// Counter detail → member card). Routed by `MainTabView.openBoard`, so
    /// a core board lands in its pager window. Optional like
    /// `onOpenTutorial` (previews / snapshots compose the view bare);
    /// MainTabView always wires it.
    var onOpenBoard: ((String) -> Void)? = nil

    // MARK: - Private state

    @StateObject private var vm = ProfileHomeViewModel()
    @State private var showEditProfile = false

    /// Counters-hub / counter-detail navigation, owned locally (the "All N ›"
    /// link and a compact row's tap aren't `ProfileRoute` cases — they carry
    /// the `onOpenBoard` cross-tab closure, same reason the pre-reorg
    /// ProfileView pushed `CountersHubView` via a plain `NavigationLink`
    /// rather than a route value).
    @State private var showCountersHub = false
    @State private var navigateToCounterId: String? = nil
    @State private var showNewCounterSheet = false
    @State private var logError: String?

    // MARK: - Derived

    private var displayName: String {
        authService.currentUser?.displayName ?? "OYBC User"
    }

    /// `nil` for both a signed-out edge case and a guest session — a Firebase
    /// anonymous user's local `User.email` is always `""`, never a real
    /// address (docs/GUEST_MODE.md §Phase 3: "empty string must render Guest").
    private var email: String? {
        guard let raw = authService.currentUser?.email, !raw.isEmpty else { return nil }
        return raw
    }

    private var isGuest: Bool { authService.isAnonymous }
    private var preferences: UserPreferences { authService.userPreferences }

    private var boardSettingsSummary: ProfileHomeViewModel.BoardSettingsTileSummary {
        ProfileHomeViewModel.boardSettingsTileSummary(
            defaultBoardSize: preferences.defaultBoardSize,
            centerType: preferences.defaultCenterType,
            weekStartDay: preferences.weekStartDay,
            repeatingCount: vm.repeatingBoardsCount
        )
    }

    private var gettingStartedDisplay: ProfileHomeViewModel.GettingStartedDisplay {
        ProfileHomeViewModel.gettingStartedDisplay(
            completedCount: tutorialStore.completedCount,
            isComplete: tutorialStore.isComplete
        )
    }

    private var nextLessonTitle: String? {
        nextIncompleteLessonTitle(completedIDs: tutorialStore.completedLessonIDs)
    }

    // MARK: - Body

    var body: some View {
        ZStack {
            RisoPaperBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    identityRow
                        .padding(.horizontal, Riso.gutter)
                        .padding(.top, 16)
                        .padding(.bottom, 18)

                    if gettingStartedDisplay == .dayOneHero {
                        RisoGettingStartedHero(
                            done: tutorialStore.completedCount,
                            total: TutorialProgressStore.totalLessons,
                            onStart: { onOpenTutorial?() }
                        )
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 18)
                    }

                    tilesRow
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 18)

                    if gettingStartedDisplay == .row {
                        gettingStartedRow
                            .padding(.horizontal, Riso.gutter)
                            .padding(.bottom, 18)
                    }

                    ProfileCountersSection(
                        groups: vm.recentCounters,
                        totalCount: vm.totalCounterCount,
                        loggingCounterIds: vm.loggingCounterIds,
                        onOpenHub: { showCountersHub = true },
                        onOpenDetail: { counterId in navigateToCounterId = counterId },
                        onNewCounter: { showNewCounterSheet = true },
                        onLog: { group in handleLog(group) }
                    )
                    .padding(.bottom, 32)
                }
            }
        }
        .navigationBarHidden(true)
        .navigationDestination(isPresented: $showCountersHub) {
            CountersHubView(onOpenBoard: onOpenBoard ?? { _ in })
        }
        .navigationDestination(item: $navigateToCounterId) { counterId in
            CounterDetailView(counterId: counterId, onOpenBoard: onOpenBoard ?? { _ in })
        }
        .sheet(isPresented: $showEditProfile) {
            EditProfileSheet(
                displayName: displayName,
                email: email,
                isGuest: isGuest,
                updateName: { name in
                    try await authService.updateDisplayName(name)
                },
                onSave: { showEditProfile = false },
                onCancel: { showEditProfile = false }
            )
        }
        .sheet(isPresented: $showNewCounterSheet, onDismiss: reload) {
            if let userId = authService.currentUser?.id {
                NewCounterSheetView(
                    userId: userId,
                    tasks: vm.counterDedupeTasks,
                    onNavigateToCounter: { _ in
                        showNewCounterSheet = false
                        showCountersHub = true
                    }
                )
            }
        }
        .alert(
            "Counter not updated",
            isPresented: Binding(get: { logError != nil }, set: { if !$0 { logError = nil } }),
            presenting: logError
        ) { _ in
            Button("OK", role: .cancel) { logError = nil }
        } message: { message in
            Text(message)
        }
        .onAppear { reload() }
    }

    // MARK: - Identity row (avatar/name/email + gear → Settings)

    private var identityRow: some View {
        HStack(alignment: .center, spacing: 12) {
            RisoProfileIdentityHeader(
                displayName: displayName,
                email: email,
                isGuest: isGuest,
                onEditName: { showEditProfile = true }
            )

            NavigationLink(value: ProfileRoute.settings) {
                gearButton
            }
            .buttonStyle(RisoButtonStyle(offset: Riso.Shadow.small))
            .accessibilityLabel("Settings")
        }
    }

    /// 40×40 paper-2 keyline square with a `gearshape` glyph — matches
    /// `RisoSubPageHeader`'s back-button metrics exactly (2pt ink border,
    /// 7pt radius).
    private var gearButton: some View {
        Image(systemName: "gearshape")
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(Color.risoInk)
            .frame(width: 40, height: 40)
            .risoCard(fill: .risoPaper2)
            // 40pt visual square, 44pt touch target (HIG minimum): the
            // content shape is laid on a 44pt frame, then the negative
            // padding gives the 40pt layout back so the button style's
            // hard shadow still traces the card.
            .padding(2)
            .contentShape(Rectangle())
            .padding(-2)
    }

    // MARK: - Tiles row (Board settings / Streak)

    private var tilesRow: some View {
        HStack(spacing: 12) {
            NavigationLink(value: ProfileRoute.boardSettings) {
                RisoProfileTile {
                    ProfileBoardSettingsTileContent(
                        defaultsLine: boardSettingsSummary.defaultsLine,
                        repeatingLine: boardSettingsSummary.repeatingLine
                    )
                }
            }
            .buttonStyle(RisoProfileTileButtonStyle())

            NavigationLink(value: ProfileRoute.streaks) {
                if vm.streak.bingoStreak > 0 {
                    RisoProfileTile(fill: .risoGold) {
                        ProfileStreakTileContent(
                            bingoStreak: vm.streak.bingoStreak,
                            longestStreak: vm.streak.longestStreak,
                            greenlogCount: vm.streak.greenlogCount
                        )
                    }
                } else {
                    RisoProfileTile(dashed: true) { ProfileEmptyStreakTileContent() }
                }
            }
            .buttonStyle(RisoProfileTileButtonStyle(offset: vm.streak.bingoStreak > 0 ? Riso.Shadow.card : nil))
        }
    }

    // MARK: - Getting started row (0 < completedCount < 8)

    private var gettingStartedRow: some View {
        Button { onOpenTutorial?() } label: {
            RisoProfileRow(
                icon: "checkmark.circle",
                label: "Getting started",
                caption: nextLessonTitle.map { "Next: \($0)" },
                value: "\(tutorialStore.completedCount)/\(TutorialProgressStore.totalLessons)",
                chevron: true
            )
        }
        .buttonStyle(.plain)
        .risoCard()
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
    }

    // MARK: - "+ Log" pill

    private func handleLog(_ group: SharedCounterGroup) {
        guard let userId = authService.currentUser?.id else { return }
        vm.handleLog(
            group: group,
            userId: userId,
            weekStartDay: preferences.weekStartDay.rawValue,
            onError: { message in logError = message }
        )
    }

    // MARK: - Loading

    private func reload() {
        guard let userId = authService.currentUser?.id else { return }
        vm.load(userId: userId, weekStartDay: preferences.weekStartDay.rawValue)
    }
}

#Preview {
    let authService = AuthService()
    return NavigationStack {
        ProfileView()
            .environmentObject(authService)
            .environmentObject(authService.syncService)
            .environmentObject(TutorialProgressStore())
            .environmentObject(NetworkMonitor())
    }
}
