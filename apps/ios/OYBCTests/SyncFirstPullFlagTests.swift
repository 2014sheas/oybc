import XCTest
@testable import OYBC

/// Board Edit redesign slice 4 (D5) — `SyncService.hasCompletedFirstPull`
/// gates the lazy auto-close pass (`BoardListView`) until this session's
/// first pull lands, so a Reopen made on another device is seen first. The
/// flag is session-scoped: `stop()` (sign-out / account switch) must clear it,
/// or the next account's first auto-close pass skips the wait entirely.
@MainActor
final class SyncFirstPullFlagTests: XCTestCase {

    func testStopClearsFirstPullFlag() throws {
        let sut = SyncService(database: try AppDatabase.makeTestInstance(), currentAuthUid: { "u1" })
        sut.hasCompletedFirstPull = true

        sut.stop()

        XCTAssertFalse(sut.hasCompletedFirstPull)
    }
}
