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

    /// Whether the guest→account upgrade sheet is presented (docs/GUEST_MODE.md
    /// §Phase 3). Presented on top of this sheet rather than swapping content,
    /// so "Sign in to sync" reuses the same `UpgradeAccountSheet` the Profile
    /// "Save your account" CTA opens.
    @State private var showUpgradeSheet = false

    var body: some View {
        SyncSheet(
            state: derivedState,
            exhaustedCount: syncService.exhaustedCount,
            isGuest: authService.isAnonymous,
            onTryAgain: handleTryAgain,
            onRetryExhausted: handleRetryExhausted,
            onSignIn: { showUpgradeSheet = true },
            onClose: onClose
        )
        .sheet(isPresented: $showUpgradeSheet) {
            UpgradeAccountSheet()
        }
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

    /// Recover items stuck past the retry cap: reset them to PENDING and kick
    /// a full sync. Delegates to `SyncService.retryExhaustedItems`.
    private func handleRetryExhausted() {
        guard let userId = authService.currentUser?.id else { return }
        _Concurrency.Task {
            await syncService.retryExhaustedItems(userId: userId)
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
    /// Number of changes stuck past the retry cap. `0` (the default) renders
    /// nothing new — existing snapshots are unaffected. When `> 0` an
    /// exhausted-item recovery block appears with a plain count + Retry button.
    var exhaustedCount: Int = 0
    /// Guest (Firebase anonymous) session (docs/GUEST_MODE.md §Phase 3). When
    /// true, the state block always shows the guest-specific "backed up on
    /// this device, not across devices" copy + a "Sign in to sync" CTA —
    /// independent of `state`, since sync genuinely does run for a guest and
    /// showing "Offline"/"Sync failed" copy would be misleading about the one
    /// thing actually missing (cross-device reach).
    var isGuest: Bool = false
    var onTryAgain: () -> Void = {}
    var onRetryExhausted: () -> Void = {}
    var onSignIn: () -> Void = {}
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
                (isGuest ? AnyView(guestStateBlock) : AnyView(stateBlock))
                    .padding(.horizontal, Riso.gutter)
                    .padding(.bottom, (isGuest || stateNeedsTryAgain) ? 12 : 24)

                // "Sign in to sync" CTA — guest only.
                if isGuest {
                    RisoButton(title: "Sign in to sync across devices", kind: .primary, fullWidth: true) {
                        onSignIn()
                    }
                    .padding(.horizontal, Riso.gutter)
                    .padding(.bottom, 24)
                }

                // "Try again" button — only for offline/error, never for a guest.
                if !isGuest && stateNeedsTryAgain {
                    RisoButton(title: "Try again", kind: .neutral, fullWidth: true) {
                        onTryAgain()
                    }
                    .padding(.horizontal, Riso.gutter)
                    .padding(.bottom, 24)
                }

                // Exhausted-item recovery — only when changes are stuck past
                // the retry cap. Independent of the connectivity state above:
                // an item can be exhausted while the sheet reads "All synced".
                // Plain count only — never a raw error (the #151 discipline).
                if !isGuest && exhaustedCount > 0 {
                    exhaustedBlock
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

    // MARK: - Guest state block

    /// The guest-only state block (docs/GUEST_MODE.md §Phase 3): same visual
    /// shape as `stateBlock`, but a fixed message independent of `state` —
    /// sync runs for a guest, it just doesn't reach another device yet.
    private var guestStateBlock: some View {
        HStack(alignment: .center, spacing: 16) {
            Image(systemName: "person.crop.circle.badge.questionmark")
                .font(.system(size: 22, weight: .bold))
                .foregroundStyle(Color.risoInk)
                .frame(width: 52, height: 52)
                .background(
                    RoundedRectangle(cornerRadius: Riso.cardRadius)
                        .fill(Color.risoGold.opacity(0.25))
                )
                .overlay(
                    RoundedRectangle(cornerRadius: Riso.cardRadius)
                        .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense)
                )

            VStack(alignment: .leading, spacing: 4) {
                Text("Backed up on this device")
                    .font(.risoHead(17, .extraBold))
                    .tracking(-0.34)
                    .foregroundStyle(Color.risoInk)
                Text("Sign in to sync across your other devices too.")
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
        .accessibilityLabel("Backed up on this device. Sign in to sync across your other devices too.")
    }

    // MARK: - Exhausted-item recovery block

    private var exhaustedBlock: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(exhaustedCountLabel)
                .font(.risoHead(15, .extraBold))
                .tracking(-0.3)
                .foregroundStyle(Color.risoRed)
                .fixedSize(horizontal: false, vertical: true)

            RisoButton(title: "Retry", kind: .primary, fullWidth: true) {
                onRetryExhausted()
            }
        }
        .padding(Riso.cardPadding)
        .frame(maxWidth: .infinity, alignment: .leading)
        .risoCard()
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("\(exhaustedCountLabel). Retry.")
    }

    /// "N change(s) couldn't sync" — the singular/plural copy shared with web.
    private var exhaustedCountLabel: String {
        exhaustedCount == 1
            ? "1 change couldn\u{2019}t sync"
            : "\(exhaustedCount) changes couldn\u{2019}t sync"
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

#Preview("Guest") {
    SyncSheet(state: .synced(lastSyncedAt: Date().addingTimeInterval(-300)), isGuest: true)
        .presentationDetents([.medium])
}
#endif
