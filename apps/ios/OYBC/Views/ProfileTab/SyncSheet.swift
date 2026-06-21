import SwiftUI

// MARK: - Sync state enum

/// The four display states for the sync sheet, derived at render time from
/// `SyncService` + `NetworkMonitor`. The order of priority matches `RisoSyncRow`:
/// offline beats syncing beats error beats synced.
enum SyncSheetState: Equatable {
    case synced(lastSyncedAt: Date?)
    case syncing
    case offline
    case error
}

// MARK: - SyncSheetContainer (env-bound container)

/// Thin env-bound container: reads `SyncService` + `NetworkMonitor`, maps them
/// to a `SyncSheetState`, and passes plain props to the pure-leaf `SyncSheet`.
/// The "Try again" button fires `syncService.fullSync` via the container.
///
/// **Privacy**: never passes `syncService.lastError.message` to `SyncSheet` —
/// only a `Bool` indicating whether the error state is active. The leaf renders
/// only fixed friendly copy. Preserves the #151 / #153 no-raw-error discipline.
struct SyncSheetContainer: View {

    @EnvironmentObject private var syncService: SyncService
    @EnvironmentObject private var networkMonitor: NetworkMonitor
    @EnvironmentObject private var authService: AuthService

    var onClose: () -> Void = {}

    var body: some View {
        SyncSheet(
            state: derivedState,
            onTryAgain: handleTryAgain,
            onClose: onClose
        )
    }

    // MARK: - State derivation

    /// Maps live service state → display state. Priority: offline → syncing → error → synced.
    private var derivedState: SyncSheetState {
        if !networkMonitor.isConnected {
            return .offline
        }
        if syncService.isSyncing {
            return .syncing
        }
        if syncService.lastError != nil {
            return .error
        }
        return .synced(lastSyncedAt: syncService.lastEventAt)
    }

    // MARK: - Try again

    private func handleTryAgain() {
        guard let userId = authService.currentUser?.id else { return }
        _Concurrency.Task {
            await syncService.fullSync(userId: userId)
        }
    }
}

// MARK: - SyncSheet (pure-props leaf, snapshot-testable)

/// Pure presentational leaf for the sync-status detail sheet (handoff §5d).
///
/// Shows one state block (icon tile + title + subtitle), a conditional
/// "Try again" button for offline/error states, and two static info rows.
///
/// **CRITICAL**: NEVER show raw error messages to users. The `SyncSheetState`
/// enum carries no message string — only a typed case. All user-facing copy
/// is fixed within this view.
struct SyncSheet: View {

    let state: SyncSheetState
    var onTryAgain: () -> Void = {}
    var onClose: () -> Void = {}

    var body: some View {
        ZStack {
            RisoPaperBackground().ignoresSafeArea()

            VStack(alignment: .leading, spacing: 0) {

                // Header: title + Done pill
                HStack {
                    Text("Sync")
                        .font(.risoHead(22, .extraBold))
                        .tracking(-0.44)
                        .foregroundStyle(Color.risoInk)
                    Spacer()
                    RisoToolbarPill(title: "Done", action: onClose)
                }
                .padding(.horizontal, Riso.gutter)
                .padding(.top, 24)
                .padding(.bottom, 24)

                // State block
                stateBlock
                    .padding(.horizontal, Riso.gutter)
                    .padding(.bottom, stateNeedsTryAgain ? 12 : 24)

                // "Try again" button — only for offline/error
                if stateNeedsTryAgain {
                    RisoButton(title: "Try again", kind: .neutral, fullWidth: true) {
                        onTryAgain()
                    }
                    .padding(.horizontal, Riso.gutter)
                    .padding(.bottom, 24)
                }

                // Static info rows
                VStack(spacing: 0) {
                    infoRow(label: "Auto-sync", value: "On")
                    rowDivider
                    infoRow(label: "Last backup", value: lastBackupLabel)
                }
                .risoCard()
                .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
                .padding(.horizontal, Riso.gutter)
                .padding(.bottom, 32)

                Spacer()
            }
        }
    }

    // MARK: - State block

    private var stateBlock: some View {
        HStack(alignment: .center, spacing: 16) {
            // Colored icon tile
            stateIcon
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(stateIconForeground)
                .frame(width: 52, height: 52)
                .background(
                    RoundedRectangle(cornerRadius: Riso.cardRadius)
                        .fill(stateIconBackground)
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Riso.cardRadius)
                        .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense)
                )

            // Title + subtitle
            VStack(alignment: .leading, spacing: 4) {
                Text(stateTitle)
                    .font(.risoHead(17, .extraBold))
                    .tracking(-0.34)
                    .foregroundStyle(Color.risoInk)
                Text(stateSubtitle)
                    .font(.risoBody(13, .regular))
                    .foregroundStyle(Color.risoMuted)
                    .fixedSize(horizontal: false, vertical: true)
            }

            Spacer(minLength: 0)
        }
        .padding(Riso.cardPadding)
        .risoCard()
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(stateTitle). \(stateSubtitle)")
    }

    // MARK: - State-derived values

    private var stateIcon: Image {
        switch state {
        case .synced:  return Image(systemName: "checkmark.circle.fill")
        case .syncing: return Image(systemName: "arrow.triangle.2.circlepath")
        case .offline: return Image(systemName: "wifi.slash")
        case .error:   return Image(systemName: "xmark.circle.fill")
        }
    }

    private var stateIconBackground: Color {
        switch state {
        case .synced:  return Color.risoGreen.opacity(0.15)
        case .syncing: return Color.risoBlue.opacity(0.15)
        case .offline: return Color.risoGold.opacity(0.25)
        case .error:   return Color.risoRed.opacity(0.12)
        }
    }

    private var stateIconForeground: Color {
        switch state {
        case .synced:  return Color.risoGreen
        case .syncing: return Color.risoBlue
        case .offline: return Color.risoInk
        case .error:   return Color.risoRed
        }
    }

    private var stateTitle: String {
        switch state {
        case .synced:  return "All synced"
        case .syncing: return "Syncing\u{2026}"
        case .offline: return "Offline"
        case .error:   return "Sync failed"
        }
    }

    private var stateSubtitle: String {
        switch state {
        case .synced(let lastAt):
            if let date = lastAt {
                let formatter = RelativeDateTimeFormatter()
                formatter.unitsStyle = .full
                let relative = formatter.localizedString(for: date, relativeTo: Date())
                return "Last synced \(relative)."
            }
            return "Not synced yet."
        case .syncing:
            return "Backing up your latest changes."
        case .offline:
            return "Changes are saved on this device and will sync when you reconnect."
        case .error:
            return "Couldn\u{2019}t reach the server. Your data is safe locally."
        }
    }

    private var stateNeedsTryAgain: Bool {
        switch state {
        case .offline, .error: return true
        default: return false
        }
    }

    private var lastBackupLabel: String {
        switch state {
        case .synced(let lastAt):
            guard let date = lastAt else { return "Never" }
            let formatter = RelativeDateTimeFormatter()
            formatter.unitsStyle = .abbreviated
            return formatter.localizedString(for: date, relativeTo: Date())
        case .syncing:
            return "Syncing\u{2026}"
        case .offline, .error:
            return "Unknown"
        }
    }

    // MARK: - Info row helpers

    private func infoRow(label: String, value: String) -> some View {
        HStack(spacing: 12) {
            Text(label)
                .font(.risoBody(14, .bold))
                .foregroundStyle(Color.risoInk)
            Spacer()
            Text(value)
                .risoSub()
                .lineLimit(1)
        }
        .padding(.horizontal, Riso.cardPadding)
        .padding(.vertical, 12)
    }

    private var rowDivider: some View {
        Divider()
            .background(Color.risoInk.opacity(0.12))
            .padding(.horizontal, Riso.cardPadding)
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Synced") {
    SyncSheet(state: .synced(lastSyncedAt: Date().addingTimeInterval(-300)))
        .presentationDetents([.medium])
}

#Preview("Syncing") {
    SyncSheet(state: .syncing)
        .presentationDetents([.medium])
}

#Preview("Offline") {
    SyncSheet(state: .offline)
        .presentationDetents([.medium])
}

#Preview("Error") {
    SyncSheet(state: .error)
        .presentationDetents([.medium])
}
#endif
