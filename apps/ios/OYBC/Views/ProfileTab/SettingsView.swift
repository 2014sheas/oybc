import SwiftUI

/// SettingsView — Profile reorg PR1. Pushed from the gear button on
/// `ProfileView` (or a tutorial deep-link, `TutorialDeepLink.settings`).
///
/// Houses everything that used to live directly on Profile but is touched
/// rarely: Theme, Notifications, Account & security, Help & getting
/// started, Sign Out, the version footer, and the DEBUG-only developer
/// affordances. Guest mode keeps its existing substitutions (the "Save your
/// account" CTA card in place of Account & security, "Discard guest data"
/// in place of Sign Out) — ported verbatim from the old `ProfileView`.
///
/// Sync UI (`RisoSyncRow` / `SyncSheet`) is NOT relocated here — it was
/// deleted entirely (owner decision, `.superpowers/sdd/2026-09-30-profile-reorg/owner-decisions.md`
/// #2). Sync keeps running silently in the background.
struct SettingsView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var tutorialStore: TutorialProgressStore

    /// Opens the Getting Started tutorial board (cross-tab to Boards).
    /// Threaded down to `HelpView`. Optional so #Preview / tests can mount
    /// this view standalone.
    var onOpenTutorial: (() -> Void)? = nil

    // MARK: - Private state

    @State private var showSignOutConfirm = false
    @State private var signOutError: String?

    // MARK: - Guest mode state (docs/GUEST_MODE.md §Phase 3/5) — ported verbatim

    @State private var showUpgradeSheet = false
    @State private var showDiscardConfirm = false
    @State private var discardError: String?
    @State private var isDiscarding = false

    // MARK: - Derived

    private var preferences: UserPreferences { authService.userPreferences }
    private var isGuest: Bool { authService.isAnonymous }

    // MARK: - Body

    var body: some View {
        ZStack {
            RisoPaperBackground()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    RisoSubPageHeader(title: "Settings")
                        .padding(.top, 16)
                        .padding(.bottom, 20)

                    sectionLabel("Appearance")
                    appearanceCard
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 18)

                    sectionLabel("Preferences")
                    preferencesCard
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 18)

                    // Guest mode (docs/GUEST_MODE.md §Phase 3/5): "Save your
                    // account" + "Discard guest data" replace the Sign Out
                    // card entirely — ported verbatim from the old
                    // ProfileView. A guest never gets a plain, reversible-
                    // looking sign-out (it would orphan the anon tree with
                    // no way back in).
                    if isGuest {
                        guestUpgradeCard
                            .padding(.horizontal, Riso.gutter)
                            .padding(.bottom, 12)

                        discardGuestDataCard
                            .padding(.horizontal, Riso.gutter)
                            .padding(.bottom, 14)
                    } else {
                        signOutCard
                            .padding(.horizontal, Riso.gutter)
                            .padding(.bottom, 14)
                    }

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
        .sheet(isPresented: $showUpgradeSheet) {
            UpgradeAccountSheet()
        }
    }

    // MARK: - Section label

    private func sectionLabel(_ title: String) -> some View {
        Text(title)
            .risoSectionLabel()
            .padding(.horizontal, Riso.gutter)
            .padding(.bottom, 8)
    }

    // MARK: - Appearance card (Theme)

    private var appearanceCard: some View {
        HStack(spacing: 12) {
            iconSquare(systemName: "sun.max")

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
        .risoCard()
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
    }

    // MARK: - Preferences card

    private var preferencesCard: some View {
        VStack(spacing: 0) {
            NavigationLink(value: ProfileRoute.notifications) {
                RisoProfileRow(
                    icon: "bell",
                    label: "Notifications",
                    caption: notificationsCaption,
                    chevron: true
                )
            }
            .buttonStyle(.plain)

            // Account & security — hidden for a guest (docs/GUEST_MODE.md
            // §Phase 3): there's no email/password/linked-provider identity
            // to manage yet — that's exactly what "Save your account"
            // below sets up. Ported verbatim from the old ProfileView.
            if !isGuest {
                rowDivider

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
            }

            rowDivider

            NavigationLink(value: ProfileRoute.help) {
                RisoProfileRow(
                    icon: "checkmark.circle",
                    label: "Help & getting started",
                    chevron: true
                )
            }
            .buttonStyle(.plain)
        }
        .risoCard()
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
    }

    /// `Reminders {on|off} · {time} · Renewals {on|off}` — "Reminders" is the
    /// daily play reminder (the only category with a time attached);
    /// "Renewals" is the new-recurring-window prompt (PR3 renames this
    /// "Board renewals" and moves the per-timeframe toggles here; this
    /// caption already uses the copy that will describe that group).
    private var notificationsCaption: String {
        let remindersOn = preferences.dailyPlayReminderEnabled ? "on" : "off"
        let time = formattedReminderTime(preferences.dailyPlayReminderTime)
        let renewalsOn = preferences.recurringWindowReminders ? "on" : "off"
        return "Reminders \(remindersOn) · \(time) · Renewals \(renewalsOn)"
    }

    /// Converts the stored "HH:mm" string to a locale-formatted short time
    /// (e.g. "8:00 PM"). Falls back to the raw string if unparsable.
    private func formattedReminderTime(_ raw: String) -> String {
        guard let (hour, minute) = NotificationPlanner.parseReminderTime(raw) else { return raw }
        let base = Calendar.current.startOfDay(for: Date())
        let date = Calendar.current.date(bySettingHour: hour, minute: minute, second: 0, of: base) ?? base
        return date.formatted(date: .omitted, time: .shortened)
    }

    // MARK: - Sign Out card (ported verbatim from the old ProfileView)

    private var signOutCard: some View {
        Group {
            if showSignOutConfirm {
                // Inline dashed-red confirm — the whole card becomes dashed red.
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

    // MARK: - Guest mode cards (docs/GUEST_MODE.md §Phase 3/5) — ported verbatim

    /// Primary CTA replacing the hidden "Account & security" row + the Sign
    /// Out card for a guest — the single most important thing a guest can do.
    private var guestUpgradeCard: some View {
        RisoButton(title: "Save your account", kind: .primary, fullWidth: true, large: true) {
            showUpgradeSheet = true
        }
        .padding(Riso.cardPadding)
        .risoCard()
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
    }

    /// A guest's replacement for "Sign Out": since a plain sign-out would
    /// orphan the anonymous Firebase tree with no way back in, the only
    /// available exit is a destructive, explicitly-irreversible discard —
    /// routed through `deleteAccount()` (not `signOut()`). This doubles as
    /// the guest's App Store 5.1.1(v) in-app deletion affordance, since the
    /// "Account & security" delete flow is hidden for guests.
    private var discardGuestDataCard: some View {
        Group {
            if showDiscardConfirm {
                VStack(spacing: 12) {
                    Text("Discard guest data?")
                        .font(.risoBody(14, .bold))
                        .foregroundStyle(Color.risoRed)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 14)

                    Text("This permanently erases every board, task, and streak on this device. It can't be undone.")
                        .font(.risoBody(12, .regular))
                        .foregroundStyle(Color.risoMuted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    if let discardError {
                        Text(discardError)
                            .font(.risoBody(11, .regular))
                            .foregroundStyle(Color.risoRed)
                            .multilineTextAlignment(.center)
                    }

                    HStack(spacing: 10) {
                        RisoButton(title: "Cancel", kind: .neutral, fullWidth: true) {
                            showDiscardConfirm = false
                            discardError = nil
                        }
                        RisoButton(
                            title: isDiscarding ? "Discarding…" : "Discard",
                            kind: .primary,
                            fullWidth: true
                        ) {
                            discardGuestData()
                        }
                        .disabled(isDiscarding)
                        .opacity(isDiscarding ? 0.6 : 1)
                    }
                    .padding(.bottom, 14)
                }
                .padding(.horizontal, Riso.cardPadding)
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
                Button {
                    discardError = nil
                    showDiscardConfirm = true
                } label: {
                    RisoProfileRow(
                        icon: "trash",
                        label: "Discard guest data",
                        danger: true
                    )
                }
                .buttonStyle(.plain)
                .risoCard()
                .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
            }
        }
    }

    /// Runs the discard: `deleteAccount()` deletes the Auth user (firing the
    /// server-side `onUserDeleted` purge) and wipes local GRDB. On success
    /// `authService.currentUser` becomes nil, so `AuthGateView` swaps back to
    /// `LoginView` on its own — no local dismiss/navigation needed here.
    private func discardGuestData() {
        isDiscarding = true
        discardError = nil
        _Concurrency.Task {
            defer { isDiscarding = false }
            do {
                try await authService.deleteAccount()
            } catch {
                discardError = error.localizedDescription
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

    private func iconSquare(systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.risoInk)
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.risoPaper)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense)
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
}

#Preview {
    let authService = AuthService()
    return NavigationStack {
        SettingsView()
            .environmentObject(authService)
            .environmentObject(TutorialProgressStore())
    }
}
