import XCTest
@testable import OYBC

/// 2026-09 audit (T1, Task 6) — `pushSyncCore` refuses to push for a uid other
/// than the signed-in Firebase user (a loop outliving an account switch, or a
/// stale debounced push). Web twin: `assertSyncUserMatches` at the top of
/// `pushSync`/`pullSync` (apps/web `syncUserGuard.test.ts`).
///
/// The signed-in uid is injected through `SyncService(currentAuthUid:)`, so no
/// Firebase session is needed. Only the SKIP path is exercised: the pass path
/// runs queue maintenance on `AppDatabase.shared` (push isn't DB-injected — see
/// the E3 scope caveat on `init`), which a unit test must not touch.
@MainActor
final class SyncPushUidGuardTests: XCTestCase {

    private let skipMessage = "Push skipped — sync userId does not match authenticated user"

    private func makeSut(currentUid: String?) throws -> SyncService {
        SyncService(database: try AppDatabase.makeTestInstance(), currentAuthUid: { currentUid })
    }

    func testPushForAnotherUidIsSkippedAndLogged() async throws {
        let sut = try makeSut(currentUid: "signed-in-uid")

        let result = await sut.pushSync(userId: "other-uid")

        XCTAssertEqual(result.details, [skipMessage])
        XCTAssertEqual(result.pushed, 0)
        XCTAssertEqual(result.failed, 0)
        XCTAssertEqual(sut.syncEvents.first?.message, skipMessage)
    }

    func testPushWithNoSignedInUserIsSkipped() async throws {
        let sut = try makeSut(currentUid: nil)

        let result = await sut.pushSync(userId: "any-uid")

        XCTAssertEqual(result.details, [skipMessage])
        XCTAssertEqual(sut.syncEvents.first?.message, skipMessage)
    }
}
