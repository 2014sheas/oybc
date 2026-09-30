import SwiftUI

/// ProfileView — Riso-styled account info + the jobs done most often
/// (streaks, Getting started, Board settings, Shared counters).
///
/// Profile reorg PR1: Theme, Notifications, Account & security, Help,
/// Sign Out, the version footer, and the DEV rows all moved to
/// `SettingsView`, pushed from the new gear button. Sync UI (`RisoSyncRow`
/// / `SyncSheet`) was deleted entirely, not relocated (owner decision,
/// `.superpowers/sdd/2026-09-30-profile-reorg/owner-decisions.md` #2).
/// PR2 rebuilds the rest of this screen (identity header, tiles, tutorial
/// hero, inline counters) — for now the account card / streaks card /
/// Getting started row / Board settings + Shared counters rows are
/// unchanged.
///
/// Layout (over `RisoPaperBackground`, scrolling VStack of `.risoCard()` sections):
/// 1. Header kicker + H1
/// 2. Identity row — account card + trailing gear button (→ Settings)
/// 3. Your streaks card
/// 4. Preferences section — Getting started / Board settings / Shared counters
struct ProfileView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var tutorialStore: TutorialProgressStore

    // MARK: - Inputs

    /// Opens the Getting Started tutorial board (cross-tab to Boards).
    /// Optional so #Preview / tests can mount ProfileView standalone.
    var onOpenTutorial: (() -> Void)? = nil
    /// Cross-tab: open a board from a Profile sub-page (Counters hub → Counter
    /// detail → member card). Routed by `MainTabView.openBoard`, so a core
    /// board lands in its pager window. Optional like `onOpenTutorial` (previews
    /// / snapshots compose the view bare); MainTabView always wires it.
    var onOpenBoard: ((String) -> Void)? = nil

    // MARK: - Private state

    @State private var showEditProfile = false

    /// Async-loaded per-timeframe bingo + greenlog streaks for the "Your
    /// streaks" card. Empty until `loadCounts()` computes it.
    @State private var streaks: [Timeframe: StreakPair] = [:]
    /// False until `loadCounts()` lands — empty streaks mean "not
    /// computed yet", not "all zero" (late-mutation audit, shape B).
    @State private var streaksLoaded = false

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

    // MARK: - Body

    var body: some View {
        ZStack {
            RisoPaperBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    header
                        .padding(.horizontal, Riso.gutter)
                        .padding(.top, 16)
                        .padding(.bottom, 18)

                    // Identity row — account card + gear (→ Settings)
                    HStack(alignment: .center, spacing: 12) {
                        RisoProfileAccountCard(
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
                    .padding(.horizontal, Riso.gutter)
                    .padding(.bottom, 18)

                    // Your streaks section — tapping the card pushes StreaksView
                    sectionLabel("Your streaks")
                    NavigationLink { StreaksView() } label: {
                        RisoYourStreaksCard(streaks: streaks, streaksLoaded: streaksLoaded)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Riso.gutter)
                    .padding(.bottom, 18)

                    // Preferences section
                    sectionLabel("Preferences")
                    preferencesCard
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 18)
                }
            }
        }
        .navigationBarHidden(true)
        // Edit profile sheet — replaces the old inline alert.
        // Presented modally so the NavigationStack chrome appears correctly
        // (title + gold-pill Done button). Dismissed by the sheet itself
        // via `onSave` / `onCancel`.
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
        .onAppear { loadCounts() }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Account").risoKicker()
            Text("Profile").risoH1()
                .padding(.top, 4)
        }
    }

    // MARK: - Gear button (→ Settings)

    /// 40×40 paper-2 keyline square with a `gearshape` glyph — matches
    /// `RisoSubPageHeader`'s back-button metrics exactly (2pt ink border,
    /// 7pt radius). The `RisoButtonStyle` wrapper on the `NavigationLink`
    /// supplies both the press-into-paper animation and the hard shadow.
    private var gearButton: some View {
        Image(systemName: "gearshape")
            .font(.system(size: 16, weight: .bold))
            .foregroundStyle(Color.risoInk)
            .frame(width: 40, height: 40)
            .risoCard(fill: .risoPaper2)
            // 40pt visual square, 44pt touch target (HIG minimum): the
            // content shape is laid on a 44pt frame, then the negative
            // padding gives the 40pt layout back so the button style's
            // hard shadow still traces the card (same trick as the
            // RisoSubPageHeader back button).
            .padding(2)
            .contentShape(Rectangle())
            .padding(-2)
    }

    // MARK: - Section label

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .risoSectionLabel()
            .padding(.horizontal, Riso.gutter)
            .padding(.bottom, 8)
    }

    // MARK: - Preferences card

    private var preferencesCard: some View {
        VStack(spacing: 0) {
            // Getting started — re-entry to the tutorial board (cross-tab).
            Button { onOpenTutorial?() } label: {
                RisoProfileRow(
                    icon: "graduationcap",
                    label: "Getting started",
                    value: tutorialStore.isComplete
                        ? "Done"
                        : "\(tutorialStore.completedCount)/\(TutorialProgressStore.totalLessons)",
                    chevron: true
                )
            }
            .buttonStyle(.plain)

            rowDivider

            // Board settings (Task Pools + Recurring Boards Rework, P7) —
            // replaces the separate "Recurring templates" / "Default
            // pools" rows: per-timeframe core-board defaults + the
            // repeating-boards roster now live on one page. No count
            // badge — a single number spanning two different entity
            // types (defaults vs. repeating boards) isn't meaningful.
            NavigationLink {
                BoardSettingsView()
            } label: {
                RisoProfileRow(
                    icon: "slider.horizontal.3",
                    label: "Board settings",
                    chevron: true
                )
            }
            .buttonStyle(.plain)

            rowDivider

            // Shared counters (Shared Counters P1)
            NavigationLink {
                CountersHubView(onOpenBoard: onOpenBoard ?? { _ in })
            } label: {
                RisoProfileRow(
                    icon: "arrow.triangle.2.circlepath",
                    label: "Shared counters",
                    chevron: true
                )
            }
            .buttonStyle(.plain)
        }
        .risoCard()
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
    }

    // MARK: - Helpers

    private var rowDivider: some View {
        Divider()
            .background(Color.risoInk.opacity(0.12))
            .padding(.horizontal, Riso.cardPadding)
    }

    // MARK: - Streak loading

    /// Loads the "Your streaks" card data async on appear. P7 (Task Pools
    /// + Recurring Boards Rework) dropped the two Preferences-row count
    /// badges this used to also load (`recurringTemplateCount`/
    /// `defaultPoolCount`) — the merged "Board settings" row shows no
    /// count (a single number spanning defaults + repeating boards isn't
    /// meaningful) — so this is streaks-only now.
    private func loadCounts() {
        guard let userId = authService.currentUser?.id else { return }
        // Per-timeframe streaks for the "Your streaks" card. `computeAllStreaks`
        // is pure (safe off-main); `fetchBoards` returns all boards and the
        // algorithm re-filters to core/non-deleted internally.
        let weekStartDay = authService.userPreferences.weekStartDay.rawValue
        // Capture `now` on main before the detached task (parity with the slot /
        // window VMs) so a midnight rollover between dispatch and execution can't
        // mismatch the boards snapshot against a next-day `now`.
        let now = Date()
        _Concurrency.Task.detached(priority: .userInitiated) {
            let boards = (try? AppDatabase.shared.fetchBoards(userId: userId)) ?? []
            let result = computeAllStreaks(boards: boards, weekStartDay: weekStartDay, now: now)
            await MainActor.run {
                streaks = result
                streaksLoaded = true
            }
        }
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
