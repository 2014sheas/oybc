import SwiftUI
import AuthenticationServices
import FirebaseAuth

/// UpgradeAccountSheet — guest→account upgrade (docs/GUEST_MODE.md §Phase 4).
///
/// Offers Apple / Google / email+password to link onto the current Firebase
/// anonymous session. Reuses `AuthService.link*`, which already re-upserts the
/// local user (populating email/displayName) and flips `isAnonymous` to false
/// on success — so a successful link here just dismisses; the Profile guest
/// treatment clears reactively via the environment-bound `AuthService`.
///
/// **Collision edge**: if the chosen identity already belongs to a *different*
/// Firebase account (`credentialAlreadyInUse` for Apple/Google,
/// `emailAlreadyInUse` for password), merging the two Firestore trees is out
/// of scope. We confirm, then **verify before destroy**: sign into the existing
/// account FIRST while still anonymous — a wrong password / cancelled OAuth
/// throws harmlessly and leaves the guest session + local data intact. Only on
/// a successful switch do we clear the stale anon sync queue. (The earlier
/// "delete anon first, then sign in" order could wipe guest data and THEN fail
/// on a wrong password — the anon email password rarely matches the existing
/// account's.) The near-empty anonymous account orphans server-side; the guest's
/// local rows are `userId`-filtered out of every view under the new account.
struct UpgradeAccountSheet: View {
    @EnvironmentObject private var authService: AuthService
    @Environment(\.dismiss) private var dismiss

    /// Drives the programmatic Apple flow (link + the collision resign-in).
    /// Held as state so it stays retained across the async round-trip,
    /// mirroring `AccountSecurityView`.
    @State private var appleCoordinator = AppleSignInCoordinator()

    @State private var isBusy = false
    @State private var errorMessage: String?

    @State private var showEmailForm = false
    @State private var email = ""
    @State private var password = ""

    /// Which method collided with an existing account, so "Sign in" in the
    /// confirm alert knows what to re-run after the discard.
    @State private var pendingCollision: UpgradeMethod?

    private enum UpgradeMethod {
        case apple, google, email
    }

    var body: some View {
        ZStack {
            RisoPaperBackground().ignoresSafeArea()

            ScrollView(showsIndicators: false) {
                VStack(alignment: .leading, spacing: 18) {
                    header

                    Text("Link a sign-in method so your boards, tasks, and streaks are backed up and available on your other devices.")
                        .font(.risoBody(13, .regular))
                        .foregroundStyle(Color.risoMuted)
                        .fixedSize(horizontal: false, vertical: true)

                    if let errorMessage {
                        banner(errorMessage)
                    }

                    VStack(spacing: 12) {
                        RisoButton(
                            title: "Continue with Apple",
                            kind: .neutral,
                            systemImage: "apple.logo",
                            fullWidth: true,
                            large: true
                        ) {
                            linkApple()
                        }
                        .disabled(isBusy)

                        RisoButton(
                            title: "Continue with Google",
                            kind: .neutral,
                            systemImage: "globe",
                            fullWidth: true,
                            large: true
                        ) {
                            linkGoogle()
                        }
                        .disabled(isBusy)
                    }

                    dividerRow

                    if showEmailForm {
                        emailForm
                    } else {
                        SwiftUI.Button {
                            withAnimation(.easeInOut(duration: 0.2)) { showEmailForm = true }
                        } label: {
                            Text("Continue with email")
                                .font(.risoBody(14, .semibold))
                                .foregroundStyle(Color.risoInk)
                        }
                        .disabled(isBusy)
                    }
                }
                .padding(.horizontal, Riso.gutter)
                .padding(.top, 8)
                .padding(.bottom, 32)
            }
        }
        .overlay { if isBusy { busyOverlay } }
        .alert("That account already exists", isPresented: collisionAlertBinding) {
            SwiftUI.Button("Cancel", role: .cancel) { pendingCollision = nil }
            SwiftUI.Button("Sign in") { resolveCollision() }
        } message: {
            Text("Sign into it instead? You'll switch to that account — your guest boards on this device won't carry over.")
        }
    }

    // MARK: - Header

    private var header: some View {
        HStack {
            Text("Save your account")
                .font(.risoHead(22, .extraBold))
                .tracking(-0.44)
                .foregroundStyle(Color.risoInk)
            Spacer()
            SwiftUI.Button("Cancel") { dismiss() }
                .font(.risoBody(14, .semibold))
                .foregroundStyle(Color.risoMuted)
                .disabled(isBusy)
        }
        .padding(.top, 24)
    }

    // MARK: - Email form

    private var emailForm: some View {
        VStack(alignment: .leading, spacing: 12) {
            RisoTextField(placeholder: "Email", text: $email)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            RisoSecureField(placeholder: "Password", text: $password, textContentType: .newPassword)

            RisoButton(title: "Create account", kind: .primary, fullWidth: true) {
                linkPassword()
            }
            .disabled(isBusy || !emailFormValid)
            .opacity(isBusy || !emailFormValid ? 0.55 : 1)
        }
    }

    private var emailFormValid: Bool {
        email.contains("@") && email.contains(".") && password.count >= 6
    }

    // MARK: - Layout helpers

    private var dividerRow: some View {
        HStack(spacing: 8) {
            Rectangle().fill(Color.risoInk.opacity(0.2)).frame(height: 1)
            Text("or").font(.risoBody(12, .bold)).foregroundStyle(Color.risoMuted)
            Rectangle().fill(Color.risoInk.opacity(0.2)).frame(height: 1)
        }
    }

    private func banner(_ text: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.risoRed)
            Text(text)
                .font(.risoBody(13, .semibold))
                .foregroundStyle(Color.risoInk)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .risoCard(fill: .risoPaper)
    }

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

    private var collisionAlertBinding: Binding<Bool> {
        Binding(
            get: { pendingCollision != nil },
            set: { presented in if !presented { pendingCollision = nil } }
        )
    }

    // MARK: - Link actions

    private func linkApple() {
        isBusy = true
        errorMessage = nil
        _Concurrency.Task {
            defer { isBusy = false }
            do {
                let (authorization, nonce) = try await appleCoordinator.authenticate()
                try await authService.linkApple(authorization: authorization, rawNonce: nonce)
                dismiss()
            } catch {
                handleLinkFailure(error, method: .apple)
            }
        }
    }

    private func linkGoogle() {
        isBusy = true
        errorMessage = nil
        _Concurrency.Task {
            defer { isBusy = false }
            do {
                guard let vc = UIApplication.currentRootViewController else {
                    throw AuthServiceError.noCurrentUser
                }
                try await authService.linkGoogle(presenting: vc)
                dismiss()
            } catch {
                handleLinkFailure(error, method: .google)
            }
        }
    }

    private func linkPassword() {
        isBusy = true
        errorMessage = nil
        let trimmedEmail = email.trimmingCharacters(in: .whitespacesAndNewlines)
        email = trimmedEmail
        _Concurrency.Task {
            defer { isBusy = false }
            do {
                try await authService.linkPassword(email: trimmedEmail, password: password)
                dismiss()
            } catch {
                handleLinkFailure(error, method: .email)
            }
        }
    }

    /// Shared failure path for all three link attempts: swallow user
    /// cancellations, route a collision into the confirm alert, otherwise
    /// surface the error inline.
    private func handleLinkFailure(_ error: Error, method: UpgradeMethod) {
        if AuthService.isAuthCancellation(error) { return }
        if AuthService.isCredentialCollision(error) {
            pendingCollision = method
            return
        }
        errorMessage = error.localizedDescription
    }

    // MARK: - Collision resolution

    /// Runs on "Sign in" in the collision alert. **Verify before destroy**: sign
    /// into the pre-existing account FIRST while still anonymous. A wrong password
    /// or cancelled OAuth throws here and leaves the guest session + local data
    /// intact (the old "delete anon first" order could wipe guest data and then
    /// fail on a wrong password). On success we've switched accounts; clear the
    /// stale anon sync queue so its pending pushes don't fail under the new uid.
    /// Apple's authorization is single-use, so it's re-requested.
    private func resolveCollision() {
        guard let method = pendingCollision else { return }
        pendingCollision = nil
        isBusy = true
        errorMessage = nil
        _Concurrency.Task {
            defer { isBusy = false }
            do {
                switch method {
                case .apple:
                    let (authorization, nonce) = try await appleCoordinator.authenticate()
                    try await authService.signInWithApple(authorization: authorization, rawNonce: nonce)
                case .google:
                    guard let vc = UIApplication.currentRootViewController else {
                        throw AuthServiceError.noCurrentUser
                    }
                    try await authService.signInWithGoogle(presenting: vc)
                case .email:
                    try await authService.signIn(email: email, password: password)
                }
                // Switched to the existing account — drop the discarded guest's
                // anon-stamped pending pushes (see the type doc).
                authService.clearPendingSyncQueue()
                dismiss()
            } catch {
                if !AuthService.isAuthCancellation(error) {
                    errorMessage = error.localizedDescription
                }
            }
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview {
    UpgradeAccountSheet()
        .environmentObject(AuthService())
}
#endif
