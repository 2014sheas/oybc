import SwiftUI
@preconcurrency import GRDB

/// ProfileView - Account info, app-level settings, and sign out.
///
/// Board-creation defaults (timeframe, size, center type, randomize,
/// custom center name, week-start) live in a dedicated sub-page at
/// `BoardPreferencesView` — they're a related cluster that governs the
/// new-board form and don't belong on the top-level settings surface.
struct ProfileView: View {
    @EnvironmentObject var authService: AuthService
    @State private var signOutError: String?
    @State private var lastSyncedAt: String?
    @State private var lastSyncedObservation: DatabaseCancellable?

    private var preferences: UserPreferences { authService.userPreferences }

    var body: some View {
        List {
            accountSection
            appSection
            preferencesSection
            developerSection
            signOutSection
        }
        .navigationTitle("Profile")
        .onAppear { startLastSyncedObservation() }
        .onDisappear {
            lastSyncedObservation?.cancel()
            lastSyncedObservation = nil
        }
    }

    // MARK: - Sections

    private var accountSection: some View {
        Section {
            HStack(spacing: 14) {
                avatarCircle
                VStack(alignment: .leading, spacing: 2) {
                    Text(authService.currentUser?.displayName ?? "OYBC User")
                        .font(.headline)
                    if let email = authService.currentUser?.email {
                        Text(email)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
        }
    }

    private var appSection: some View {
        Section("App") {
            Picker(selection: themeBinding) {
                Text("System").tag(ThemePreference.system)
                Text("Light").tag(ThemePreference.light)
                Text("Dark").tag(ThemePreference.dark)
            } label: {
                Label("Theme", systemImage: "paintpalette")
            }

            HStack {
                Label("Last Synced", systemImage: "arrow.triangle.2.circlepath")
                Spacer()
                Text(formattedLastSynced)
                    .foregroundStyle(.secondary)
            }
        }
    }

    private var preferencesSection: some View {
        Section("Preferences") {
            NavigationLink {
                BoardPreferencesView()
            } label: {
                Label("Board preferences", systemImage: "square.grid.3x3")
            }
        }
    }

    private var developerSection: some View {
        Section("Developer") {
            NavigationLink {
                PlaygroundView()
            } label: {
                Label("Playground", systemImage: "hammer")
            }
        }
    }

    private var signOutSection: some View {
        Section {
            if let signOutError {
                Text(signOutError)
                    .font(.footnote)
                    .foregroundStyle(.red)
            }
            Button("Sign Out", role: .destructive) {
                do {
                    try authService.signOut()
                } catch {
                    signOutError = error.localizedDescription
                }
            }
        }
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

    // MARK: - Last-synced display

    private var formattedLastSynced: String {
        guard let iso = lastSyncedAt,
              let date = ISO8601DateFormatter().date(from: iso) else {
            return "Never"
        }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }

    /// Subscribes to GRDB `ValueObservation` on the signed-in user's row so
    /// the Last-Synced label reflects sync writes without requiring a
    /// refresh. The cancellable is retained in `@State` and torn down in
    /// `.onDisappear`.
    private func startLastSyncedObservation() {
        guard let userId = authService.currentUser?.id else { return }
        lastSyncedObservation = AppDatabase.shared.observeLastSynced(userId: userId) { value in
            _Concurrency.Task { @MainActor in
                self.lastSyncedAt = value
            }
        }
    }

    // MARK: - Subviews

    private var avatarCircle: some View {
        ZStack {
            Circle()
                .fill(Color.accentColor.opacity(0.15))
                .frame(width: 52, height: 52)

            if let initial = avatarInitial {
                Text(initial)
                    .font(.title2.bold())
                    .foregroundStyle(Color.accentColor)
            } else {
                Image(systemName: "person.fill")
                    .font(.title2)
                    .foregroundStyle(Color.accentColor)
            }
        }
    }

    private var avatarInitial: String? {
        let source = authService.currentUser?.displayName ?? authService.currentUser?.email
        return source.flatMap { $0.first.map { String($0).uppercased() } }
    }
}

#Preview {
    NavigationStack {
        ProfileView()
            .environmentObject(AuthService())
    }
}
