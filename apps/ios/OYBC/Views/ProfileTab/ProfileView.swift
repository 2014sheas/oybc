import SwiftUI

/// ProfileView - Account info, app-level settings, and sign out.
///
/// Board-creation defaults (timeframe, size, center type, randomize,
/// custom center name, week-start) live in a dedicated sub-page at
/// `BoardPreferencesView` — they're a related cluster that governs the
/// new-board form and don't belong on the top-level settings surface.
struct ProfileView: View {
    @EnvironmentObject var authService: AuthService
    @EnvironmentObject var syncService: SyncService
    @State private var signOutError: String?
    @State private var showSignOutConfirm = false
    @State private var showNameEdit = false
    @State private var editNameValue = ""

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
    }

    // MARK: - Sections

    private var accountSection: some View {
        Section {
            HStack(spacing: 14) {
                avatarCircle
                VStack(alignment: .leading, spacing: 2) {
                    HStack(spacing: 4) {
                        Text(authService.currentUser?.displayName ?? "OYBC User")
                            .font(.headline)
                        Image(systemName: "pencil")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    .onTapGesture {
                        editNameValue = authService.currentUser?.displayName ?? ""
                        showNameEdit = true
                    }
                    if let email = authService.currentUser?.email {
                        Text(email)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .padding(.vertical, 4)
            .alert("Edit Display Name", isPresented: $showNameEdit) {
                TextField("Display name", text: $editNameValue)
                Button("Cancel", role: .cancel) { }
                Button("Save") {
                    _Concurrency.Task {
                        try? await authService.updateDisplayName(editNameValue)
                    }
                }
            }
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

            SyncStatusIndicatorView()
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
                // Pass the signed-in user's week-start so playground features
                // that do timeframe boundary math match production behaviour.
                PlaygroundView(weekStartDay: preferences.weekStartDay.rawValue)
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
                showSignOutConfirm = true
            }
            .alert("Sign out?", isPresented: $showSignOutConfirm) {
                Button("Cancel", role: .cancel) { }
                Button("Sign Out", role: .destructive) {
                    do {
                        try authService.signOut()
                    } catch {
                        signOutError = error.localizedDescription
                    }
                }
            } message: {
                Text("Are you sure you want to sign out?")
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
    let authService = AuthService()
    return NavigationStack {
        ProfileView()
            .environmentObject(authService)
            .environmentObject(authService.syncService)
            .environmentObject(NetworkMonitor())
    }
}
