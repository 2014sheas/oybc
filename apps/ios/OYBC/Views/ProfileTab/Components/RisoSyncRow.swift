import SwiftUI

/// Riso-styled Sync row for the Profile App card.
///
/// Shows the sync icon square + "Sync" label + a green status dot
/// + a compact status string derived from `SyncService.lastEventAt`
/// and `SyncService.lastError`.
///
/// This row is presentational regarding the icon/label/chevron layout
/// but reads from the SyncService environment directly so its status
/// stays live without the parent having to pass through every field.
struct RisoSyncRow: View {
    @EnvironmentObject private var syncService: SyncService
    @EnvironmentObject private var networkMonitor: NetworkMonitor

    var body: some View {
        HStack(spacing: 12) {
            // Icon square
            Image(systemName: "arrow.triangle.2.circlepath")
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

            Text("Sync")
                .font(.risoBody(14, .bold))
                .foregroundStyle(Color.risoInk)
                .frame(maxWidth: .infinity, alignment: .leading)

            // Status dot + label
            HStack(spacing: 5) {
                Circle()
                    .fill(statusDotColor)
                    .frame(width: 7, height: 7)
                Text(statusText)
                    .risoSub()
                    .lineLimit(1)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, Riso.cardPadding)
    }

    // MARK: - Derived

    private var statusDotColor: Color {
        if let _ = syncService.lastError { return .risoRed }
        if !networkMonitor.isConnected { return Color.orange }
        return .risoGreen
    }

    private var statusText: String {
        if let err = syncService.lastError {
            return err.message
        }
        if !networkMonitor.isConnected {
            return "Offline"
        }
        guard let last = syncService.lastEventAt else {
            return syncService.isSyncing ? "Syncing…" : "Not yet synced"
        }
        return "Synced · \(relativeTimeString(from: last))"
    }

    /// Compact relative-time string matching the prototype ("just now",
    /// "2m ago", "3h ago", "yesterday"). Keeps the status line to one line.
    private func relativeTimeString(from date: Date) -> String {
        let seconds = Date().timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        let minutes = Int(seconds / 60)
        if minutes < 60 { return "\(minutes)m ago" }
        let hours = Int(seconds / 3600)
        if hours < 24 { return "\(hours)h ago" }
        return "yesterday"
    }
}
