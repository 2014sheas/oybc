import SwiftUI
import AuthenticationServices
import FirebaseAuth

/// AuthGateView - Wraps any content behind authentication
///
/// Shows a loading spinner until the Firebase auth state resolves, then
/// either presents the wrapped content (signed in) or the login/register
/// form (signed out).
///
/// Usage:
/// ```swift
/// AuthGateView {
///     MainAppView()
/// }
/// ```
struct AuthGateView<Content: View>: View {
    @ObservedObject var authService: AuthService
    /// Mode the login form opens in when it first appears: true = "Create an
    /// account" (a first-run user arriving from onboarding), false = "Welcome
    /// back". Read only when the form is created; a later change (onboarding
    /// finishing) doesn't flip a form already on screen.
    var loginStartsInCreateAccount: Bool = false
    @StateObject private var networkMonitor = NetworkMonitor()
    @StateObject private var tutorialStore = TutorialProgressStore()
    let content: () -> Content

    var body: some View {
        Group {
            if authService.isLoading {
                loadingView
            } else if authService.currentUser != nil {
                content()
                    .environmentObject(authService)
                    .environmentObject(authService.syncService)
                    .environmentObject(authService.notificationService)
                    .environmentObject(NotificationDelegate.shared)
                    .environmentObject(networkMonitor)
                    .environmentObject(tutorialStore)
            } else {
                LoginView(authService: authService, startsInCreateAccount: loginStartsInCreateAccount)
            }
        }
    }

    private var loadingView: some View {
        ZStack {
            RisoPaperBackground().ignoresSafeArea()
            VStack(spacing: 16) {
                ProgressView()
                    .scaleEffect(1.4)
                    .tint(Color.risoInk)
                Text("Loading…")
                    .font(.risoBody(14, .semibold))
                    .foregroundStyle(Color.risoMuted)
            }
        }
    }
}

// MARK: - LoginView

/// The sign-in / create-account form rendered by `AuthGateView`.
///
/// Supports email/password, Google Sign-In, and Sign in with Apple.
private struct LoginView: View {
    @ObservedObject var authService: AuthService
    @Environment(\.colorScheme) private var colorScheme

    // MARK: Form state

    @State private var email: String = ""
    @State private var password: String = ""
    @State private var isCreatingAccount: Bool
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?
    /// "Reset link sent to …" after a "Forgot password?" send; cleared when the
    /// email, the mode, or the next submission changes the context.
    @State private var statusMessage: String?

    // Apple Sign-In nonce — generated fresh per request.
    @State private var currentNonce: String?

    /// - Parameters:
    ///   - authService: The shared auth service.
    ///   - startsInCreateAccount: Open in "Create an account" mode (first run).
    init(authService: AuthService, startsInCreateAccount: Bool) {
        self.authService = authService
        _isCreatingAccount = State(initialValue: startsInCreateAccount)
    }

    var body: some View {
        NavigationStack {
            ZStack {
                RisoPaperBackground().ignoresSafeArea()
                ScrollView {
                    VStack(spacing: 28) {
                        headerSection
                        emailPasswordSection
                        dividerSection
                        socialSignInSection
                    }
                    .padding(.horizontal, 24)
                    .padding(.top, 48)
                    .padding(.bottom, 32)
                }
            }
            .navigationTitle("")
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // MARK: - Subviews

    private var headerSection: some View {
        VStack(spacing: 8) {
            Text("OYBC")
                .font(.risoHead(40, .extraBold))
                .foregroundStyle(Color.risoInk)
            Text(isCreatingAccount ? "Create an account" : "Welcome back")
                .font(.risoBody(16, .semibold))
                .foregroundStyle(Color.risoMuted)
        }
    }

    private var emailPasswordSection: some View {
        VStack(spacing: 14) {
            if let errorMessage {
                errorBanner(errorMessage)
            } else if let statusMessage {
                statusBanner(statusMessage)
            }

            RisoTextField(placeholder: "Email", text: $email)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()
                .onChange(of: email) { _, _ in statusMessage = nil }

            RisoSecureField(
                placeholder: "Password",
                text: $password,
                textContentType: isCreatingAccount ? .newPassword : .password
            )

            if !isCreatingAccount {
                forgotPasswordButton
            }

            RisoButton(
                title: isSubmitting
                    ? "Please wait…"
                    : (isCreatingAccount ? "Create account" : "Sign in"),
                kind: .primary,
                fullWidth: true,
                large: true
            ) {
                _Concurrency.Task { await submitEmailPassword() }
            }
            .disabled(isSubmitting || email.isEmpty || password.isEmpty)
            .opacity(isSubmitting || email.isEmpty || password.isEmpty ? 0.55 : 1)

            SwiftUI.Button(action: {
                withAnimation(.easeInOut(duration: 0.2)) {
                    isCreatingAccount.toggle()
                    errorMessage = nil
                    statusMessage = nil
                }
            }, label: {
                Text(
                    isCreatingAccount
                        ? "Already have an account? Sign in"
                        : "Don't have an account? Create one"
                )
                .font(.risoBody(13, .semibold))
                .foregroundStyle(Color.risoMuted)
            })
        }
    }

    /// "Forgot password?" — sends a reset link to the email typed above. Gated
    /// like "Sign in": disabled while the email field is empty or a request is
    /// in flight; a malformed address comes back as the form's error banner.
    private var forgotPasswordButton: some View {
        let isEmailEmpty = PasswordReset.normalizedEmail(email).isEmpty
        return SwiftUI.Button("Forgot password?") {
            _Concurrency.Task { await sendPasswordReset() }
        }
        .font(.risoBody(13, .semibold))
        .foregroundStyle(Color.risoMuted)
        .frame(maxWidth: .infinity, alignment: .trailing)
        .disabled(isSubmitting || isEmailEmpty)
        .opacity(isSubmitting || isEmailEmpty ? 0.55 : 1)
    }

    private var dividerSection: some View {
        HStack(spacing: 8) {
            Rectangle()
                .fill(Color.risoInk.opacity(0.2))
                .frame(height: 1)
            Text("or")
                .font(.risoBody(12, .bold))
                .foregroundStyle(Color.risoMuted)
            Rectangle()
                .fill(Color.risoInk.opacity(0.2))
                .frame(height: 1)
        }
    }

    private var socialSignInSection: some View {
        VStack(spacing: 12) {
            googleSignInButton
            appleSignInButton

            // Continue as guest — Firebase anonymous session (docs/GUEST_MODE.md).
            // Keeps guest mode reachable after first-run onboarding / after a
            // sign-out, mirroring web's always-available "Continue without an
            // account". Upgradeable later via Profile → Save your account.
            SwiftUI.Button("Continue as guest") {
                _Concurrency.Task { await signInAsGuest() }
            }
            .font(.risoBody(14, .semibold))
            .foregroundStyle(Color.risoMuted)
            .disabled(isSubmitting)
            .padding(.top, 4)
        }
    }

    private var googleSignInButton: some View {
        RisoButton(
            title: "Continue with Google",
            kind: .neutral,
            systemImage: "globe",
            fullWidth: true,
            large: true
        ) {
            _Concurrency.Task { await signInWithGoogle() }
        }
        .disabled(isSubmitting)
    }

    private var appleSignInButton: some View {
        SignInWithAppleButton(
            isCreatingAccount ? .signUp : .signIn,
            onRequest: { request in
                let nonce = AppleAuthNonce.randomNonceString()
                currentNonce = nonce
                request.requestedScopes = [.fullName, .email]
                request.nonce = AppleAuthNonce.sha256(nonce)
            },
            onCompletion: { (result: Result<ASAuthorization, Error>) in
                _Concurrency.Task { await handleAppleSignIn(result) }
            }
        )
        // Dark mode flips the Riso paper near-black; a `.black` Apple button
        // would vanish, so use the light glyph there. The system button
        // doesn't restyle in place, so rebuild it when the scheme flips.
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
        .id(colorScheme)
        .frame(height: 50)
        .disabled(isSubmitting)
    }

    @ViewBuilder
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(Color.risoRed)
            Text(message)
                .font(.risoBody(13, .semibold))
                .foregroundStyle(Color.risoInk)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .risoCard(fill: .risoPaper)
    }

    /// One-line confirmation banner (the success twin of `errorBanner`).
    @ViewBuilder
    private func statusBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "checkmark.circle.fill")
                .foregroundStyle(Color.risoGreen)
            Text(message)
                .font(.risoBody(13, .semibold))
                .foregroundStyle(Color.risoInk)
            Spacer(minLength: 0)
        }
        .padding(12)
        .frame(maxWidth: .infinity, alignment: .leading)
        .risoCard(fill: .risoPaper)
    }

    // MARK: - Actions

    private func submitEmailPassword() async {
        isSubmitting = true
        errorMessage = nil
        statusMessage = nil
        defer { isSubmitting = false }

        do {
            if isCreatingAccount {
                try await authService.signUp(email: email, password: password)
            } else {
                try await authService.signIn(email: email, password: password)
            }
        } catch {
            errorMessage = SignInErrorMessage.message(for: error)
        }
    }

    /// Sends a password-reset link to the typed email. The confirmation is the
    /// same whether or not an account uses the address (`AuthService.
    /// sendPasswordReset(toEmail:)` is enumeration-safe); any other failure
    /// (malformed address, offline) shows in the error banner.
    private func sendPasswordReset() async {
        isSubmitting = true
        errorMessage = nil
        statusMessage = nil
        defer { isSubmitting = false }

        do {
            let sentTo = try await authService.sendPasswordReset(toEmail: email)
            statusMessage = PasswordReset.sentStatus(for: sentTo)
        } catch {
            errorMessage = SignInErrorMessage.message(for: error)
        }
    }

    private func signInWithGoogle() async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        guard let rootVC = UIApplication.currentRootViewController else {
            errorMessage = "Unable to present Google sign-in."
            return
        }

        do {
            try await authService.signInWithGoogle(presenting: rootVC)
        } catch {
            // nil for a cancelled Google sheet — backing out shows nothing.
            errorMessage = SignInErrorMessage.message(for: error)
        }
    }

    /// Guest sign-in (Firebase anonymous, docs/GUEST_MODE.md). Offline is the one
    /// dented-offline-first case — minting the anon uid needs one network round-trip
    /// — so show honest copy instead of a raw error.
    private func signInAsGuest() async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            try await authService.signInAnonymously()
        } catch {
            errorMessage = SignInErrorMessage.isOffline(error)
                ? "You're offline. Connect to continue as a guest."
                : SignInErrorMessage.message(for: error)
        }
    }

    private func handleAppleSignIn(_ result: Result<ASAuthorization, Error>) async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        switch result {
        case .success(let authorization):
            guard let nonce = currentNonce else {
                errorMessage = "Apple sign-in failed: missing nonce."
                return
            }
            do {
                try await authService.signInWithApple(authorization: authorization, rawNonce: nonce)
            } catch {
                errorMessage = SignInErrorMessage.message(for: error)
            }
        case .failure(let error):
            // A cancelled Apple sheet maps to nil — nothing shown.
            errorMessage = SignInErrorMessage.message(for: error)
        }
    }
}

// MARK: - Preview

#Preview("Signed Out") {
    AuthGateView(authService: AuthService()) {
        Text("Signed in!")
    }
}
