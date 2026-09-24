import XCTest
import FirebaseAuth
import AuthenticationServices
@testable import OYBC

/// Guest-upgrade collision — **verify before destroy** (docs/GUEST_MODE.md
/// §Upgrade, CLAUDE.md §Guest Mode). Sign into the existing account FIRST;
/// only a successful sign-in may clear the anon sync queue. Mirrors web
/// `guestCollisionSwitch.test.ts`.
@MainActor
final class GuestCollisionSwitchTests: XCTestCase {

    private struct StubError: Error {}

    private func authError(_ code: AuthErrorCode) -> NSError {
        NSError(domain: AuthErrorDomain, code: code.rawValue)
    }

    // MARK: - Decision table

    func testSuccessSignsInThenClearsThenSwitches() {
        XCTAssertEqual(
            GuestCollisionSwitch.effects(for: .success),
            [.signInExisting, .clearAnonQueue, .switchSession]
        )
    }

    func testEveryFailureStopsAfterSignInWithGuestDataIntact() {
        for outcome in [CollisionSignInOutcome.wrongPassword, .cancelled, .otherError] {
            XCTAssertEqual(
                GuestCollisionSwitch.effects(for: outcome),
                [.signInExisting, .keepGuestData],
                "outcome \(outcome)"
            )
        }
    }

    func testClassify() {
        XCTAssertEqual(GuestCollisionSwitch.classify(authError(.wrongPassword)), .wrongPassword)
        XCTAssertEqual(GuestCollisionSwitch.classify(authError(.invalidCredential)), .wrongPassword)
        XCTAssertEqual(GuestCollisionSwitch.classify(ASAuthorizationError(.canceled)), .cancelled)
        XCTAssertEqual(GuestCollisionSwitch.classify(authError(.networkError)), .otherError)
        XCTAssertEqual(GuestCollisionSwitch.classify(StubError()), .otherError)
    }

    // MARK: - Executor (what UpgradeAccountSheet.resolveCollision runs)

    func testRunOnSuccessOrdersSignInClearSwitch() async throws {
        var log: [CollisionEffect] = []
        try await GuestCollisionSwitch.run(
            signInExisting: { log.append(.signInExisting) },
            clearAnonQueue: { log.append(.clearAnonQueue) },
            switchSession: { log.append(.switchSession) }
        )
        XCTAssertEqual(log, [.signInExisting, .clearAnonQueue, .switchSession])
    }

    func testRunOnFailedSignInRethrowsAndDestroysNothing() async {
        let failures: [(String, Error)] = [
            ("wrong password", authError(.wrongPassword)),
            ("cancelled", ASAuthorizationError(.canceled)),
            ("other", authError(.networkError)),
        ]
        for (label, failure) in failures {
            var log: [CollisionEffect] = []
            do {
                try await GuestCollisionSwitch.run(
                    signInExisting: { log.append(.signInExisting); throw failure },
                    clearAnonQueue: { log.append(.clearAnonQueue) },
                    switchSession: { log.append(.switchSession) }
                )
                XCTFail("\(label): expected the sign-in error to propagate")
            } catch {
                XCTAssertEqual((error as NSError).code, (failure as NSError).code, label)
            }
            XCTAssertEqual(log, [.signInExisting], "\(label): queue cleared or session switched on a failed sign-in")
        }
    }
}
