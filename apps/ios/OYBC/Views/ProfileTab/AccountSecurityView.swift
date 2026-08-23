import SwiftUI
import AuthenticationServices
import GoogleSignIn

/// AccountSecurityView — Riso-styled Profile sub-page for Firebase account
/// identity (handoff §5c, screenshot 24). The destination of the Edit-profile
/// sheet's "Change your email from Account security." hint.
///
/// Sections (the handoff's decorative 2FA + Active-sessions rows are omitted —
/// Firebase has no client API to back them, and shipping fake toggles is
/// dishonest UI):
///   Sign in           — read-only email · Change email · Change password
///                        (password-provider only; OAuth-only accounts get an
///                        "Add a password" affordance instead).
///   Connected accounts — Apple / Google link & unlink (real Firebase linking;
///                        the last remaining provider can't be removed).
///   Danger zone        — Delete account → inline dashed-red confirm. Deletion
///                        purges Firestore server-side via a Cloud Function,
///                        deletes the Auth user, and wipes local data.
///
/// Split into a thin environment-bound container (`AccountSecurityView`) and a
/// presentational leaf (`AccountSecurityContent`, props + closures) so the leaf
/// is snapshot-testable without Firebase — mirroring `NotificationPreferences*`.
/// Security-sensitive ops surface `requiresRecentLogin`; the container then
/// presents a provider-appropriate reauth sheet and retries.
struct AccountSecurityView: View {

    @EnvironmentObject private var authService: AuthService

    @State private var activeSheet: ActiveSheet?
    @State private var isBusy = false
    @State private var statusMessage: String?
    @State private var errorMessage: String?
    @State private var showDeleteConfirm = false

    /// The op to re-run after a successful reauth, plus the success message to
    /// show once it lands (set when an op throws `requiresRecentLogin`).
    @State private var pendingRetry: (() async throws -> Void)?
    @State private var pendingSuccessMessage: String?

    /// Drives the programmatic Apple flow for link + reauth. Held as state so it
    /// stays retained across the async authorization round-trip.
    @State private var appleCoordinator = AppleSignInCoordinator()

    private var email: String { authService.currentUser?.email ?? "—" }
    private var providerState: ProviderState { authService.providerState }

    var body: some View {
        AccountSecurityContent(
            email: email,
            providerState: providerState,
            statusMessage: statusMessage,
            errorMessage: errorMessage,
            showDeleteConfirm: $showDeleteConfirm,
            onChangeEmail: { activeSheet = .changeEmail },
            onChangePassword: { activeSheet = .changePassword },
            onAddPassword: { activeSheet = .addPassword },
            onLinkApple: linkApple,
            onUnlinkApple: { unlink(ProviderState.appleProviderID, name: "Apple") },
            onLinkGoogle: linkGoogle,
            onUnlinkGoogle: { unlink(ProviderState.googleProviderID, name: "Google") },
            onDeleteAccount: startDelete
        )
        .navigationBarHidden(true)
        // Refresh provider state on appear, and heal the local email if the user
        // completed a verifyBeforeUpdateEmail flow out-of-band.
        .task {
            await authService.refreshProviderState()
            await authService.reconcileEmailIfChanged()
        }
        .overlay { if isBusy { busyOverlay } }
        .sheet(item: $activeSheet) { sheet in sheetView(for: sheet) }
    }

    // MARK: - Busy overlay

    private var busyOverlay: some View {
        ZStack {
            Color.black.opacity(0.2).ignoresSafeArea()
            ProgressView()
                .scaleEffect(1.3)
                .tint(Color.risoInk)
                .padding(28)
                .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(Color.risoPaper))
                .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
        }
    }

    // MARK: - Sheets

    private enum ActiveSheet: Identifiable {
        case changeEmail, changePassword, addPassword, reauth
        var id: Int {
            switch self {
            case .changeEmail: return 0
            case .changePassword: return 1
            case .addPassword: return 2
            case .reauth: return 3
            }
        }
    }

    @ViewBuilder
    private func sheetView(for sheet: ActiveSheet) -> some View {
        switch sheet {
        case .changeEmail:
            ChangeEmailSheet(
                currentEmail: email,
                onSubmit: submitChangeEmail,
                onCancel: { activeSheet = nil }
            )
        case .changePassword:
            ChangePasswordSheet(
                onSubmit: submitChangePassword,
                onCancel: { activeSheet = nil }
            )
        case .addPassword:
            AddPasswordSheet(
                email: email,
                onSubmit: submitAddPassword,
                onCancel: { activeSheet = nil }
            )
        case .reauth:
            ReauthSheet(
                providerState: providerState,
                reauthPassword: { try await authService.reauthenticateWithPassword($0) },
                reauthGoogle: reauthGoogle,
                reauthApple: reauthApple,
                onSuccess: afterReauthSuccess,
                onCancel: cancelReauth
            )
        }
    }

    // MARK: - Submit handlers

    private func submitChangePassword(_ newPassword: String) {
        activeSheet = nil
        runSensitive({ try await authService.updatePassword(to: newPassword) },
                     success: "Password updated.")
    }

    private func submitChangeEmail(_ newEmail: String) {
        activeSheet = nil
        runSensitive({ try await authService.updateEmail(to: newEmail) },
                     success: "Verification link sent to \(newEmail). Tap it there to finish the change.")
    }

    private func submitAddPassword(_ newEmail: String, _ password: String) {
        activeSheet = nil
        runSensitive({ try await authService.linkPassword(email: newEmail, password: password) },
                     success: "Password added — you can now sign in with email.")
    }

    // MARK: - Link / unlink / delete

    private func linkGoogle() {
        runSensitive({
            guard let vc = UIApplication.currentRootViewController else { throw AuthServiceError.noCurrentUser }
            try await authService.linkGoogle(presenting: vc)
        }, success: "Google connected.")
    }

    private func linkApple() {
        runSensitive({
            let (authorization, nonce) = try await appleCoordinator.authenticate()
            try await authService.linkApple(authorization: authorization, rawNonce: nonce)
        }, success: "Apple connected.")
    }

    private func unlink(_ providerID: String, name: String) {
        runSensitive({ try await authService.unlinkProvider(providerID) },
                     success: "\(name) disconnected.")
    }

    /// Delete reauths proactively (before any work) so we never run the
    /// server-side Firestore purge and then fail at `currentUser.delete()`,
    /// leaving a half-deleted account.
    private func startDelete() {
        pendingRetry = { try await authService.deleteAccount() }
        pendingSuccessMessage = ""
        activeSheet = .reauth
    }

    // MARK: - Reauth helpers

    private func reauthGoogle() async throws {
        guard let vc = UIApplication.currentRootViewController else { throw AuthServiceError.noCurrentUser }
        try await authService.reauthenticateWithGoogle(presenting: vc)
    }

    private func reauthApple() async throws {
        let (authorization, nonce) = try await appleCoordinator.authenticate()
        try await authService.reauthenticateWithApple(authorization: authorization, rawNonce: nonce)
    }

    private func afterReauthSuccess() {
        activeSheet = nil
        guard let retry = pendingRetry else { return }
        let message = pendingSuccessMessage ?? ""
        pendingRetry = nil
        pendingSuccessMessage = nil
        runSensitive(retry, success: message)
    }

    private func cancelReauth() {
        activeSheet = nil
        pendingRetry = nil
        pendingSuccessMessage = nil
    }

    // MARK: - Sensitive-op runner

    /// Runs a security-sensitive op with a busy spinner. On `requiresRecentLogin`
    /// it stashes the op + presents the reauth sheet (the op re-runs on reauth
    /// success). User cancellations are swallowed silently.
    private func runSensitive(_ op: @escaping () async throws -> Void, success: String) {
        isBusy = true
        errorMessage = nil
        statusMessage = nil
        _Concurrency.Task {
            // `defer` guarantees the spinner clears on every exit path (including
            // the early return below), so no future edit can strand it.
            defer { isBusy = false }
            do {
                try await op()
                statusMessage = success.isEmpty ? nil : success
            } catch {
                if AuthService.isAuthCancellation(error) {
                    // User backed out — no error.
                } else if AuthService.isRecentLoginRequired(error) {
                    pendingRetry = op
                    pendingSuccessMessage = success
                    activeSheet = .reauth
                    return
                } else {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Presentational content (snapshot-testable leaf)

/// Pure-props rendering of the Account & security page. No environment, DB, or
/// Firebase dependency — emits actions through closures so it renders in
/// snapshot tests with a plain `ProviderState`.
struct AccountSecurityContent: View {

    let email: String
    let providerState: ProviderState
    var statusMessage: String? = nil
    var errorMessage: String? = nil
    @Binding var showDeleteConfirm: Bool

    var onChangeEmail: () -> Void = {}
    var onChangePassword: () -> Void = {}
    var onAddPassword: () -> Void = {}
    var onLinkApple: () -> Void = {}
    var onUnlinkApple: () -> Void = {}
    var onLinkGoogle: () -> Void = {}
    var onUnlinkGoogle: () -> Void = {}
    var onDeleteAccount: () -> Void = {}

    var body: some View {
        ZStack {
            RisoPaperBackground()
            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 0) {
                    RisoSubPageHeader(title: "Account & security")
                        .padding(.top, 16).padding(.bottom, 20)

                    if let statusMessage { banner(statusMessage, color: .risoGreen) }
                    if let errorMessage { banner(errorMessage, color: .risoRed) }

                    sectionLabel("Sign in")
                    signInCard.padding(.horizontal, Riso.gutter).padding(.bottom, 6)
                    caption(signInCaption)

                    sectionLabel("Connected accounts")
                    connectedCard.padding(.horizontal, Riso.gutter).padding(.bottom, 6)
                    caption("Keep at least one way to sign in. You can't remove your only method.")

                    sectionLabel("Danger zone")
                    dangerCard

                    Text("Deleting your account removes all of your data from this device and our servers. It can't be undone.")
                        .font(.risoBody(12, .regular)).foregroundStyle(Color.risoMuted)
                        .multilineTextAlignment(.center).frame(maxWidth: .infinity)
                        .padding(.horizontal, Riso.gutter).padding(.bottom, 24)
                }
            }
        }
    }

    private var signInCaption: String {
        providerState.hasPassword
            ? "Changing your email sends a verification link to the new address; it finishes once you tap it."
            : "You sign in with Apple or Google. Add a password to also sign in with email."
    }

    // MARK: - Sign in card

    private var signInCard: some View {
        VStack(spacing: 0) {
            RisoProfileRow(icon: "envelope", label: "Email", value: email)
            rowDivider
            if providerState.hasPassword {
                tapRow(icon: "envelope.badge", label: "Change email", action: onChangeEmail)
                rowDivider
                tapRow(icon: "lock.rotation", label: "Change password", action: onChangePassword)
            } else {
                tapRow(icon: "key.fill", label: "Add a password", action: onAddPassword)
            }
        }
        .risoCard()
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
    }

    // MARK: - Connected accounts card

    private var connectedCard: some View {
        VStack(spacing: 0) {
            connectedRow(name: "Apple", icon: "apple.logo",
                         linked: providerState.hasApple,
                         onLink: onLinkApple, onUnlink: onUnlinkApple)
            rowDivider
            connectedRow(name: "Google", icon: "globe",
                         linked: providerState.hasGoogle,
                         onLink: onLinkGoogle, onUnlink: onUnlinkGoogle)
        }
        .risoCard()
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
    }

    private func connectedRow(name: String, icon: String, linked: Bool,
                              onLink: @escaping () -> Void,
                              onUnlink: @escaping () -> Void) -> some View {
        HStack(spacing: 12) {
            iconSquare(icon)
            Text(name).font(.risoBody(14, .bold)).foregroundStyle(Color.risoInk)
            Spacer()
            if linked {
                HStack(spacing: 6) {
                    Circle().fill(Color.risoGreen).frame(width: 8, height: 8)
                        .overlay(Circle().strokeBorder(Color.risoInk, lineWidth: 1))
                    Text("Connected").risoSub()
                }
                if !providerState.isLastProvider {
                    Button(action: onUnlink) {
                        Text("Disconnect")
                            .font(.risoBody(12, .bold))
                            .foregroundStyle(Color.risoRed)
                    }
                    .buttonStyle(.plain)
                    .padding(.leading, 4)
                }
            } else {
                Button(action: onLink) {
                    HStack(spacing: 4) {
                        Text("Connect").risoSub()
                        Image(systemName: "chevron.right")
                            .font(.system(size: 12, weight: .bold))
                            .foregroundStyle(Color.risoMuted)
                    }
                }
                .buttonStyle(.plain)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, Riso.cardPadding)
    }

    // MARK: - Danger zone card

    private var dangerCard: some View {
        Group {
            if showDeleteConfirm {
                VStack(spacing: 12) {
                    Text("Delete your account?")
                        .font(.risoBody(14, .bold))
                        .foregroundStyle(Color.risoRed)
                        .frame(maxWidth: .infinity, alignment: .center)
                        .padding(.top, 14)

                    Text("This erases every board, streak, and GREENLOG. It can't be undone.")
                        .font(.risoBody(12, .regular))
                        .foregroundStyle(Color.risoMuted)
                        .multilineTextAlignment(.center)
                        .fixedSize(horizontal: false, vertical: true)

                    HStack(spacing: 10) {
                        RisoButton(title: "Cancel", kind: .neutral, fullWidth: true) {
                            showDeleteConfirm = false
                        }
                        RisoButton(title: "Delete forever", kind: .primary, fullWidth: true) {
                            onDeleteAccount()
                        }
                    }
                    .padding(.bottom, 14)
                }
                .padding(.horizontal, Riso.cardPadding)
                .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(Color.risoPaper2))
                .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
                .overlay(
                    RoundedRectangle(cornerRadius: Riso.cardRadius)
                        .strokeBorder(Color.risoRed.opacity(0.6),
                                      style: StrokeStyle(lineWidth: 2, dash: [6, 4]))
                )
                .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
            } else {
                Button { showDeleteConfirm = true } label: {
                    RisoProfileRow(icon: "trash", label: "Delete account", danger: true)
                }
                .buttonStyle(.plain)
                .risoCard()
                .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
            }
        }
        .padding(.horizontal, Riso.gutter)
        .padding(.bottom, 18)
    }

    // MARK: - Row + layout helpers

    private func tapRow(icon: String, label: String, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            RisoProfileRow(icon: icon, label: label, chevron: true)
        }
        .buttonStyle(.plain)
    }

    private func sectionLabel(_ title: String) -> some View {
        Text(title).risoSectionLabel()
            .padding(.horizontal, Riso.gutter).padding(.bottom, 8)
    }

    private func caption(_ text: String) -> some View {
        Text(text)
            .font(.risoBody(12, .regular)).foregroundStyle(Color.risoMuted)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, Riso.gutter).padding(.bottom, 18)
    }

    private func banner(_ text: String, color: Color) -> some View {
        Text(text)
            .font(.risoBody(13, .semibold)).foregroundStyle(color)
            .frame(maxWidth: .infinity, alignment: .leading)
            .fixedSize(horizontal: false, vertical: true)
            .padding(12)
            .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(Color.risoPaper))
            .overlay(RoundedRectangle(cornerRadius: Riso.cardRadius)
                .strokeBorder(color.opacity(0.5), lineWidth: Riso.Keyline.dense))
            .padding(.horizontal, Riso.gutter).padding(.bottom, 14)
    }

    private var rowDivider: some View {
        Divider().background(Color.risoInk.opacity(0.12))
            .padding(.horizontal, Riso.cardPadding)
    }

    private func iconSquare(_ systemName: String) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(Color.risoInk)
            .frame(width: 26, height: 26)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.risoPaper))
            .overlay(RoundedRectangle(cornerRadius: 6)
                .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
    }
}

// MARK: - Sheets

/// Shared bottom-sheet chrome for the account flows: paper background, a title +
/// Cancel header, and a `.medium` detent.
private struct AccountSheetScaffold<Content: View>: View {
    let title: String
    let onCancel: () -> Void
    @ViewBuilder var content: Content

    var body: some View {
        ZStack {
            RisoPaperBackground().ignoresSafeArea()
            VStack(alignment: .leading, spacing: 18) {
                HStack {
                    Text(title).font(.risoHead(22, .extraBold)).foregroundStyle(Color.risoInk)
                    Spacer()
                    Button("Cancel", action: onCancel)
                        .font(.risoBody(14, .semibold)).foregroundStyle(Color.risoMuted)
                }
                content
                Spacer(minLength: 0)
            }
            .padding(24)
        }
        .presentationDetents([.medium])
    }
}

private struct ChangePasswordSheet: View {
    var onSubmit: (String) -> Void
    var onCancel: () -> Void

    @State private var password = ""
    @State private var confirm = ""

    private var valid: Bool { password.count >= 6 && password == confirm }

    var body: some View {
        AccountSheetScaffold(title: "Change password", onCancel: onCancel) {
            VStack(alignment: .leading, spacing: 12) {
                RisoSecureField(placeholder: "New password", text: $password, textContentType: .newPassword)
                RisoSecureField(placeholder: "Confirm new password", text: $confirm, textContentType: .newPassword)

                if !password.isEmpty && password.count < 6 {
                    hint("Use at least 6 characters.")
                } else if !confirm.isEmpty && password != confirm {
                    hint("Passwords don't match.")
                }

                RisoButton(title: "Update password", kind: .primary, fullWidth: true) {
                    onSubmit(password)
                }
                .disabled(!valid)
                .opacity(valid ? 1 : 0.5)
            }
        }
    }

    private func hint(_ text: String) -> some View {
        Text(text).font(.risoBody(12, .regular)).foregroundStyle(Color.risoRed)
    }
}

private struct ChangeEmailSheet: View {
    let currentEmail: String
    var onSubmit: (String) -> Void
    var onCancel: () -> Void

    @State private var newEmail = ""

    private var valid: Bool {
        newEmail.contains("@") && newEmail.contains(".") && newEmail != currentEmail
    }

    var body: some View {
        AccountSheetScaffold(title: "Change email", onCancel: onCancel) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Current: \(currentEmail)")
                    .font(.risoBody(13, .regular)).foregroundStyle(Color.risoMuted)

                RisoTextField(placeholder: "New email", text: $newEmail)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                Text("We'll send a verification link to the new address. The change finishes once you tap it.")
                    .font(.risoBody(12, .regular)).foregroundStyle(Color.risoMuted)
                    .fixedSize(horizontal: false, vertical: true)

                RisoButton(title: "Send verification", kind: .primary, fullWidth: true) {
                    onSubmit(newEmail.trimmingCharacters(in: .whitespacesAndNewlines))
                }
                .disabled(!valid)
                .opacity(valid ? 1 : 0.5)
            }
        }
    }
}

private struct AddPasswordSheet: View {
    var onSubmit: (String, String) -> Void
    var onCancel: () -> Void

    @State private var email: String
    @State private var password = ""

    init(email: String, onSubmit: @escaping (String, String) -> Void, onCancel: @escaping () -> Void) {
        self.onSubmit = onSubmit
        self.onCancel = onCancel
        _email = State(initialValue: email == "—" ? "" : email)
    }

    private var valid: Bool { email.contains("@") && email.contains(".") && password.count >= 6 }

    var body: some View {
        AccountSheetScaffold(title: "Add a password", onCancel: onCancel) {
            VStack(alignment: .leading, spacing: 12) {
                Text("Add an email + password so you can sign in without Apple or Google.")
                    .font(.risoBody(12, .regular)).foregroundStyle(Color.risoMuted)
                    .fixedSize(horizontal: false, vertical: true)

                RisoTextField(placeholder: "Email", text: $email)
                    .keyboardType(.emailAddress)
                    .textContentType(.emailAddress)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()

                RisoSecureField(placeholder: "Password", text: $password, textContentType: .newPassword)

                RisoButton(title: "Add password", kind: .primary, fullWidth: true) {
                    onSubmit(email.trimmingCharacters(in: .whitespacesAndNewlines), password)
                }
                .disabled(!valid)
                .opacity(valid ? 1 : 0.5)
            }
        }
    }
}

/// Reauthentication sheet shown when a security-sensitive op needs a fresh
/// login. Offers every linked provider; runs the chosen reauth and calls
/// `onSuccess` (which retries the pending op). Owns its own busy/error state.
private struct ReauthSheet: View {
    let providerState: ProviderState
    var reauthPassword: (String) async throws -> Void = { _ in }
    var reauthGoogle: () async throws -> Void = {}
    var reauthApple: () async throws -> Void = {}
    var onSuccess: () -> Void = {}
    var onCancel: () -> Void = {}

    @State private var password = ""
    @State private var busy = false
    @State private var error: String?

    var body: some View {
        AccountSheetScaffold(title: "Confirm it's you", onCancel: onCancel) {
            VStack(alignment: .leading, spacing: 14) {
                Text("For your security, please sign in again to continue.")
                    .font(.risoBody(13, .regular)).foregroundStyle(Color.risoMuted)
                    .fixedSize(horizontal: false, vertical: true)

                if let error {
                    Text(error).font(.risoBody(12, .regular)).foregroundStyle(Color.risoRed)
                }

                if providerState.hasPassword {
                    RisoSecureField(placeholder: "Current password", text: $password, textContentType: .password)
                    RisoButton(title: busy ? "Verifying…" : "Verify", kind: .primary, fullWidth: true) {
                        run { try await reauthPassword(password) }
                    }
                    .disabled(busy || password.isEmpty)
                    .opacity(busy || password.isEmpty ? 0.5 : 1)
                }
                if providerState.hasGoogle {
                    RisoButton(title: "Continue with Google", kind: .neutral, systemImage: "globe", fullWidth: true) {
                        run { try await reauthGoogle() }
                    }
                    .disabled(busy)
                }
                if providerState.hasApple {
                    RisoButton(title: "Continue with Apple", kind: .neutral, systemImage: "apple.logo", fullWidth: true) {
                        run { try await reauthApple() }
                    }
                    .disabled(busy)
                }
            }
        }
    }

    private func run(_ op: @escaping () async throws -> Void) {
        guard !busy else { return } // ignore re-taps while a reauth is in flight
        busy = true
        error = nil
        _Concurrency.Task {
            do {
                try await op()
                // Success hands off to the container (dismisses this sheet +
                // retries the pending op); leave `busy` set so the buttons stay
                // disabled during the brief dismissal rather than flashing back.
                onSuccess()
                return
            } catch {
                if !AuthService.isAuthCancellation(error) {
                    self.error = error.localizedDescription
                }
            }
            busy = false
        }
    }
}
