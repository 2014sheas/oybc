import XCTest
@testable import OYBC

final class AppDatabaseCounterCreateKindTests: XCTestCase {
    func testContinuousCounterSeedsAFraction() throws {
        let db = try AppDatabase.makeTestInstance(); try LinkedWindowKit.seedUser(db)
        let t = try db.createCounterTask(userId: "u1", action: "Run", unit: "miles", startingCount: 148.6, countKind: .continuous, now: "2026-10-07T00:00:00.000Z")
        XCTAssertEqual(t.countKind, .continuous)
        XCTAssertEqual(try db.fetchTask(id: t.id)?.currentCount, 148.6)
    }
    func testDiscreteRefusesAFractionalSeed() throws {
        let db = try AppDatabase.makeTestInstance(); try LinkedWindowKit.seedUser(db)
        XCTAssertThrowsError(try db.createCounterTask(userId: "u1", action: "Do", unit: "push-ups", startingCount: 2.5, now: "2026-10-07T00:00:00.000Z"))
    }
    func testDefaultKindIsWrittenExplicitly() throws {
        let db = try AppDatabase.makeTestInstance(); try LinkedWindowKit.seedUser(db)
        let t = try db.createCounterTask(userId: "u1", action: "Do", unit: "push-ups", startingCount: nil, now: "2026-10-07T00:00:00.000Z")
        XCTAssertEqual(try db.fetchTask(id: t.id)?.countKind, .discrete)
    }
}
