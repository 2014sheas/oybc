import SwiftUI

/// Riso-styled Sync row for the Profile App card.
///
/// Shows the sync icon square + "Sync" label + a status dot and one of three
/// plain, non-technical states: "Up to date" / "Syncing…" / "Offline".
///
/// Sync is automatic; this row is reassurance only. It deliberately never
/// surfaces raw error detail, timestamps, or internal ids. Only a real network
/// outage reads as "Offline"; an online sync error (which the background loop
/// retries) reads as "Syncing…" — never "Offline" while the device is connected.
///
/// **Guest mode** (docs/GUEST_MODE.md §Phase 3): a Firebase anonymous session
/// genuinely syncs to Firestore under its hidden uid — it's just not
/// reachable from another device without signing in. So a guest never reads
/// "Offline"/error copy here; the row always shows the guest-specific status
/// regardless of live sync/network state, and says "not synced *across
/// devices*", never "not synced".
///
/// Reads from the AuthService / SyncService / NetworkMonitor environment
/// directly so its status stays live without the parent passing through
/// every field.
struct RisoSyncRow: View {
    @EnvironmentObject private var authService: AuthService
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
        // Guest: an informational nudge, not a warning — gold, not orange/green.
        if authService.isAnonymous { return .risoGold }
        // Orange only when attention may be warranted (offline, stuck items,
        // or a sync error); routine in-flight syncing stays green/calm.
        if !networkMonitor.isConnected
            || syncService.exhaustedCount > 0
            || syncService.lastError != nil { return Color.orange }
        return .risoGreen
    }

    private var statusText: String {
        // Guest: sync genuinely runs to this device's hidden anon uid — say
        // "not synced across devices", never "not synced". Independent of
        // live network/sync state (see doc comment above).
        if authService.isAnonymous { return "Backed up · sign in to sync across devices" }
        // Only a real network outage is "Offline". Items stuck past the retry
        // cap surface as a plain count so the user has a reason to open the
        // sync sheet (where the Retry button lives) — never the raw error. An
        // online sync error is being retried by the background loop, so it
        // reads as "Syncing…" — never "Offline" while connected.
        if !networkMonitor.isConnected { return "Offline" }
        if syncService.exhaustedCount > 0 {
            return syncService.exhaustedCount == 1
                ? "1 couldn\u{2019}t sync"
                : "\(syncService.exhaustedCount) couldn\u{2019}t sync"
        }
        if syncService.lastError != nil || syncService.isSyncing { return "Syncing…" }
        return "Up to date"
    }
}
