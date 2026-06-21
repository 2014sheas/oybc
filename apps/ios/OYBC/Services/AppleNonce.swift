import Foundation
import CryptoKit
import UIKit
import AuthenticationServices

/// Apple Sign-In nonce helpers, shared by the login flow and the
/// Account & security reauth / link flows.
///
/// "Sign in with Apple" requires a per-request nonce: the raw nonce is held by
/// the app while the SHA-256 of it is sent to Apple in the authorization
/// request. Firebase later verifies the raw nonce against the ID token. Both
/// sign-in and reauthentication run the exact same handshake, so this crypto
/// lives in one place rather than being duplicated per call site.
enum AppleAuthNonce {
    /// Generates a cryptographically random nonce string of the given byte length.
    ///
    /// - Parameter length: Number of random bytes (default 32).
    /// - Returns: A URL-safe Base64-encoded nonce string.
    static func randomNonceString(length: Int = 32) -> String {
        var randomBytes = [UInt8](repeating: 0, count: length)
        let errorCode = SecRandomCopyBytes(kSecRandomDefault, length, &randomBytes)
        guard errorCode == errSecSuccess else {
            // Fallback to UUID-based nonce if secure random fails.
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
    static func sha256(_ input: String) -> String {
        let inputData = Data(input.utf8)
        let hashedData = SHA256.hash(data: inputData)
        return hashedData.compactMap { String(format: "%02x", $0) }.joined()
    }
}

extension UIApplication {
    /// The root view controller of the app's foreground window scene, used to
    /// present provider sign-in / reauth UI (Google's flow needs a presenter).
    @MainActor
    static var currentRootViewController: UIViewController? {
        let scene = UIApplication.shared.connectedScenes
            .compactMap { $0 as? UIWindowScene }
            .first { $0.activationState == .foregroundActive }
            ?? UIApplication.shared.connectedScenes.first as? UIWindowScene

        let keyWindow = scene?.windows.first { $0.isKeyWindow } ?? scene?.windows.first
        return keyWindow?.rootViewController
    }

    /// The key window, used as the Apple authorization presentation anchor.
    @MainActor
    static var currentKeyWindow: UIWindow? {
        currentRootViewController?.view.window
    }
}

/// Drives "Sign in with Apple" programmatically (outside a SwiftUI
/// `SignInWithAppleButton`) and returns the authorization + raw nonce via
/// async/await. Used by the Account & security screen for **linking** an Apple
/// identity and for **reauthentication** — flows that aren't a fresh sign-in
/// button. The raw nonce is generated here and handed back so the caller can
/// build a Firebase credential.
@MainActor
final class AppleSignInCoordinator: NSObject {
    private var continuation: CheckedContinuation<(ASAuthorization, String), Error>?
    private var currentNonce: String?

    /// Presents the Apple authorization sheet and resolves with the resulting
    /// `(ASAuthorization, rawNonce)`. Throws on failure; an `ASAuthorizationError`
    /// with `.canceled` means the user dismissed it.
    func authenticate() async throws -> (ASAuthorization, String) {
        let nonce = AppleAuthNonce.randomNonceString()
        currentNonce = nonce

        let request = ASAuthorizationAppleIDProvider().createRequest()
        request.requestedScopes = [.fullName, .email]
        request.nonce = AppleAuthNonce.sha256(nonce)

        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self

        return try await withCheckedThrowingContinuation { continuation in
            self.continuation = continuation
            controller.performRequests()
        }
    }
}

extension AppleSignInCoordinator: ASAuthorizationControllerDelegate {
    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let nonce = currentNonce else {
            continuation?.resume(throwing: AuthServiceError.invalidAppleCredential)
            continuation = nil
            return
        }
        continuation?.resume(returning: (authorization, nonce))
        continuation = nil
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        continuation?.resume(throwing: error)
        continuation = nil
    }
}

extension AppleSignInCoordinator: ASAuthorizationControllerPresentationContextProviding {
    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        UIApplication.currentKeyWindow ?? ASPresentationAnchor()
    }
}
