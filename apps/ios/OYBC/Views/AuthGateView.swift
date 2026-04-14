import SwiftUI
import AuthenticationServices
import CryptoKit

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
    let content: () -> Content

    var body: some View {
        Group {
            if authService.isLoading {
                loadingView
            } else if authService.currentUser != nil {
                content()
                    .environmentObject(authService)
                    .environmentObject(authService.syncService)
            } else {
                LoginView(authService: authService)
            }
        }
    }

    private var loadingView: some View {
        VStack(spacing: 16) {
            ProgressView()
                .scaleEffect(1.4)
            Text("Loading…")
                .font(.subheadline)
                .foregroundStyle(.secondary)
        }
    }
}

// MARK: - LoginView

/// The sign-in / create-account form rendered by `AuthGateView`.
///
/// Supports email/password, Google Sign-In, and Sign in with Apple.
private struct LoginView: View {
    @ObservedObject var authService: AuthService

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
            .navigationTitle("")
            .toolbar(.hidden, for: .navigationBar)
        }
    }

    // MARK: - Subviews

    private var headerSection: some View {
        VStack(spacing: 8) {
            Text("OYBC")
                .font(.largeTitle.bold())
            Text(isCreatingAccount ? "Create an account" : "Welcome back")
                .font(.title3)
                .foregroundStyle(.secondary)
        }
    }

    private var emailPasswordSection: some View {
        VStack(spacing: 16) {
            if let errorMessage {
                errorBanner(errorMessage)
            }

            TextField("Email", text: $email)
                .keyboardType(.emailAddress)
                .textContentType(.emailAddress)
                .autocapitalization(.none)
                .textFieldStyle(.roundedBorder)

            SecureField("Password", text: $password)
                .textContentType(isCreatingAccount ? .newPassword : .password)
                .textFieldStyle(.roundedBorder)

            SwiftUI.Button(action: {
                _Concurrency.Task { await submitEmailPassword() }
            }, label: {
                Group {
                    if isSubmitting {
                        ProgressView()
                            .tint(.white)
                    } else {
                        Text(isCreatingAccount ? "Create Account" : "Sign In")
                            .fontWeight(.semibold)
                    }
                }
                .frame(maxWidth: .infinity)
                .frame(height: 50)
            })
            .buttonStyle(.borderedProminent)
            .disabled(isSubmitting || email.isEmpty || password.isEmpty)

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
                .font(.footnote)
                .foregroundStyle(.secondary)
            })
        }
    }

    private var dividerSection: some View {
        HStack {
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(.quaternary)
            Text("or")
                .font(.footnote)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 8)
            Rectangle()
                .frame(height: 1)
                .foregroundStyle(.quaternary)
        }
    }

    private var socialSignInSection: some View {
        VStack(spacing: 12) {
            googleSignInButton
            appleSignInButton
        }
    }

    private var googleSignInButton: some View {
        SwiftUI.Button(action: {
            _Concurrency.Task { await signInWithGoogle() }
        }, label: {
            HStack(spacing: 8) {
                Image(systemName: "globe")
                    .imageScale(.medium)
                Text("Continue with Google")
                    .fontWeight(.medium)
            }
            .frame(maxWidth: .infinity)
            .frame(height: 50)
        })
        .buttonStyle(.bordered)
        .disabled(isSubmitting)
    }

    private var appleSignInButton: some View {
        SignInWithAppleButton(
            isCreatingAccount ? .signUp : .signIn,
            onRequest: { request in
                let nonce = randomNonceString()
                currentNonce = nonce
                request.requestedScopes = [.fullName, .email]
                request.nonce = sha256(nonce)
            },
            onCompletion: { (result: Result<ASAuthorization, Error>) in
                _Concurrency.Task { await handleAppleSignIn(result) }
            }
        )
        .signInWithAppleButtonStyle(.black)
        .frame(height: 50)
        .disabled(isSubmitting)
    }

    @ViewBuilder
    private func errorBanner(_ message: String) -> some View {
        HStack(spacing: 8) {
            Image(systemName: "exclamationmark.circle.fill")
                .foregroundStyle(.red)
            Text(message)
                .font(.footnote)
                .foregroundStyle(.red)
            Spacer()
        }
        .padding(12)
        .background(.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
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

        guard
            let windowScene = UIApplication.shared.connectedScenes.first as? UIWindowScene,
            let rootVC = windowScene.windows.first?.rootViewController
        else {
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

    // MARK: - Nonce Helpers (Apple Sign-In)

    /// Generates a cryptographically random nonce string of the given byte length.
    ///
    /// - Parameter length: Number of random bytes (default 32).
    /// - Returns: A URL-safe Base64-encoded nonce string.
    private func randomNonceString(length: Int = 32) -> String {
        var randomBytes = [UInt8](repeating: 0, count: length)
        let errorCode = SecRandomCopyBytes(kSecRandomDefault, length, &randomBytes)
        guard errorCode == errSecSuccess else {
            // Fallback to UUID-based nonce if secure random fails
            return UUID().uuidString + UUID().uuidString
        }
        return Data(randomBytes).base64EncodedString()
            .replacingOccurrences(of: "+", with: "-")
            .replacingOccurrences(of: "/", with: "_")
            .replacingOccurrences(of: "=", with: "")
            .trimmingCharacters(in: .whitespaces)
    }

    /// Returns the SHA-256 hash of the given string as a lowercase hex string.
    ///
    /// - Parameter input: The raw nonce string.
    /// - Returns: The SHA-256 hex digest.
    private func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashedData = SHA256.hash(data: inputData)
        return hashedData.compactMap { String(format: "%02x", $0) }.joined()
    }
}

// MARK: - Preview

#Preview("Signed Out") {
    AuthGateView {
        Text("Signed in!")
    }
}
