import SwiftUI

/// Compact sync status indicator for production screens (Profile).
///
/// Shows online/offline badge, last-synced timestamp, optional error,
/// and a "Sync Now" button. Reads from the shared `SyncService` and
/// `NetworkMonitor` environment objects.
struct SyncStatusIndicatorView: View {
    @EnvironmentObject private var syncService: SyncService
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @EnvironmentObject private var authService: AuthService

    var body: some View {
        Group {
            // Online / offline status
            HStack {
                Label("Status", systemImage: "wifi")
                Spacer()
                HStack(spacing: 6) {
                    Circle()
                        .fill(networkMonitor.isConnected ? .green : .orange)
                        .frame(width: 8, height: 8)
                    Text(networkMonitor.isConnected ? "Online" : "Offline")
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
            }

            // Last synced timestamp
            HStack {
                Label("Last Synced", systemImage: "arrow.triangle.2.circlepath")
                Spacer()
                Text(formattedLastSynced)
                    .foregroundStyle(.secondary)
            }

            // Last error (conditional)
            if let error = syncService.lastError {
                HStack(spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .foregroundStyle(.orange)
                    Text(error.message)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(2)
                }
            }

            // Sync Now button
            Button {
                guard let userId = authService.currentUser?.id else { return }
                _Concurrency.Task {
                    _ = await syncService.fullSync(userId: userId)
                }
            } label: {
                HStack {
                    Image(systemName: "arrow.clockwise")
                    Text(syncService.isSyncing ? "Syncing…" : "Sync Now")
                }
            }
            .disabled(syncService.isSyncing || !networkMonitor.isConnected)
        }
    }

    private var formattedLastSynced: String {
        guard let date = syncService.lastEventAt else { return "Syncing…" }
        let formatter = DateFormatter()
        formatter.dateStyle = .none
        formatter.timeStyle = .short
        return formatter.string(from: date)
    }
}
