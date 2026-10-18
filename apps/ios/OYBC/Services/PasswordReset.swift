import Foundation
import FirebaseAuth

/// Pure helpers behind the signed-out "Forgot password?" action on the login
/// form (`LoginView` in `AuthGateView.swift`; web twin `sendPasswordReset` in
/// `apps/web/src/firebase/authService.ts`).
///
/// The one rule that matters: the confirmation must read the SAME whether or
/// not an account exists for the typed address, so the form can't be used to
/// probe which emails have accounts. Firebase's `userNotFound` is therefore
/// treated as a successful send; every other error (malformed address,
/// network, rate limit) surfaces through the form's normal error banner.
enum PasswordReset {

    /// The address the reset is sent to: the typed email with surrounding
    /// whitespace removed (an autofilled address can carry a trailing space).
    ///
    /// - Parameter raw: The email field's current text.
    /// - Returns: The trimmed address (may be empty — callers gate on that).
    static func normalizedEmail(_ raw: String) -> String {
        raw.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// True when a `sendPasswordReset` failure must still read as "sent" —
    /// Firebase's `userNotFound`, which would otherwise reveal that no account
    /// uses the address. (With Firebase email-enumeration protection on, the
    /// server never returns it; this keeps the form safe when it is off.)
    ///
    /// - Parameter error: The error `sendPasswordReset(withEmail:)` threw.
    /// - Returns: True when the caller should report success.
    static func countsAsSent(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == AuthErrorDomain
            && nsError.code == AuthErrorCode.userNotFound.rawValue
    }

    /// The status line the form shows after a send, e.g.
    /// "Reset link sent to alex@example.com".
    ///
    /// - Parameter email: The normalized address the reset went to.
    /// - Returns: The one-line confirmation.
    static func sentStatus(for email: String) -> String {
        "Reset link sent to \(email)"
    }
}
