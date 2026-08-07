import SwiftUI

/// ProfileView — Riso-styled account info, app-level settings, and sign out.
///
/// Phase 5 Riso reskin: preserves all behavior (theme write path via
/// `themeBinding`, name edit via `updateDisplayName`, sign out via
/// `authService.signOut()`, the 4 preferences NavigationLinks + the
/// `onEditRecurringTemplate` callback, and the `RisoSyncRow` status).
/// The Developer/Playground section is intentionally removed.
///
/// Layout (over `RisoPaperBackground`, scrolling VStack of `.risoCard()` sections):
/// 1. Header kicker + H1
/// 2. Account card — Blip avatar, name ✎, email
/// 3. App card — Theme segmented + Sync row
/// 4. Preferences section — 3 rows with count pills + NavigationLinks
/// 5. Sign Out card — resting row → inline dashed confirm
/// 6. Version footer
struct ProfileView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var syncService: SyncService
    @EnvironmentObject var tutorialStore: TutorialProgressStore

    // MARK: - Inputs

    /// Phase 6.2: cross-tab edit handler. Optional so #Preview / tests
    /// that mount ProfileView in isolation don't need cross-tab plumbing.
    var onEditRecurringTemplate: ((String) -> Void)? = nil

    /// Cross-tab "+ New template" route from the Recurring templates
    /// sub-page — opens the wizard's recurring flow on the Create tab.
    var onNewRecurringTemplate: (() -> Void)? = nil

    /// Cross-tab "Add tasks" route (issue #321) from a template card's
    /// Add-tasks button — same wizard deep-link as edit, but lands on the
    /// Tasks step instead of Setup.
    var onAddTasksRecurringTemplate: ((String) -> Void)? = nil

    /// Opens the Getting Started tutorial board (cross-tab to Boards).
    /// Optional so #Preview / tests can mount ProfileView standalone.
    var onOpenTutorial: (() -> Void)? = nil

    // MARK: - Private state

    @State private var showEditProfile = false
    @State private var showSignOutConfirm = false
    @State private var signOutError: String?
    /// Whether the Sync detail sheet is presented.
    @State private var showSyncSheet = false

    /// Async-loaded counts for the Preferences rows.
    @State private var recurringTemplateCount: Int? = nil
    @State private var defaultPoolCount: Int? = nil

    /// Async-loaded per-timeframe bingo + greenlog streaks for the "Your
    /// streaks" card. Empty until `loadCounts()` computes it.
    @State private var streaks: [Timeframe: StreakPair] = [:]

    // MARK: - Derived

    private var preferences: UserPreferences { authService.userPreferences }

    private var displayName: String {
        authService.currentUser?.displayName ?? "OYBC User"
    }

    private var email: String? {
        authService.currentUser?.email
    }

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

                    // Account card
                    RisoProfileAccountCard(
                        displayName: displayName,
                        email: email,
                        onEditName: { showEditProfile = true }
                    )
                    .padding(.horizontal, Riso.gutter)
                    .padding(.bottom, 18)

                    // Your streaks section — tapping the card pushes StreaksView
                    sectionLabel("Your streaks")
                    NavigationLink { StreaksView() } label: {
                        RisoYourStreaksCard(streaks: streaks)
                    }
                    .buttonStyle(.plain)
                    .padding(.horizontal, Riso.gutter)
                    .padding(.bottom, 18)

                    // App section
                    sectionLabel("App")
                    appCard
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 18)

                    // Preferences section
                    sectionLabel("Preferences")
                    preferencesCard
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 18)

                    // Sign Out card
                    signOutCard
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 14)

                    // Version footer
                    versionFooter
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 24)

                    #if DEBUG
                    // Developer affordances: replay first-run onboarding /
                    // reset the Getting Started tutorial progress.
                    VStack(spacing: 8) {
                        SwiftUI.Button("Replay onboarding") {
                            UserDefaults.hasSeenOnboarding = false
                        }
                        SwiftUI.Button("Reset tutorial progress") {
                            tutorialStore.reset()
                        }
                    }
                    .font(.risoBody(12, .semibold))
                    .foregroundStyle(Color.risoMuted)
                    .frame(maxWidth: .infinity)
                    .padding(.bottom, 24)
                    #endif
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
                updateName: { name in
                    try await authService.updateDisplayName(name)
                },
                onSave: { showEditProfile = false },
                onCancel: { showEditProfile = false }
            )
        }
        .onAppear { loadCounts() }
        // Sync detail sheet (handoff §5d) — medium detent, drag indicator.
        // `SyncSheetContainer` reads env directly so no props need threading here.
        .sheet(isPresented: $showSyncSheet) {
            SyncSheetContainer(onClose: { showSyncSheet = false })
                .presentationDetents([.medium])
                .presentationDragIndicator(.visible)
        }
    }

    // MARK: - Header

    private var header: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("Account").risoKicker()
            Text("Profile").risoH1()
                .padding(.top, 4)
        }
    }

    // MARK: - Section label

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .risoSectionLabel()
            .padding(.horizontal, Riso.gutter)
            .padding(.bottom, 8)
    }

    // MARK: - App card (Theme + Sync)

    private var appCard: some View {
        VStack(spacing: 0) {
            // Theme row
            HStack(spacing: 12) {
                iconSquare(systemName: "circle.lefthalf.filled")

                Text("Theme")
                    .font(.risoBody(14, .bold))
                    .foregroundStyle(Color.risoInk)

                Spacer()

                RisoSegmented(
                    options: [
                        (ThemePreference.system, "System"),
                        (ThemePreference.light, "Light"),
                        (ThemePreference.dark, "Dark"),
                    ],
                    selection: themeBinding,
                    // Sizes each segment to its label (System is wider than
                    // Light/Dark) instead of `.fixedSize()` collapsing the
                    // equal-width layout into mismatched, clipping pills.
                    equalWidth: false
                )
            }
            .padding(.vertical, 12)
            .padding(.horizontal, Riso.cardPadding)

            rowDivider

            // Sync row — tapping opens the Sync detail sheet
            Button { showSyncSheet = true } label: {
                RisoSyncRow()
            }
            .buttonStyle(.plain)
        }
        .risoCard()
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
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

            // Board preferences (no count)
            NavigationLink {
                BoardPreferencesView()
            } label: {
                RisoProfileRow(
                    icon: "square.grid.3x3",
                    label: "Board preferences",
                    chevron: true
                )
            }
            .buttonStyle(.plain)

            rowDivider

            // Notifications (Phase 7 — local reminders)
            NavigationLink {
                NotificationPreferencesView()
            } label: {
                RisoProfileRow(
                    icon: "bell",
                    label: "Notifications",
                    chevron: true
                )
            }
            .buttonStyle(.plain)

            rowDivider

            // Account & security — change email/password, linked providers,
            // delete account (handoff §5c).
            NavigationLink {
                AccountSecurityView()
            } label: {
                RisoProfileRow(
                    icon: "lock.shield",
                    label: "Account & security",
                    chevron: true
                )
            }
            .buttonStyle(.plain)

            rowDivider

            // Recurring templates (with async count)
            NavigationLink {
                RecurringTemplatesView(
                    onEditTemplate: onEditRecurringTemplate,
                    onNewTemplate: onNewRecurringTemplate,
                    onAddTasksTemplate: onAddTasksRecurringTemplate
                )
            } label: {
                RisoProfileRow(
                    icon: "calendar.badge.clock",
                    label: "Recurring templates",
                    countBadge: recurringTemplateCount,
                    chevron: true
                )
            }
            .buttonStyle(.plain)

            rowDivider

            rowDivider

            // Shared counters (Shared Counters P1)
            NavigationLink {
                CountersHubView()
            } label: {
                RisoProfileRow(
                    icon: "arrow.triangle.2.circlepath",
                    label: "Shared counters",
                    chevron: true
                )
            }
            .buttonStyle(.plain)

            rowDivider

            // Default pools (with async count)
            NavigationLink {
                DefaultPoolsListView()
            } label: {
                RisoProfileRow(
                    icon: "tray.full",
                    label: "Default pools",
                    countBadge: defaultPoolCount,
                    chevron: true
                )
            }
            .buttonStyle(.plain)
        }
        .risoCard()
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
    }

    // MARK: - Sign Out card

    private var signOutCard: some View {
        Group {
            if showSignOutConfirm {
                // Inline dashed-red confirm — the whole card becomes dashed red.
                // Matches the prototype's `tt-confirm` pattern inside `.pf-card.pf-out`.
                VStack(spacing: 12) {
                    Text("Sign out?")
                        .font(.risoBody(14, .bold))
                        .foregroundStyle(Color.risoRed)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 14)

                    if let signOutError {
                        Text(signOutError)
                            .font(.risoBody(11, .regular))
                            .foregroundStyle(Color.risoRed)
                            .multilineTextAlignment(.center)
                    }

                    HStack(spacing: 10) {
                        RisoButton(title: "Cancel", kind: .neutral, fullWidth: true) {
                            showSignOutConfirm = false
                            signOutError = nil
                        }
                        RisoButton(title: "Sign Out", kind: .primary, fullWidth: true) {
                            do {
                                try authService.signOut()
                            } catch {
                                // Keep the confirm card visible so the error
                                // (rendered inside it) is actually seen.
                                signOutError = error.localizedDescription
                            }
                        }
                    }
                    .padding(.bottom, 14)
                }
                .padding(.horizontal, Riso.cardPadding)
                // Card: paper2 fill + dashed red border (no solid ink keyline)
                .background(
                    RoundedRectangle(cornerRadius: Riso.cardRadius)
                        .fill(Color.risoPaper2)
                )
                .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Riso.cardRadius)
                        .strokeBorder(
                            Color.risoRed.opacity(0.6),
                            style: StrokeStyle(lineWidth: 2, dash: [6, 4])
                        )
                )
                .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
            } else {
                // Resting Sign Out row — solid ink keyline card
                Button {
                    signOutError = nil
                    showSignOutConfirm = true
                } label: {
                    RisoProfileRow(
                        icon: "escape",
                        label: "Sign Out",
                        danger: true
                    )
                }
                .buttonStyle(.plain)
                .risoCard()
                .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
            }
        }
    }

    // MARK: - Version footer

    private var versionFooter: some View {
        let version = Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "—"
        let build = Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "—"
        return Text("OYBC · v\(version) (\(build))")
            .font(.risoBody(11, .regular))
            .foregroundStyle(Color.risoMuted)
            .frame(maxWidth: .infinity, alignment: .center)
            .padding(.top, 4)
    }

    // MARK: - Helpers

    private func iconSquare(systemName: String, danger: Bool = false) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(danger ? Color.risoRed : Color.risoInk)
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.risoPaper)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(danger ? Color.risoRed : Color.risoInk, lineWidth: Riso.Keyline.dense)
            )
    }

    private var rowDivider: some View {
        Divider()
            .background(Color.risoInk.opacity(0.12))
            .padding(.horizontal, Riso.cardPadding)
    }

    // MARK: - Theme binding

    /// Writes through `AppDatabase.updateUserPreferences` — same atomic
    /// transaction + sync-queue pattern the sub-page uses. `AuthService`'s
    /// row observation re-publishes `currentUser` when the write commits,
    /// so `MainTabView.preferredColorScheme` flips without manual refresh.
    private var themeBinding: Binding<ThemePreference> {
        Binding(
            get: { preferences.theme },
            set: { newValue in
                guard let userId = authService.currentUser?.id else { return }
                do {
                    _ = try AppDatabase.shared.updateUserPreferences(userId: userId) { current in
                        var next = current
                        next.theme = newValue
                        return next
                    }
                } catch {
                    dlog("⚠️ updateUserPreferences(theme) failed: \(error)")
                }
            }
        )
    }

    // MARK: - Count loading

    /// Loads the preference-row count badges async on appear. Single-shot,
    /// same queries the sub-views use. No live-query harness needed for a
    /// one-time badge count.
    private func loadCounts() {
        guard let userId = authService.currentUser?.id else { return }
        // Push the GRDB reads off the main actor (both fetches already filter
        // isDeleted at the SQL level — no in-memory re-filter needed).
        _Concurrency.Task.detached(priority: .userInitiated) {
            let templates = try? AppDatabase.shared.fetchRecurringBoardTemplates(userId: userId)
            await MainActor.run { recurringTemplateCount = templates?.count }
        }
        _Concurrency.Task.detached(priority: .userInitiated) {
            let pools = try? AppDatabase.shared.fetchDefaultPools(userId: userId)
            await MainActor.run { defaultPoolCount = pools?.count }
        }
        // Per-timeframe streaks for the "Your streaks" card. `computeAllStreaks`
        // is pure (safe off-main); `fetchBoards` returns all boards and the
        // algorithm re-filters to core/non-deleted internally.
        let weekStartDay = preferences.weekStartDay.rawValue
        // Capture `now` on main before the detached task (parity with the slot /
        // window VMs) so a midnight rollover between dispatch and execution can't
        // mismatch the boards snapshot against a next-day `now`.
        let now = Date()
        _Concurrency.Task.detached(priority: .userInitiated) {
            let boards = (try? AppDatabase.shared.fetchBoards(userId: userId)) ?? []
            let result = computeAllStreaks(boards: boards, weekStartDay: weekStartDay, now: now)
            await MainActor.run { streaks = result }
        }
    }
}

#Preview {
    let authService = AuthService()
    return NavigationStack {
        ProfileView()
            .environmentObject(authService)
            .environmentObject(authService.syncService)
            .environmentObject(NetworkMonitor())
    }
}
