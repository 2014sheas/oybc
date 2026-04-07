import SwiftUI

/// ProfileView - Account settings and app configuration.
///
/// Grouped settings layout (mirroring iOS Settings app conventions) covering:
/// - Account identity (avatar initial, display name, email)
/// - App settings (theme placeholder, last synced, Playground access)
/// - Sign-out action
struct ProfileView: View {
    @EnvironmentObject var authService: AuthService

    var body: some View {
        List {
            accountSection
            appSection
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
            HStack {
                Label("Theme", systemImage: "paintpalette")
                Spacer()
                Text("System")
                    .foregroundStyle(.secondary)
            }

            HStack {
                Label("Last Synced", systemImage: "arrow.triangle.2.circlepath")
                Spacer()
                Text("Never")
                    .foregroundStyle(.secondary)
            }

            NavigationLink {
                PlaygroundView()
            } label: {
                Label("Playground", systemImage: "hammer")
            }
        }
    }

    private var signOutSection: some View {
        Section {
            Button("Sign Out", role: .destructive) {
                try? authService.signOut()
            }
        }
    }

    // MARK: - Subviews

    /// Circular avatar showing the user's initial (or a person icon as fallback).
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

    /// Returns the uppercased first character of the user's display name or email, if available.
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
