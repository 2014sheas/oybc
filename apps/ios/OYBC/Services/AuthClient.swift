import Foundation
import FirebaseAuth

/// Value snapshot of the Firebase user fields `AuthService` reads during the
/// post-link reconcile (docs/GUEST_MODE.md §Upgrade). A plain struct so tests
/// can describe "what `currentUser` looks like after a link" without a real
/// `FirebaseAuth.User` (which can't be constructed outside the SDK).
struct AuthUserSnapshot: Equatable {
    let uid: String
    let email: String?
    let displayName: String?
    let photoURL: URL?
    let isAnonymous: Bool
    /// `providerData[].providerID` — feeds `AuthService.computeProviderState`.
    let providerIDs: [String]
}

extension AuthUserSnapshot {
    /// Snapshots the fields `AuthService` reads off a live Firebase user.
    init(firebaseUser: FirebaseAuth.User) {
        self.init(
            uid: firebaseUser.uid,
            email: firebaseUser.email,
            displayName: firebaseUser.displayName,
            photoURL: firebaseUser.photoURL,
            isAnonymous: firebaseUser.isAnonymous,
            providerIDs: firebaseUser.providerData.map { $0.providerID }
        )
    }
}

/// The slice of Firebase Auth that `AuthService.linkCredential`,
/// `refreshProviderState`, the signed-out password reset and account deletion
/// touch — a seam so the guest-upgrade reconcile, the enumeration-safe reset
/// and the Apple-revoke-before-delete ordering can be unit-tested against a
/// fake (`GuestUpgradeStateTests`, `AuthRecoveryAndRevocationTests`).
/// Production always uses `FirebaseAuthClient`, the default in `AuthService.init`.
///
/// The listener hook exists only so `AuthService.init` can be constructed
/// under XCTest, where `FirebaseApp.configure()` is skipped and any
/// `Auth.auth()` call would crash; a fake returns nil and never fires.
@MainActor
protocol AuthClient {
    /// Installs the auth-state listener `AuthService.init` relies on.
    ///
    /// - Parameter listener: Called with the Firebase user (nil when signed out).
    /// - Returns: The handle to remove on deinit, or nil if nothing was installed.
    func addStateDidChangeListener(
        _ listener: @escaping (FirebaseAuth.User?) -> Void
    ) -> AuthStateDidChangeListenerHandle?

    /// The signed-in Firebase user, snapshotted; nil when signed out.
    var currentUserSnapshot: AuthUserSnapshot? { get }

    /// Links `credential` onto the current user (mutating it in place).
    ///
    /// - Throws: `AuthServiceError.noCurrentUser` when signed out, or the
    ///   Firebase link error (e.g. `providerAlreadyLinked`, a collision).
    func linkCurrentUser(with credential: AuthCredential) async throws

    /// Reloads the current user's profile from the server (no-op when signed out).
    ///
    /// - Throws: The Firebase reload error.
    func reloadCurrentUser() async throws

    /// Sends a password-reset email to `email`. Works signed out.
    ///
    /// - Parameter email: The (already normalized) address to send to.
    /// - Throws: The Firebase error (e.g. `invalidEmail`, `userNotFound`,
    ///   `networkError`) — `AuthService` decides which ones still read as sent.
    func sendPasswordReset(email: String) async throws

    /// Reauthenticates the current user with `credential` (refreshes login
    /// recency so a security-sensitive op such as delete can proceed).
    ///
    /// - Parameter credential: A fresh provider credential.
    /// - Throws: `AuthServiceError.noCurrentUser` when signed out, or the
    ///   Firebase reauth error (e.g. `userMismatch`).
    func reauthenticateCurrentUser(with credential: AuthCredential) async throws

    /// Revokes the current user's Sign in with Apple token with a fresh
    /// authorization code (App Store 5.1.1(v)). Needs a signed-in user, so it
    /// must run BEFORE the account is deleted.
    ///
    /// - Parameter authorizationCode: The UTF-8 decoded Apple authorization code.
    /// - Throws: `AuthServiceError.noCurrentUser` when signed out, or the
    ///   Firebase revoke error.
    func revokeAppleToken(authorizationCode: String) async throws

    /// Deletes the current Firebase Auth user (fires the server-side
    /// `onUserDeleted` purge).
    ///
    /// - Throws: `AuthServiceError.noCurrentUser` when signed out, or the
    ///   Firebase delete error (e.g. `requiresRecentLogin`).
    func deleteCurrentUser() async throws
}

/// The real `AuthClient`: forwards to `Auth.auth()`.
struct FirebaseAuthClient: AuthClient {
    /// Stateless; `nonisolated` so it can be `AuthService.init`'s default argument.
    nonisolated init() {}

    func addStateDidChangeListener(
        _ listener: @escaping (FirebaseAuth.User?) -> Void
    ) -> AuthStateDidChangeListenerHandle? {
        Auth.auth().addStateDidChangeListener { _, firebaseUser in listener(firebaseUser) }
    }

    var currentUserSnapshot: AuthUserSnapshot? {
        Auth.auth().currentUser.map(AuthUserSnapshot.init(firebaseUser:))
    }

    func linkCurrentUser(with credential: AuthCredential) async throws {
        guard let user = Auth.auth().currentUser else { throw AuthServiceError.noCurrentUser }
        _ = try await user.link(with: credential)
    }

    func reloadCurrentUser() async throws {
        try await Auth.auth().currentUser?.reload()
    }

    func sendPasswordReset(email: String) async throws {
        try await Auth.auth().sendPasswordReset(withEmail: email)
    }

    func reauthenticateCurrentUser(with credential: AuthCredential) async throws {
        guard let user = Auth.auth().currentUser else { throw AuthServiceError.noCurrentUser }
        _ = try await user.reauthenticate(with: credential)
    }

    func revokeAppleToken(authorizationCode: String) async throws {
        // The SDK's revoke never calls back when there is no current user (its
        // async wrapper would hang), so refuse up front instead.
        guard Auth.auth().currentUser != nil else { throw AuthServiceError.noCurrentUser }
        try await Auth.auth().revokeToken(withAuthorizationCode: authorizationCode)
    }

    func deleteCurrentUser() async throws {
        guard let user = Auth.auth().currentUser else { throw AuthServiceError.noCurrentUser }
        try await user.delete()
    }
}
