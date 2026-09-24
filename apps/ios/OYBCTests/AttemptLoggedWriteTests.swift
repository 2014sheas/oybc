import XCTest
import GRDB
@testable import OYBC

/// 2026-09 audit (T1, Task 4) — `attemptLoggedWrite` replaced bare `try?`
/// on counter log/undo and the Boards-tab lazy passes. The Counters hub
/// branches on its result to decide between the "Logged +N" toast and the
/// error alert, so the success/failure signal is the contract under test.
final class AttemptLoggedWriteTests: XCTestCase {

    private struct WriteFailure: Error {}

    func testReturnsTrueAndRunsTheWriteWhenItSucceeds() {
        var ran = false
        let ok = attemptLoggedWrite("test") { ran = true }
        XCTAssertTrue(ok)
        XCTAssertTrue(ran)
    }

    func testReturnsFalseWhenTheWriteThrows() {
        let ok = attemptLoggedWrite("test") { throw WriteFailure() }
        XCTAssertFalse(ok)
    }

    func testReturnsFalseForARealFailingDatabaseWrite() throws {
        let db = try AppDatabase.makeTestInstance()
        // A write against a table that doesn't exist fails inside GRDB — the
        // same error path a failing counter write would take.
        let ok = attemptLoggedWrite("test") {
            try db.write { try $0.execute(sql: "DELETE FROM no_such_table") }
        }
        XCTAssertFalse(ok)
    }
}
