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

    /// Which sign-in providers are linked to the current account. Recomputed on
    /// sign-in and after every link/unlink; drives the Account & security UI
    /// (change email/password gated on `hasPassword`, unlink gated on count).
    @Published var providerState: ProviderState = .none

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

    /// Local-notification scheduler (Phase 7). Auth-owned like `syncService`;
    /// injected into the view tree by `AuthGateView`. Cleared on sign-out so
    /// one account's reminders never linger into another's session.
    let notificationService = NotificationService()

    // MARK: - Initialization

    init() {
        #if DEBUG
        // Debug-only local bypass: when the process is launched with
        // `-bypassAuth YES`, skip Firebase entirely and drop straight
        // into the signed-in UI with a synthetic playground user. Used
        // to screenshot / interact with auth-gated views on the
        // simulator without real credentials. SyncService is NOT
        // started — bypass runs fully offline and never pushes to
        // Firestore.
        //
        // Launch from CLI:
        //   xcrun simctl launch <device> com.oybc.OYBC -bypassAuth YES
        // Or add `-bypassAuth YES` under Run → Arguments in Xcode.
        if ProcessInfo.processInfo.arguments.contains("-bypassAuth") {
            setupDebugBypass()
            return
        }
        #endif

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
                    await self.refreshProviderState()
                } else {
                    await MainActor.run {
                        self.currentUser = nil
                        self.stopUserRowObservation()
                        self.syncService.stop()
                        self.notificationService.clearAll()
                        self.providerState = .none
                    }
                }
                await MainActor.run { self.isLoading = false }
            }
        }
    }

    #if DEBUG
    /// Ensures a local playground `User` row exists and surfaces it as
    /// the signed-in user. Observed by GRDB so preference edits work
    /// the same way they would under a real sign-in. No Firestore
    /// push side — `syncService.start` is intentionally skipped.
    private func setupDebugBypass() {
        _Concurrency.Task { @MainActor in
            let userId = "playground-user-1"
            do {
                let now = AppDatabase.currentTimestamp()
                try await _Concurrency.Task.detached(priority: .userInitiated) {
                    try AppDatabase.shared.write { db in
                        if try User.fetchOne(db, key: userId) == nil {
                            let user = User(
                                id: userId,
                                email: "debug-bypass@oybc.local",
                                displayName: "Debug Bypass",
                                photoURL: nil,
                                preferences: User.encodePreferences(.defaults),
                                createdAt: now,
                                updatedAt: now,
                                lastSyncedAt: nil,
                                version: 1
                            )
                            try user.save(db)
                        }
                    }
                }.value

                let user = try AppDatabase.shared.read { db in
                    try User.fetchOne(db, key: userId)
                }
                if let user {
                    self.currentUser = user
                    self.startUserRowObservation(userId: user.id)
                }
            } catch {
                print("⚠️ Debug auth bypass failed: \(error)")
            }
            self.isLoading = false
        }
    }
    #endif

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
        let credential = try await googleCredential(presenting: presenting)
        let result = try await Auth.auth().signIn(with: credential)
        let user = await upsertLocalUser(result.user)
        currentUser = user
        return user
    }

    /// Runs the Google sign-in handshake and returns a Firebase credential.
    /// Shared by sign-in, reauthentication, and account linking.
    private func googleCredential(presenting: UIViewController) async throws -> AuthCredential {
        let signInResult = try await GIDSignIn.sharedInstance.signIn(withPresenting: presenting)
        guard let idToken = signInResult.user.idToken?.tokenString else {
            throw AuthServiceError.missingGoogleIdToken
        }
        return GoogleAuthProvider.credential(
            withIDToken: idToken,
            accessToken: signInResult.user.accessToken.tokenString
        )
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
        let credential = try appleCredential(from: authorization, rawNonce: rawNonce)
        let result = try await Auth.auth().signIn(with: credential)
        let user = await upsertLocalUser(result.user)
        currentUser = user
        return user
    }

    /// Builds a Firebase credential from an Apple `ASAuthorization` + raw nonce.
    /// Shared by sign-in, reauthentication, and account linking.
    private func appleCredential(from authorization: ASAuthorization, rawNonce: String) throws -> AuthCredential {
        guard
            let appleIDCredential = authorization.credential as? ASAuthorizationAppleIDCredential,
            let tokenData = appleIDCredential.identityToken,
            let idTokenString = String(data: tokenData, encoding: .utf8)
        else {
            throw AuthServiceError.invalidAppleCredential
        }
        return OAuthProvider.appleCredential(
            withIDToken: idTokenString,
            rawNonce: rawNonce,
            fullName: appleIDCredential.fullName
        )
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
        try persistUserMutation { $0.displayName = displayName }
    }

    /// Applies a mutation to the local user row (bumping `version` + `updatedAt`)
    /// and enqueues a `users` sync-queue update — all in one transaction — so the
    /// change replicates to Firestore. Shared by display-name + email edits.
    private func persistUserMutation(_ apply: (inout User) -> Void) throws {
        guard let userId = Auth.auth().currentUser?.uid else { return }
        try AppDatabase.shared.write { db in
            guard var user = try User.fetchOne(db, key: userId) else { return }
            apply(&user)
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
            try syncItem.enqueue(db)
        }
    }

    // MARK: - Account & Security: provider state

    /// Reloads the Firebase user and recomputes `providerState` from its
    /// `providerData`. Call after sign-in and after any link/unlink.
    func refreshProviderState() async {
        try? await Auth.auth().currentUser?.reload()
        providerState = Self.computeProviderState(Auth.auth().currentUser)
    }

    /// Derives a `ProviderState` from a Firebase user's linked providers.
    static func computeProviderState(_ user: FirebaseAuth.User?) -> ProviderState {
        let ids = Set((user?.providerData ?? []).map { $0.providerID })
        return ProviderState(
            hasPassword: ids.contains(ProviderState.passwordProviderID),
            hasGoogle: ids.contains(ProviderState.googleProviderID),
            hasApple: ids.contains(ProviderState.appleProviderID),
            providerCount: ids.count
        )
    }

    /// True when an error is Firebase's `requiresRecentLogin` — the cue to run a
    /// reauth flow and retry the security-sensitive operation.
    static func isRecentLoginRequired(_ error: Error) -> Bool {
        let nsError = error as NSError
        return nsError.domain == AuthErrorDomain
            && nsError.code == AuthErrorCode.requiresRecentLogin.rawValue
    }

    // MARK: - Account & Security: reauthentication

    /// Reauthenticates a password-provider user (refreshes login recency so a
    /// security-sensitive op can proceed).
    func reauthenticateWithPassword(_ password: String) async throws {
        guard let user = Auth.auth().currentUser, let email = user.email else {
            throw AuthServiceError.noCurrentUser
        }
        let credential = EmailAuthProvider.credential(withEmail: email, password: password)
        try await user.reauthenticate(with: credential)
    }

    /// Reauthenticates via the Google handshake.
    func reauthenticateWithGoogle(presenting: UIViewController) async throws {
        guard let user = Auth.auth().currentUser else { throw AuthServiceError.noCurrentUser }
        let credential = try await googleCredential(presenting: presenting)
        try await user.reauthenticate(with: credential)
    }

    /// Reauthenticates via the Apple handshake.
    func reauthenticateWithApple(authorization: ASAuthorization, rawNonce: String) async throws {
        guard let user = Auth.auth().currentUser else { throw AuthServiceError.noCurrentUser }
        let credential = try appleCredential(from: authorization, rawNonce: rawNonce)
        try await user.reauthenticate(with: credential)
    }

    // MARK: - Account & Security: change email / password

    /// Updates the account password. Password-provider only; requires recent
    /// login (throws `requiresRecentLogin` otherwise — reauth then retry).
    func updatePassword(to newPassword: String) async throws {
        guard let user = Auth.auth().currentUser else { throw AuthServiceError.noCurrentUser }
        try await user.updatePassword(to: newPassword)
    }

    /// Begins an email change. Uses `verifyBeforeUpdateEmail` (the supported,
    /// non-deprecated path; direct `updateEmail` is rejected under email-
    /// enumeration protection): Firebase emails a verification link to the NEW
    /// address and only swaps `currentUser.email` once the user clicks it. The
    /// local mirror is healed later by `reconcileEmailIfChanged()`.
    /// Requires recent login.
    func updateEmail(to newEmail: String) async throws {
        guard let user = Auth.auth().currentUser else { throw AuthServiceError.noCurrentUser }
        let trimmed = newEmail.trimmingCharacters(in: .whitespacesAndNewlines)
        try await user.sendEmailVerification(beforeUpdatingEmail: trimmed)
    }

    /// If the verified Firebase email now differs from the locally-stored one
    /// (the user completed a `verifyBeforeUpdateEmail` flow out-of-band), update
    /// the local row + enqueue a sync so the new address reaches Firestore.
    /// Safe to call on foreground / launch; a no-op when nothing changed.
    func reconcileEmailIfChanged() async {
        guard let user = Auth.auth().currentUser else { return }
        try? await user.reload()
        guard let firebaseEmail = user.email, !firebaseEmail.isEmpty else { return }
        let localEmail = (try? AppDatabase.shared.read { db in
            try User.fetchOne(db, key: user.uid)?.email
        }) ?? nil
        guard localEmail != firebaseEmail else { return }
        try? persistUserMutation { $0.email = firebaseEmail }
    }

    /// Sends a password-reset email to the signed-in user's address — an escape
    /// hatch for changing the password without knowing the current one. No
    /// reauth required.
    func sendPasswordReset() async throws {
        guard let email = Auth.auth().currentUser?.email else { throw AuthServiceError.noCurrentUser }
        try await Auth.auth().sendPasswordReset(withEmail: email)
    }

    // MARK: - Account & Security: link / unlink providers

    /// Links a Google identity to the current account.
    func linkGoogle(presenting: UIViewController) async throws {
        let credential = try await googleCredential(presenting: presenting)
        try await linkCredential(credential)
    }

    /// Links an Apple identity to the current account.
    func linkApple(authorization: ASAuthorization, rawNonce: String) async throws {
        let credential = try appleCredential(from: authorization, rawNonce: rawNonce)
        try await linkCredential(credential)
    }

    /// Adds an email/password sign-in method to an OAuth-only account, unlocking
    /// change-email / change-password.
    func linkPassword(email: String, password: String) async throws {
        let credential = EmailAuthProvider.credential(withEmail: email, password: password)
        try await linkCredential(credential)
    }

    /// Shared link path: links the credential, treating "already linked" as an
    /// idempotent success; any other failure propagates. Refreshes provider
    /// state on success.
    private func linkCredential(_ credential: AuthCredential) async throws {
        guard let user = Auth.auth().currentUser else { throw AuthServiceError.noCurrentUser }
        do {
            try await user.link(with: credential)
        } catch {
            if (error as NSError).code == AuthErrorCode.providerAlreadyLinked.rawValue {
                await refreshProviderState()
                return
            }
            throw error
        }
        await refreshProviderState()
    }

    /// Unlinks a provider. Blocks removing the user's only sign-in method.
    func unlinkProvider(_ providerID: String) async throws {
        guard let user = Auth.auth().currentUser else { throw AuthServiceError.noCurrentUser }
        guard providerState.providerCount > 1 else { throw AuthServiceError.cannotUnlinkLastProvider }
        _ = try await user.unlink(fromProvider: providerID)
        await refreshProviderState()
    }

    // MARK: - Account & Security: delete account

    /// Permanently deletes the account and all of its data.
    ///
    /// Ordering is load-bearing: the Firebase Auth user is deleted FIRST. That's
    /// the only step that can fail for auth reasons (`requiresRecentLogin` → the
    /// caller reauthenticates and retries), and if it fails nothing has been
    /// purged, so the user is left cleanly intact. Deleting the Auth user fires
    /// the `onUserDeleted` Cloud Function, which recursively purges this user's
    /// Firestore data server-side (the only way to remove the parent
    /// `users/{uid}` doc — client rules forbid it). We then tear down local
    /// sync/observers BEFORE wiping the device DB so nothing re-pushes (which
    /// would resurrect the just-purged Firestore data) or observes mid-delete.
    func deleteAccount() async throws {
        guard let user = Auth.auth().currentUser else { throw AuthServiceError.noCurrentUser }

        // 1. Delete the Auth user (→ server-side `onUserDeleted` purges Firestore).
        try await user.delete()

        // 2. Stop sync/observers before the local wipe so nothing re-pulls or
        //    re-pushes during teardown (the auth-state listener also does this,
        //    but asynchronously — do it synchronously here to avoid the race).
        stopUserRowObservation()
        syncService.stop()
        notificationService.clearAll()

        // 3. Wipe device-local state.
        wipeLocalDatabase()
        clearLocalUserDefaults()

        currentUser = nil
        providerState = .none
    }

    /// Deletes every row across the local tables (preserving `schema_version` so
    /// the migrator stays intact). Row-deletes, not file deletion: the
    /// `AppDatabase` singleton has no reopen path and `fatalError`s on init.
    private func wipeLocalDatabase() {
        let tables = [
            "users", "boards", "tasks", "task_steps", "board_tasks",
            "progress_counters", "sync_queue", "composite_tasks",
            "composite_nodes", "compound_children",
            "recurring_board_templates", "default_pools"
        ]
        do {
            try AppDatabase.shared.write { db in
                // `foreign_keys = ON` would reject deleting a parent (e.g.
                // `users`) before its children, and the legacy
                // `tasks` ↔ `task_steps` FK pair is even circular — so no static
                // delete order is safe. `defer_foreign_keys` (settable inside a
                // transaction, unlike `foreign_keys`) defers all FK checks to
                // COMMIT, by which point every row is gone. Order-independent.
                try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
                for table in tables {
                    try db.execute(sql: "DELETE FROM \(table)")
                }
            }
        } catch {
            // Non-fatal: the account is already deleted server-side. Log loudly
            // rather than swallow so a regression here is never invisible.
            print("⚠️ AuthService.wipeLocalDatabase failed: \(error)")
        }
    }

    /// Clears device-local UserDefaults so a fresh sign-up on this device starts
    /// clean (onboarding + tutorial + legacy week-start key).
    private func clearLocalUserDefaults() {
        let defaults = UserDefaults.standard
        for key in [
            "oybc-onboarding-seen",
            "oybc-tutorial-completed-lessons",
            "oybc-tutorial-card-dismissed",
            Self.legacyWeekStartDayKey
        ] {
            defaults.removeObject(forKey: key)
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
        // Cancel scheduled reminders so they don't fire for a signed-out /
        // subsequently different account.
        notificationService.clearAll()
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
                // Heal the email if it changed out-of-band (e.g. the user
                // completed a verifyBeforeUpdateEmail flow on another device).
                existing.email = firebaseUser.email ?? existing.email
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
    case noCurrentUser
    case cannotUnlinkLastProvider

    var errorDescription: String? {
        switch self {
        case .missingGoogleIdToken:
            return "Google sign-in did not return an ID token."
        case .invalidAppleCredential:
            return "Apple sign-in returned an invalid credential."
        case .noCurrentUser:
            return "You're not signed in."
        case .cannotUnlinkLastProvider:
            return "You can't remove your only sign-in method. Add another first."
        }
    }
}
