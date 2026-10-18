import XCTest
import GRDB
@testable import OYBC

/// Cross-platform pull-tolerance vectors (issue #300; docs/SYNC_STRATEGY.md
/// §Forward-compatible pull) run END TO END through iOS's `applyPullBatch`. The
/// SAME fixture (`packages/shared/tests/fixtures/pullToleranceVectors.json`, a
/// byte-identical copy under `OYBCTests/Fixtures`) runs through web's
/// `applyRemoteSubdoc` in `pullToleranceVectors.test.ts`: both suites passing is
/// what proves a pulled doc is applied (with the same fallback values) or
/// quarantined IDENTICALLY on the two platforms.
@MainActor
final class PullToleranceVectorTests: XCTestCase {

    private struct Vector: Decodable {
        let name: String
        let collection: String
        let set: [String: AnyJSON]
        let disposition: String
        let expect: [String: AnyJSON]?
    }

    /// A JSON scalar / null, kept as the Foundation value `JSONSerialization` would give.
    private struct AnyJSON: Decodable {
        let value: Any
        init(from decoder: Decoder) throws {
            let c = try decoder.singleValueContainer()
            if c.decodeNil() { value = NSNull() }
            else if let b = try? c.decode(Bool.self) { value = b }
            else if let i = try? c.decode(Int.self) { value = i }
            else if let d = try? c.decode(Double.self) { value = d }
            else if let s = try? c.decode(String.self) { value = s }
            else if let a = try? c.decode([AnyJSON].self) { value = a.map(\.value) }
            else { value = NSNull() }
        }
    }

    private let userId = "u1"

    private func loadFixture() throws -> (bases: [String: [String: Any]], cases: [Vector]) {
        let url = try XCTUnwrap(Bundle(for: PullToleranceVectorTests.self).url(forResource: "pullToleranceVectors", withExtension: "json"),
                                "pullToleranceVectors.json is missing from the test bundle (OYBCTests/Fixtures + xcodegen generate)")
        let data = try Data(contentsOf: url)
        let root = try XCTUnwrap(JSONSerialization.jsonObject(with: data) as? [String: Any])
        let bases = try XCTUnwrap(root["bases"] as? [String: [String: Any]])
        struct Fixture: Decodable { let cases: [Vector] }
        return (bases, try JSONDecoder().decode(Fixture.self, from: data).cases)
    }

    private func doc(_ base: [String: Any], set: [String: Any] = [:]) -> [String: Any] {
        var out = base
        for (key, value) in out { if let s = value as? String, s == "$USER" { out[key] = userId } }
        for (key, value) in set { out[key] = value }
        out["_syncedAt"] = Date(timeIntervalSince1970: 1_790_000_000)
        return out
    }

    private func collection(_ name: String) throws -> PullCollection {
        try XCTUnwrap(pullApplyCollections.first { $0.firestoreName == name })
    }

    /// The normalized value of `field` as the TYPED model reads the stored row.
    private func normalized(_ db: AppDatabase, _ collection: String, id: String, field: String) throws -> Any {
        try db.read { database in
            switch (collection, field) {
            case ("boards", "centerSquareType"): return try Board.fetchOne(database, key: id)?.centerSquareType.rawValue ?? NSNull()
            case ("recurringBoardTemplates", "centerSquareType"): return try RecurringBoardTemplate.fetchOne(database, key: id)?.centerSquareType.rawValue ?? NSNull()
            case ("coreBoardDefaults", "defaultBoardSize"): return try CoreBoardDefault.fetchOne(database, key: id)?.defaultBoardSize?.rawValue ?? NSNull()
            case ("coreBoardDefaults", "defaultCenterType"): return try CoreBoardDefault.fetchOne(database, key: id)?.defaultCenterType?.rawValue ?? NSNull()
            case ("boardTasks", "targetKind"): return try BoardTask.fetchOne(database, key: id)?.targetKind?.rawValue ?? NSNull()
            case ("boardTasks", "targetOverride"): return try BoardTask.fetchOne(database, key: id)?.targetOverride ?? NSNull()
            default: XCTFail("no accessor for \(collection).\(field)"); return NSNull()
            }
        }
    }

    private func same(_ a: Any, _ b: Any) -> Bool {
        if a is NSNull, b is NSNull { return true }
        if let x = a as? String, let y = b as? String { return x == y }
        if let x = a as? NSNumber, let y = b as? NSNumber { return x.doubleValue == y.doubleValue }
        return false
    }

    func test_everyVector_behavesAsTheFixtureSays() async throws {
        let (bases, cases) = try loadFixture()
        XCTAssertFalse(cases.isEmpty)
        for vector in cases {
            let db = try AppDatabase.makeTestInstance()
            let now = AppDatabase.currentTimestamp()
            try db.saveUser(User(id: userId, email: "t@e.com", displayName: "T", photoURL: nil,
                                 preferences: User.encodePreferences(.defaults), createdAt: now, updatedAt: now,
                                 lastSyncedAt: nil, version: 1))
            if vector.collection == "boardTasks" { // the placement's foreign keys
                for prerequisite in ["boards", "tasks"] {
                    _ = try await db.applyPullBatch(collection: collection(prerequisite), docs: PullDocs(docs: [doc(bases[prerequisite]!)]), userId: userId, checkpoint: false)
                }
            }
            let base = try XCTUnwrap(bases[vector.collection], vector.name)
            let pulled = doc(base, set: vector.set.mapValues(\.value))
            let id = try XCTUnwrap(pulled["id"] as? String)
            let col = try collection(vector.collection)

            let outcome = try await db.applyPullBatch(collection: col, docs: PullDocs(docs: [pulled]), userId: userId, checkpoint: false)

            let stored = try db.read { try Int.fetchOne($0, sql: "SELECT COUNT(*) FROM \(col.grdbTable) WHERE id = ?", arguments: [id]) ?? 0 }
            let ledgered = try db.read { try AppDatabase.fetchQuarantinedDocs(db: $0, userId: self.userId) }.filter { $0.collection == vector.collection }
            if vector.disposition == "applied" {
                XCTAssertEqual(outcome.pulled, 1, vector.name)
                XCTAssertEqual(stored, 1, vector.name)
                XCTAssertTrue(ledgered.isEmpty, vector.name)
                for (field, want) in vector.expect ?? [:] {
                    let got = try normalized(db, vector.collection, id: id, field: field)
                    XCTAssertTrue(same(got, want.value), "\(vector.name): \(field) = \(got), expected \(want.value)")
                }
            } else {
                XCTAssertEqual(outcome.pulled, 0, vector.name)
                XCTAssertEqual(stored, 0, vector.name)
                XCTAssertEqual(ledgered.map(\.docId), [id], vector.name)
            }
        }
    }
}
