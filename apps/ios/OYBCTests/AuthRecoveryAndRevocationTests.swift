import XCTest
import FirebaseAuth
@testable import OYBC

/// Recording fake `AuthClient`: logs every account call in order so the tests
/// can pin the signed-out reset's enumeration safety and the Apple
/// revoke-before-delete ordering. Never installs a listener, so
/// `AuthService.init` runs without a configured FirebaseApp.
@MainActor
private final class RecordingAuthClient: AuthClient {
    enum Call: Equatable {
        case sendPasswordReset(String)
        case reauthenticate(String)
        case revoke(String)
        case delete
    }

    var current: AuthUserSnapshot?
    var calls: [Call] = []
    var resetError: Error?
    var reauthError: Error?
    var revokeError: Error?
    var deleteError: Error?

    var currentUserSnapshot: AuthUserSnapshot? { current }

    func addStateDidChangeListener(
        _ listener: @escaping (FirebaseAuth.User?) -> Void
    ) -> AuthStateDidChangeListenerHandle? { nil }

    func linkCurrentUser(with credential: AuthCredential) async throws {}

    func reloadCurrentUser() async throws {}

    func sendPasswordReset(email: String) async throws {
        calls.append(.sendPasswordReset(email))
        if let resetError { throw resetError }
    }

    func reauthenticateCurrentUser(with credential: AuthCredential) async throws {
        calls.append(.reauthenticate(credential.provider))
        if let reauthError { throw reauthError }
    }

    func revokeAppleToken(authorizationCode: String) async throws {
        calls.append(.revoke(authorizationCode))
        if let revokeError { throw revokeError }
    }

    func deleteCurrentUser() async throws {
        calls.append(.delete)
        if let deleteError { throw deleteError }
        current = nil
    }
}

/// App Review launch blockers (ROADMAP Track L → L1): the signed-out "Forgot
/// password?" path never reveals whether an account exists, and deleting an
/// account with Sign in with Apple linked revokes the Apple token BEFORE the
/// Firebase user is deleted (App Store 5.1.1(v)) — never after, never skipped.
@MainActor
final class AuthRecoveryAndRevocationTests: XCTestCase {

    private let uid = "user-uid-0001"

    private func authError(_ code: AuthErrorCode) -> NSError {
        NSError(domain: AuthErrorDomain, code: code.rawValue)
    }

    private func snapshot(providerIDs: [String], isAnonymous: Bool = false) -> AuthUserSnapshot {
        AuthUserSnapshot(uid: uid, email: isAnonymous ? nil : "me@example.com", displayName: nil,
                         photoURL: nil, isAnonymous: isAnonymous, providerIDs: providerIDs)
    }

    private func seedUserRow(_ database: AppDatabase) throws {
        let now = AppDatabase.currentTimestamp()
        try database.saveUser(User(
            id: uid, email: "me@example.com", displayName: nil, photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
    }

    private func appleCredential() -> AuthCredential {
        OAuthProvider.appleCredential(withIDToken: "apple-id-token", rawNonce: "raw-nonce", fullName: nil)
    }

    /// An `AuthService` over a fresh test DB holding the user's row.
    private func makeService(
        _ client: RecordingAuthClient
    ) throws -> (AuthService, AppDatabase) {
        let database = try AppDatabase.makeTestInstance()
        try seedUserRow(database)
        return (AuthService(authClient: client, database: database), database)
    }

    // MARK: - PasswordReset (pure)

    func testNormalizedEmailTrimsSurroundingWhitespace() {
        XCTAssertEqual(PasswordReset.normalizedEmail("  me@example.com \n"), "me@example.com")
        XCTAssertEqual(PasswordReset.normalizedEmail("   "), "")
    }

    func testOnlyUserNotFoundCountsAsSent() {
        XCTAssertTrue(PasswordReset.countsAsSent(authError(.userNotFound)))
        XCTAssertFalse(PasswordReset.countsAsSent(authError(.invalidEmail)))
        XCTAssertFalse(PasswordReset.countsAsSent(authError(.networkError)))
        XCTAssertFalse(PasswordReset.countsAsSent(authError(.tooManyRequests)))
        // Same numeric code outside the Firebase Auth domain is not a match.
        XCTAssertFalse(PasswordReset.countsAsSent(
            NSError(domain: NSURLErrorDomain, code: AuthErrorCode.userNotFound.rawValue)))
    }

    func testSentStatusNamesTheAddress() {
        XCTAssertEqual(PasswordReset.sentStatus(for: "me@example.com"), "Reset link sent to me@example.com")
    }

    // MARK: - sendPasswordReset(toEmail:)

    func testResetSendsTheTrimmedAddress() async throws {
        let client = RecordingAuthClient()
        let (auth, _) = try makeService(client)

        let sentTo = try await auth.sendPasswordReset(toEmail: " me@example.com ")

        XCTAssertEqual(sentTo, "me@example.com")
        XCTAssertEqual(client.calls, [.sendPasswordReset("me@example.com")])
    }

    func testResetForUnknownAccountReadsExactlyLikeASend() async throws {
        let client = RecordingAuthClient()
        client.resetError = authError(.userNotFound)
        let (auth, _) = try makeService(client)

        let sentTo = try await auth.sendPasswordReset(toEmail: "nobody@example.com")

        XCTAssertEqual(sentTo, "nobody@example.com", "user-not-found must not surface (no enumeration)")
    }

    func testResetPropagatesEveryOtherError() async throws {
        for code in [AuthErrorCode.invalidEmail, .networkError] {
            let client = RecordingAuthClient()
            client.resetError = authError(code)
            let (auth, _) = try makeService(client)
            do {
                try await auth.sendPasswordReset(toEmail: "me@example.com")
                XCTFail("\(code) should propagate to the form's error banner")
            } catch {
                XCTAssertEqual((error as NSError).code, code.rawValue)
            }
        }
    }

    // MARK: - AppleTokenRevocation (pure)

    func testRevocationRequiredWheneverAppleIsLinked() {
        XCTAssertTrue(AppleTokenRevocation.isRequired(providerIDs: [ProviderState.appleProviderID]))
        XCTAssertTrue(AppleTokenRevocation.isRequired(
            providerIDs: [ProviderState.passwordProviderID, ProviderState.appleProviderID]))
        XCTAssertFalse(AppleTokenRevocation.isRequired(
            providerIDs: [ProviderState.passwordProviderID, ProviderState.googleProviderID]))
        XCTAssertFalse(AppleTokenRevocation.isRequired(providerIDs: []), "a guest has no providers")
    }

    func testAuthorizationCodeDecoding() {
        XCTAssertEqual(AppleTokenRevocation.authorizationCodeString(from: Data("c0de.abc".utf8)), "c0de.abc")
        XCTAssertEqual(AppleTokenRevocation.authorizationCodeString(from: Data(" c0de \n".utf8)), "c0de")
        XCTAssertNil(AppleTokenRevocation.authorizationCodeString(from: nil))
        XCTAssertNil(AppleTokenRevocation.authorizationCodeString(from: Data()))
        XCTAssertNil(AppleTokenRevocation.authorizationCodeString(from: Data("  ".utf8)))
        XCTAssertNil(AppleTokenRevocation.authorizationCodeString(from: Data([0xFF, 0xFE, 0xFD])),
                     "non-UTF-8 bytes are not a code")
    }

    // MARK: - deleteAccount (no Apple)

    func testDeleteRequiresAppleRevocationReadsTheLiveUser() throws {
        let client = RecordingAuthClient()
        let (auth, _) = try makeService(client)
        client.current = snapshot(providerIDs: [ProviderState.googleProviderID])
        XCTAssertFalse(auth.deleteRequiresAppleRevocation)
        client.current = snapshot(providerIDs: [ProviderState.googleProviderID, ProviderState.appleProviderID])
        XCTAssertTrue(auth.deleteRequiresAppleRevocation)
    }

    func testPlainDeleteRefusesAnAppleLinkedAccount() async throws {
        let client = RecordingAuthClient()
        client.current = snapshot(providerIDs: [ProviderState.passwordProviderID, ProviderState.appleProviderID])
        let (auth, database) = try makeService(client)

        do {
            try await auth.deleteAccount()
            XCTFail("an Apple-linked account must not delete without revoking")
        } catch AuthServiceError.appleRevocationRequired {
            // expected
        }

        XCTAssertEqual(client.calls, [], "nothing deleted")
        XCTAssertNotNil(try database.fetchUser(id: uid))
    }

    func testGuestDiscardStillDeletesAndWipes() async throws {
        let client = RecordingAuthClient()
        client.current = snapshot(providerIDs: [], isAnonymous: true)
        let (auth, database) = try makeService(client)

        try await auth.deleteAccount()

        XCTAssertEqual(client.calls, [.delete], "guest deletion never touches Apple")
        XCTAssertNil(try database.fetchUser(id: uid), "local data wiped")
        XCTAssertNil(auth.currentUser)
    }

    // MARK: - deleteAccountRevokingApple

    func testAppleDeleteReauthsThenRevokesThenDeletes() async throws {
        let client = RecordingAuthClient()
        client.current = snapshot(providerIDs: [ProviderState.passwordProviderID, ProviderState.appleProviderID])
        let (auth, database) = try makeService(client)

        try await auth.deleteAccountRevokingApple(credential: appleCredential(), authorizationCode: "fresh-code")

        XCTAssertEqual(client.calls, [
            .reauthenticate(ProviderState.appleProviderID),
            .revoke("fresh-code"),
            .delete
        ])
        XCTAssertNil(try database.fetchUser(id: uid), "local data wiped after the delete")
        XCTAssertNil(auth.currentUser)
    }

    func testRevokeFailureLeavesTheAccountIntact() async throws {
        let client = RecordingAuthClient()
        client.current = snapshot(providerIDs: [ProviderState.appleProviderID])
        client.revokeError = authError(.networkError)
        let (auth, database) = try makeService(client)

        do {
            try await auth.deleteAccountRevokingApple(credential: appleCredential(), authorizationCode: "fresh-code")
            XCTFail("a failed revoke must abort the delete")
        } catch AuthServiceError.appleRevocationFailed {
            // expected
        }

        XCTAssertEqual(client.calls, [.reauthenticate(ProviderState.appleProviderID), .revoke("fresh-code")],
                       "delete must never run after a failed revoke")
        XCTAssertNotNil(try database.fetchUser(id: uid), "nothing local wiped")
    }

    func testReauthFailureStopsBeforeRevoking() async throws {
        let client = RecordingAuthClient()
        client.current = snapshot(providerIDs: [ProviderState.appleProviderID])
        client.reauthError = authError(.userMismatch)
        let (auth, database) = try makeService(client)

        do {
            try await auth.deleteAccountRevokingApple(credential: appleCredential(), authorizationCode: "fresh-code")
            XCTFail("reauth failure should propagate")
        } catch {
            XCTAssertEqual((error as NSError).code, AuthErrorCode.userMismatch.rawValue)
        }

        XCTAssertEqual(client.calls, [.reauthenticate(ProviderState.appleProviderID)])
        XCTAssertNotNil(try database.fetchUser(id: uid))
    }

    func testDeleteFailureAfterRevokeWipesNothingLocal() async throws {
        let client = RecordingAuthClient()
        client.current = snapshot(providerIDs: [ProviderState.appleProviderID])
        client.deleteError = authError(.networkError)
        let (auth, database) = try makeService(client)

        do {
            try await auth.deleteAccountRevokingApple(credential: appleCredential(), authorizationCode: "fresh-code")
            XCTFail("delete failure should propagate")
        } catch {
            XCTAssertEqual((error as NSError).code, AuthErrorCode.networkError.rawValue)
        }

        XCTAssertEqual(client.calls.last, .delete)
        XCTAssertNotNil(try database.fetchUser(id: uid), "a surviving account keeps its local data")
    }

    func testAppleDeleteWhenSignedOutDoesNothing() async throws {
        let client = RecordingAuthClient()
        let (auth, _) = try makeService(client)

        do {
            try await auth.deleteAccountRevokingApple(credential: appleCredential(), authorizationCode: "fresh-code")
            XCTFail("signed out should throw")
        } catch AuthServiceError.noCurrentUser {
            // expected
        }
        XCTAssertEqual(client.calls, [])
    }
}
