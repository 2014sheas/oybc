import Foundation
import FirebaseAuth

/// User-facing copy for errors on the sign-in surfaces (`LoginView` in
/// `AuthGateView.swift`, the onboarding sign-in panel in `OnboardingView.swift`,
/// the guest `UpgradeAccountSheet`) — never Firebase's raw
/// `localizedDescription`. `AuthServiceError`s keep their own curated copy.
///
/// Web twin: `signInErrorMessage` in `apps/web/src/firebase/authService.ts`
/// (same codes, same wording; the shared lines mirror `friendlyError` in
/// `accountSecurity.ts`). A wrong password and an unknown address read the
/// same, so the form never reveals whether an account exists.
@MainActor
enum SignInErrorMessage {

    /// Wrong password / unknown address / Firebase's merged
    /// `INVALID_LOGIN_CREDENTIALS` (`invalidCredential` under email-enumeration
    /// protection) — one message for all three.
    static let incorrectCredentials = "Incorrect email or password."
    static let invalidEmail = "That email address looks invalid."
    static let emailInUse = "That email is already in use by another account."
    static let weakPassword = "Pick a stronger password (at least 6 characters)."
    static let tooManyRequests = "Too many attempts. Try again later."
    static let userDisabled = "This account has been disabled."
    static let differentSignInMethod = "This email uses a different sign-in method."
    static let offline = "You're offline. Connect and try again."
    static let fallback = "Something went wrong. Please try again."

    /// The banner text for a failed sign-in / sign-up / reset / provider flow.
    ///
    /// - Parameter error: The error the auth call threw.
    /// - Returns: The message to show, or nil when the user cancelled an
    ///   Apple or Google sheet (`AuthService.isAuthCancellation`) — a
    ///   cancellation shows nothing. Callers that branch on the error (e.g. a
    ///   link collision) do so on the raw error first and map only for display.
    static func message(for error: Error) -> String? {
        if AuthService.isAuthCancellation(error) { return nil }
        // Our own errors already carry curated one-line copy.
        if let serviceError = error as? AuthServiceError { return serviceError.errorDescription ?? fallback }
        if isOffline(error) { return offline }
        let nsError = error as NSError
        guard nsError.domain == AuthErrorDomain, let code = AuthErrorCode(rawValue: nsError.code) else {
            return fallback
        }
        switch code {
        case .invalidCredential, .wrongPassword, .userNotFound:
            return incorrectCredentials
        case .invalidEmail:
            return invalidEmail
        case .emailAlreadyInUse:
            return emailInUse
        case .weakPassword:
            return weakPassword
        case .tooManyRequests:
            return tooManyRequests
        case .userDisabled:
            return userDisabled
        case .accountExistsWithDifferentCredential:
            return differentSignInMethod
        default:
            return fallback
        }
    }

    /// True for a "no network" failure: Firebase's `networkError`, or the
    /// URL-loading codes for no connection / lost connection / timeout.
    /// Shared with the guest paths, which show their own offline line.
    ///
    /// - Parameter error: The error the auth call threw.
    /// - Returns: True when the failure is a connectivity problem.
    static func isOffline(_ error: Error) -> Bool {
        let nsError = error as NSError
        if nsError.domain == AuthErrorDomain && nsError.code == AuthErrorCode.networkError.rawValue {
            return true
        }
        return nsError.domain == NSURLErrorDomain && [
            NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut
        ].contains(nsError.code)
    }
}
