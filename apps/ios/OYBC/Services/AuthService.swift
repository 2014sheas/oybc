import Foundation
import FirebaseAuth
import GoogleSignIn
import AuthenticationServices
import UIKit
@preconcurrency import GRDB

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

    /// GRDB observation of the signed-in user's row. Keeps `currentUser`
    /// in sync with local writes (preference changes) and sync-pulled
    /// remote changes without requiring callers to manually refresh.
    private var userRowObservation: DatabaseCancellable?

    /// Real-time sync orchestrator. Started when the user signs in,
    /// stopped on sign-out. Drives push-on-enqueue + Firestore snapshot
    /// listeners so local writes and cross-device updates replicate
    /// in roughly a second instead of waiting up to 30s for a tick.
    let syncService = SyncService()

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
                    await MainActor.run {
                        self.currentUser = user
                        self.startUserRowObservation(userId: user.id)
                        self.syncService.start(userId: user.id)
                    }
                } else {
                    await MainActor.run {
                        self.currentUser = nil
                        self.stopUserRowObservation()
                        self.syncService.stop()
                    }
                }
                await MainActor.run { self.isLoading = false }
            }
        }
    }

    deinit {
        if let handle = authStateHandle {
            Auth.auth().removeStateDidChangeListener(handle)
        }
        userRowObservation?.cancel()
    }

    // MARK: - User row observation

    /// Starts a `ValueObservation` on the signed-in user's row so that any
    /// mutation (local preference write, sync-pulled remote update) flows
    /// into the published `currentUser` automatically.
    private func startUserRowObservation(userId: String) {
        userRowObservation?.cancel()
        let observation = ValueObservation.tracking { db in
            try User.fetchOne(db, key: userId)
        }
        userRowObservation = observation.start(
            in: AppDatabase.shared.dbQueue,
            onError: { error in
                print("⚠️ user row observation failed: \(error)")
            },
            onChange: { [weak self] refreshed in
                guard let refreshed, let self else { return }
                _Concurrency.Task { @MainActor in
                    self.currentUser = refreshed
                }
            }
        )
    }

    private func stopUserRowObservation() {
        userRowObservation?.cancel()
        userRowObservation = nil
    }

    // MARK: - Preferences

    /// Current synced user preferences, or `.defaults` when signed out.
    ///
    /// Backed by `currentUser`, which is itself kept in sync via the GRDB
    /// `ValueObservation` started in the auth state handler — so local
    /// preference writes and sync-pulled remote updates both flow through
    /// without any manual refresh step.
    var userPreferences: UserPreferences {
        currentUser?.decodedPreferences ?? .defaults
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

    // MARK: - Display Name

    /// Update the user's display name in Firebase Auth and the local DB.
    ///
    /// 1. Updates the Firebase Auth profile so the name persists on re-auth.
    /// 2. Updates the GRDB User row (version bump + updatedAt) and enqueues
    ///    a sync-queue item — all in a single transaction.
    ///
    /// - Parameter newName: The new display name; empty/whitespace clears it.
    func updateDisplayName(_ newName: String) async throws {
        let trimmed = newName.trimmingCharacters(in: .whitespacesAndNewlines)
        let displayName: String? = trimmed.isEmpty ? nil : trimmed

        // 1. Firebase Auth profile
        let changeRequest = Auth.auth().currentUser?.createProfileChangeRequest()
        changeRequest?.displayName = displayName
        try await changeRequest?.commitChanges()

        // 2. Local GRDB row + sync queue
        guard let userId = Auth.auth().currentUser?.uid else { return }
        try AppDatabase.shared.write { db in
            guard var user = try User.fetchOne(db, key: userId) else { return }
            user.displayName = displayName
            user.updatedAt = AppDatabase.currentTimestamp()
            user.version += 1
            try user.save(db)

            let payload: String
            do {
                let data = try JSONEncoder().encode(user)
                payload = String(data: data, encoding: .utf8) ?? "{}"
            } catch {
                payload = "{}"
            }

            let syncItem = SyncQueueItem(
                id: AppDatabase.generateUUID(),
                entityType: "users",
                entityId: userId,
                operationType: .update,
                payload: payload,
                status: .pending,
                retryCount: 0,
                lastError: nil,
                createdAt: user.updatedAt,
                lastAttemptAt: nil,
                completedAt: nil,
                priority: 1
            )
            try syncItem.save(db)
        }
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

    // MARK: - Legacy @AppStorage migration

    /// Key used by pre-Phase-0 `@AppStorage("oybc-weekStartDay")` bindings.
    private static let legacyWeekStartDayKey = "oybc-weekStartDay"

    /// If the legacy UserDefaults `oybc-weekStartDay` key is present and
    /// holds a recognised value, returns an updated `UserPreferences` with
    /// `weekStartDay` migrated and removes the key. Returns `nil` if the
    /// key is absent or already migrated, so the caller can skip a write.
    private static func migrateLegacyWeekStartDay(
        from current: UserPreferences
    ) -> UserPreferences? {
        let defaults = UserDefaults.standard
        guard let raw = defaults.string(forKey: legacyWeekStartDayKey) else {
            return nil
        }
        defaults.removeObject(forKey: legacyWeekStartDayKey)

        guard let value = WeekStartDay(rawValue: raw),
              value != current.weekStartDay else {
            return nil
        }
        var next = current
        next.weekStartDay = value
        return next
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

                // Backfill missing preference fields and apply the one-shot
                // legacy @AppStorage migration. `decodedPreferences` fills
                // any keys absent in the stored JSON (pre-Phase-0 rows or
                // rows written by an older client) with defaults via the
                // custom init(from:); we then give the legacy migration a
                // chance to override `weekStartDay` before re-encoding.
                // Mirrors web's `mergeUserPreferences(existing.preferences)`
                // + `migrateLegacyLocalStoragePreferences` on every upsert.
                var mergedPrefs = existing.decodedPreferences
                if let migrated = Self.migrateLegacyWeekStartDay(from: mergedPrefs) {
                    mergedPrefs = migrated
                }
                existing.preferences = User.encodePreferences(mergedPrefs)

                try AppDatabase.shared.saveUser(existing)
                return existing
            } else {
                // First sign-in: create the local user record seeded with
                // default synced preferences.
                let newUser = User(
                    id: firebaseUser.uid,
                    email: firebaseUser.email ?? "",
                    displayName: firebaseUser.displayName,
                    photoURL: firebaseUser.photoURL?.absoluteString,
                    preferences: User.encodePreferences(.defaults),
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
                preferences: User.encodePreferences(.defaults),
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
