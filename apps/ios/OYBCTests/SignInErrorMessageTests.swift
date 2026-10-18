import XCTest
import AuthenticationServices
import FirebaseAuth
import GoogleSignIn
@testable import OYBC

/// Sign-in error copy (release audit, ROADMAP Track L → L1): the login form and
/// the onboarding sign-in panel never show Firebase's raw text, a cancelled
/// Apple / Google sheet shows nothing, and a wrong password reads the same as
/// an unknown address. Web twin: `signInErrorMessage.test.ts`.
@MainActor
final class SignInErrorMessageTests: XCTestCase {

    private func authError(_ code: AuthErrorCode) -> NSError {
        NSError(domain: AuthErrorDomain, code: code.rawValue)
    }

    func testCredentialFailuresShareOneMessage() {
        for code in [AuthErrorCode.invalidCredential, .wrongPassword, .userNotFound] {
            XCTAssertEqual(SignInErrorMessage.message(for: authError(code)),
                           "Incorrect email or password.", "\(code)")
        }
    }

    func testCommonCodesMapToShortCopy() {
        XCTAssertEqual(SignInErrorMessage.message(for: authError(.invalidEmail)),
                       "That email address looks invalid.")
        XCTAssertEqual(SignInErrorMessage.message(for: authError(.emailAlreadyInUse)),
                       "That email is already in use by another account.")
        XCTAssertEqual(SignInErrorMessage.message(for: authError(.weakPassword)),
                       "Pick a stronger password (at least 6 characters).")
        XCTAssertEqual(SignInErrorMessage.message(for: authError(.tooManyRequests)),
                       "Too many attempts. Try again later.")
        XCTAssertEqual(SignInErrorMessage.message(for: authError(.userDisabled)),
                       "This account has been disabled.")
        // Signed up with Google, then tried Apple with the same email.
        XCTAssertEqual(SignInErrorMessage.message(for: authError(.accountExistsWithDifferentCredential)),
                       "This email uses a different sign-in method.")
    }

    func testServiceErrorsKeepTheirOwnCopy() {
        XCTAssertEqual(SignInErrorMessage.message(for: AuthServiceError.noCurrentUser), "You're not signed in.")
        XCTAssertEqual(SignInErrorMessage.message(for: AuthServiceError.appleRevocationFailed),
                       "Couldn't disconnect Apple. Your account wasn't deleted.")
    }

    func testConnectivityFailuresReadAsOffline() {
        let offline = "You're offline. Connect and try again."
        XCTAssertEqual(SignInErrorMessage.message(for: authError(.networkError)), offline)
        for code in [NSURLErrorNotConnectedToInternet, NSURLErrorNetworkConnectionLost, NSURLErrorTimedOut] {
            let error = NSError(domain: NSURLErrorDomain, code: code)
            XCTAssertTrue(SignInErrorMessage.isOffline(error))
            XCTAssertEqual(SignInErrorMessage.message(for: error), offline)
        }
        XCTAssertFalse(SignInErrorMessage.isOffline(authError(.invalidEmail)))
        XCTAssertFalse(SignInErrorMessage.isOffline(
            NSError(domain: NSCocoaErrorDomain, code: AuthErrorCode.networkError.rawValue)),
            "the network code only counts in the Firebase Auth domain")
    }

    func testCancelledProviderSheetsShowNothing() {
        XCTAssertNil(SignInErrorMessage.message(for: ASAuthorizationError(.canceled)))
        XCTAssertNil(SignInErrorMessage.message(for: GIDSignInError(.canceled)))
    }

    func testEverythingElseFallsBackToPlainCopy() {
        let fallback = "Something went wrong. Please try again."
        XCTAssertEqual(SignInErrorMessage.message(for: authError(.internalError)), fallback)
        XCTAssertEqual(SignInErrorMessage.message(for: ASAuthorizationError(.failed)), fallback)
        XCTAssertEqual(SignInErrorMessage.message(
            for: NSError(domain: NSCocoaErrorDomain, code: AuthErrorCode.wrongPassword.rawValue)), fallback,
            "a Firebase code number outside the Firebase domain is not a match")
    }
}
