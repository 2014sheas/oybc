import Foundation
import FirebaseAuth
import GoogleSignIn
import AuthenticationServices
import UIKit

/// AuthService - Firebase authentication and local user record management
///
/// Listens to Firebase auth state changes and keeps the local GRDB `User`
/// record in sync. All sign-in methods return the local `User` model so
/// callers never interact with Firebase types directly.
///
/// Published properties:
/// - `currentUser`: The local OYBC `User` model, or nil when signed out.
/// - `isLoading`: True until the first Firebase auth state callback fires.
@MainActor
final class AuthService: ObservableObject {
    // MARK: - Published State

    /// The current signed-in OYBC user, or nil when signed out.
    @Published var currentUser: User?

    /// True while waiting for the initial Firebase auth state to resolve.
    @Published var isLoading: Bool = true

    // MARK: - Private

    private var authStateHandle: AuthStateDidChangeListenerHandle?

    // MARK: - Initialization

    init() {
        // Firebase delivers the initial auth state asynchronously on a
        // background thread. We bridge it to the main actor here.
        authStateHandle = Auth.auth().addStateDidChangeListener { [weak self] _, firebaseUser in
            guard let self else { return }
            _Concurrency.Task {
                if let firebaseUser {
                    await MainActor.run { self.currentUser = nil } // clear stale state
                    let user = await self.upsertLocalUser(firebaseUser)
                    await MainActor.run { self.currentUser = user }
                } else {
                    await MainActor.run { self.currentUser = nil }
                }
                await MainActor.run { self.isLoading = false }
            }
        }
    }

    deinit {
        if let handle = authStateHandle {
            Auth.auth().removeStateDidChangeListener(handle)
        }
    }

    // MARK: - Email / Password

    /// Creates a new Firebase account and upserts a local GRDB `User` record.
    ///
    /// - Parameters:
    ///   - email: The user's email address.
    ///   - password: The desired password (min 6 characters, enforced by Firebase).
    /// - Returns: The newly created local `User`.
    /// - Throws: A Firebase `AuthError` on failure.
    @discardableResult
    func signUp(email: String, password: String) async throws -> User {
        let result = try await Auth.auth().createUser(withEmail: email, password: password)
        let user = await upsertLocalUser(result.user)
        currentUser = user
        return user
    }

    /// Signs in with email and password and upserts a local GRDB `User` record.
    ///
    /// - Parameters:
    ///   - email: The user's email address.
    ///   - password: The account password.
    /// - Returns: The signed-in local `User`.
    /// - Throws: A Firebase `AuthError` on failure.
    @discardableResult
    func signIn(email: String, password: String) async throws -> User {
        let result = try await Auth.auth().signIn(withEmail: email, password: password)
        let user = await upsertLocalUser(result.user)
        currentUser = user
        return user
    }

    // MARK: - Google Sign-In

    /// Signs in with Google and upserts a local GRDB `User` record.
    ///
    /// - Parameter presenting: The `UIViewController` used to present the Google sign-in flow.
    /// - Returns: The signed-in local `User`.
    /// - Throws: A `GoogleSignInError` or Firebase `AuthError` on failure.
    @discardableResult
    func signInWithGoogle(presenting: UIViewController) async throws -> User {
        let signInResult = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenting)
        let googleUser = signInResult.user

        guard let idToken = googleUser.idToken?.tokenString else {
            throw AuthServiceError.missingGoogleIdToken
        }

        let credential = GoogleAuthProvider.credential(
            withIDToken: idToken,
            accessToken: googleUser.accessToken.tokenString
        )

        let result = try await Auth.auth().signIn(with: credential)
        let user = await upsertLocalUser(result.user)
        currentUser = user
        return user
    }

    // MARK: - Apple Sign-In

    /// Signs in with Apple using the given `ASAuthorization` and upserts a
    /// local GRDB `User` record.
    ///
    /// The caller is responsible for supplying the nonce that was used during
    /// the `ASAuthorizationAppleIDRequest` — pass it as `rawNonce`.
    ///
    /// - Parameters:
    ///   - authorization: The `ASAuthorization` from the Apple sign-in delegate.
    ///   - rawNonce: The raw (unhashed) nonce used when building the request.
    /// - Returns: The signed-in local `User`.
    /// - Throws: `AuthServiceError.invalidAppleCredential` or a Firebase `AuthError`.
    @discardableResult
    func signInWithApple(authorization: ASAuthorization, rawNonce: String) async throws -> User {
        guard
            let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
            let appleIDTokenData = appleIDCredential.identityToken,
            let idTokenString = String(data: appleIDTokenData, encoding: .utf8)
        else {
            throw AuthServiceError.invalidAppleCredential
        }

        let credential = OAuthProvider.appleCredential(
            withIDToken: idTokenString,
            rawNonce: rawNonce,
            fullName: appleIDCredential.fullName
        )

        let result = try await Auth.auth().signIn(with: credential)
        let user = await upsertLocalUser(result.user)
        currentUser = user
        return user
    }

    // MARK: - Sign Out

    /// Signs out of Firebase and clears the local current user.
    ///
    /// - Throws: A Firebase `AuthError` if sign-out fails.
    func signOut() throws {
        // Clear sync queue to prevent cross-user data leakage
        try? AppDatabase.shared.write { db in
            try db.execute(sql: "DELETE FROM sync_queue")
        }
        try Auth.auth().signOut()
        currentUser = nil
    }

    // MARK: - Local User Upsert

    /// Creates or updates the GRDB `User` record for the given Firebase user.
    ///
    /// On first sign-in a new record is inserted. On subsequent sign-ins the
    /// `displayName`, `photoURL`, `updatedAt`, and `version` fields are refreshed.
    ///
    /// - Parameter firebaseUser: The authenticated Firebase user.
    /// - Returns: The up-to-date local `User`.
    private func upsertLocalUser(_ firebaseUser: FirebaseAuth.User) async -> User {
        let now = AppDatabase.currentTimestamp()

        do {
            if var existing = try AppDatabase.shared.fetchUser(id: firebaseUser.uid) {
                // Update mutable fields that may have changed.
                existing.displayName = firebaseUser.displayName
                existing.photoURL = firebaseUser.photoURL?.absoluteString
                existing.updatedAt = now
                existing.version += 1
                try AppDatabase.shared.saveUser(existing)
                return existing
            } else {
                // First sign-in: create the local user record.
                let newUser = User(
                    id: firebaseUser.uid,
                    email: firebaseUser.email ?? "",
                    displayName: firebaseUser.displayName,
                    photoURL: firebaseUser.photoURL?.absoluteString,
                    createdAt: now,
                    updatedAt: now,
                    lastSyncedAt: nil,
                    version: 1
                )
                try AppDatabase.shared.saveUser(newUser)
                return newUser
            }
        } catch {
            // Database errors are non-fatal for the auth flow; log and return
            // a transient User from Firebase data so the session still starts.
            print("⚠️ AuthService: failed to upsert local user: \(error)")
            return User(
                id: firebaseUser.uid,
                email: firebaseUser.email ?? "",
                displayName: firebaseUser.displayName,
                photoURL: firebaseUser.photoURL?.absoluteString,
                createdAt: now,
                updatedAt: now,
                lastSyncedAt: nil,
                version: 1
            )
        }
    }
}

// MARK: - Errors

/// Errors specific to `AuthService` that are not covered by Firebase's own error types.
enum AuthServiceError: LocalizedError {
    case missingGoogleIdToken
    case invalidAppleCredential

    var errorDescription: String? {
        switch self {
        case .missingGoogleIdToken:
            return "Google sign-in did not return an ID token."
        case .invalidAppleCredential:
            return "Apple sign-in returned an invalid credential."
        }
    }
}
