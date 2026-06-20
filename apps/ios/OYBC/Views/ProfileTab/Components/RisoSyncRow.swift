import SwiftUI

/// Riso-styled Sync row for the Profile App card.
///
/// Shows the sync icon square + "Sync" label + a status dot and one of three
/// plain, non-technical states: "Up to date" / "Syncing…" / "Offline".
///
/// Sync is automatic; this row is reassurance only. It deliberately never
/// surfaces raw error detail, timestamps, or internal ids — a sync error (which
/// the background loop retries) and being offline both read simply as "Offline".
///
/// Reads from the SyncService / NetworkMonitor environment directly so its
/// status stays live without the parent passing through every field.
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

    /// True when changes aren't currently reaching the cloud — offline, or a
    /// sync error the background loop will retry. Both read as "Offline" so we
    /// never surface technical detail or alarm the user over a transient hiccup.
    private var isNotSyncing: Bool {
        !networkMonitor.isConnected || syncService.lastError != nil
    }

    private var statusDotColor: Color {
        isNotSyncing ? Color.orange : .risoGreen
    }

    private var statusText: String {
        if isNotSyncing { return "Offline" }
        if syncService.isSyncing { return "Syncing…" }
        return "Up to date"
    }
}
