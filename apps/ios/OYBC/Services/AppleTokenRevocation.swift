import Foundation

/// Pure helpers for revoking a Sign in with Apple token when an account is
/// deleted (App Store Review Guideline 5.1.1(v)).
///
/// Apple requires that deleting an account that uses Sign in with Apple also
/// revokes the app's Apple token. Firebase does this with
/// `Auth.revokeToken(withAuthorizationCode:)`, which needs a FRESH Apple
/// `authorizationCode` (single use, short-lived) and a signed-in user — so the
/// delete flow runs an Apple authorization first, revokes with its code, and
/// only then deletes the Firebase user (`AuthService.deleteAccountRevokingApple`).
/// Web twin: `requiresAppleRevocation` in `apps/web/src/firebase/accountSecurity.ts`.
enum AppleTokenRevocation {

    /// True when deleting an account with these linked providers must revoke a
    /// Sign in with Apple token first — any account with `apple.com` linked,
    /// however the user signed in this session. A guest (anonymous) account
    /// has no providers and never qualifies.
    ///
    /// - Parameter providerIDs: The account's `providerData[].providerID`s.
    /// - Returns: True when the Apple revoke path is required.
    static func isRequired(providerIDs: [String]) -> Bool {
        providerIDs.contains(ProviderState.appleProviderID)
    }

    /// Decodes `ASAuthorizationAppleIDCredential.authorizationCode` (UTF-8
    /// bytes) into the string `revokeToken(withAuthorizationCode:)` expects.
    ///
    /// - Parameter data: The credential's `authorizationCode`, if any.
    /// - Returns: The code, or nil when it is absent, not UTF-8, or blank.
    static func authorizationCodeString(from data: Data?) -> String? {
        guard let data, let code = String(data: data, encoding: .utf8) else { return nil }
        let trimmed = code.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
