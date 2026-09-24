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

/// The slice of Firebase Auth that `AuthService.linkCredential` and
/// `refreshProviderState` touch — a seam so the guest-upgrade reconcile can be
/// unit-tested against a fake (`GuestUpgradeStateTests`). Production always
/// uses `FirebaseAuthClient`, the default in `AuthService.init`.
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
}
