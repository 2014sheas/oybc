import SwiftUI
import AuthenticationServices

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
    @StateObject private var authService = AuthService()
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
                LoginView(authService: authService)
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
    @State private var isCreatingAccount: Bool = false
    @State private var isSubmitting: Bool = false
    @State private var errorMessage: String?

    // Apple Sign-In nonce — generated fresh per request.
    @State private var currentNonce: String?

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
            }

            RisoTextField(placeholder: "Email", text: $email)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .textInputAutocapitalization(.never)
                .autocorrectionDisabled()

            RisoSecureField(
                placeholder: "Password",
                text: $password,
                textContentType: isCreatingAccount ? .newPassword : .password
            )

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
        // would vanish, so use the light glyph there.
        .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
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

    // MARK: - Actions

    private func submitEmailPassword() async {
        isSubmitting = true
        errorMessage = nil
        defer { isSubmitting = false }

        do {
            if isCreatingAccount {
                try await authService.signUp(email: email, password: password)
            } else {
                try await authService.signIn(email: email, password: password)
            }
        } catch {
            errorMessage = error.localizedDescription
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
            errorMessage = error.localizedDescription
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
                errorMessage = error.localizedDescription
            }
        case .failure(let error):
            // ASAuthorizationError.canceled (1001) is user-initiated; suppress it.
            let asError = error as? ASAuthorizationError
            if asError?.code != .canceled {
                errorMessage = error.localizedDescription
            }
        }
    }
}

// MARK: - Preview

#Preview("Signed Out") {
    AuthGateView {
        Text("Signed in!")
    }
}
