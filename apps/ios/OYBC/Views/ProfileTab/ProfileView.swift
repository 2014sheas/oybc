import SwiftUI

/// ProfileView — Riso-styled account info, app-level settings, and sign out.
///
/// Phase 5 Riso reskin: preserves all behavior (theme write path via
/// `themeBinding`, name edit via `updateDisplayName`, sign out via
/// `authService.signOut()`, the 3 preferences NavigationLinks + the
/// `onEditRecurringTemplate` callback, SyncStatusIndicator data).
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

    // MARK: - Inputs

    /// Phase 6.2: cross-tab edit handler. Optional so #Preview / tests
    /// that mount ProfileView in isolation don't need cross-tab plumbing.
    var onEditRecurringTemplate: ((String) -> Void)? = nil

    // MARK: - Private state

    @State private var showNameEdit = false
    @State private var editNameValue = ""
    @State private var showSignOutConfirm = false
    @State private var signOutError: String?

    /// Async-loaded counts for the Preferences rows.
    @State private var recurringTemplateCount: Int? = nil
    @State private var defaultPoolCount: Int? = nil

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
                        onEditName: {
                            editNameValue = displayName
                            showNameEdit = true
                        }
                    )
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
                }
            }
        }
        .navigationBarHidden(true)
        // Name edit alert
        .alert("Edit Display Name", isPresented: $showNameEdit) {
            TextField("Display name", text: $editNameValue)
            Button("Cancel", role: .cancel) { }
            Button("Save") {
                _Concurrency.Task {
                    try? await authService.updateDisplayName(editNameValue)
                }
            }
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
                    selection: themeBinding
                )
                // Compact: shrink the segmented to fit
                .fixedSize()
            }
            .padding(.vertical, 12)
            .padding(.horizontal, Riso.cardPadding)

            rowDivider

            // Sync row
            RisoSyncRow()
        }
        .risoCard()
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
    }

    // MARK: - Preferences card

    private var preferencesCard: some View {
        VStack(spacing: 0) {
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

            // Recurring templates (with async count)
            NavigationLink {
                RecurringTemplatesView(onEditTemplate: onEditRecurringTemplate)
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
                                signOutError = error.localizedDescription
                                showSignOutConfirm = false
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
                    print("⚠️ updateUserPreferences(theme) failed: \(error)")
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
        _Concurrency.Task {
            let templates = try? AppDatabase.shared.fetchRecurringBoardTemplates(userId: userId)
            let nonDeleted = templates?.filter { !$0.isDeleted } ?? []
            await MainActor.run { recurringTemplateCount = nonDeleted.count }
        }
        _Concurrency.Task {
            let pools = try? AppDatabase.shared.fetchDefaultPools(userId: userId)
            await MainActor.run { defaultPoolCount = pools?.count }
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
