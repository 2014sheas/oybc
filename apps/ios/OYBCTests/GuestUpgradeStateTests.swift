import XCTest
import GRDB
import FirebaseAuth
@testable import OYBC

/// Fake `AuthClient`: `current` is what `Auth.auth().currentUser` would be;
/// a successful link swaps it to `afterLink` (same uid, now permanent), which
/// is exactly what Firebase's in-place `link(with:)` does. Never installs a
/// listener, so `AuthService.init` runs without a configured FirebaseApp.
@MainActor
private final class FakeAuthClient: AuthClient {
    var current: AuthUserSnapshot?
    var afterLink: AuthUserSnapshot?
    var linkError: Error?

    var currentUserSnapshot: AuthUserSnapshot? { current }

    func addStateDidChangeListener(
        _ listener: @escaping (FirebaseAuth.User?) -> Void
    ) -> AuthStateDidChangeListenerHandle? { nil }

    func linkCurrentUser(with credential: AuthCredential) async throws {
        if let linkError { throw linkError }
        current = afterLink
    }

    func reloadCurrentUser() async throws {}
}

/// Guest-mode stateful invariants (docs/GUEST_MODE.md, CLAUDE.md §Guest Mode):
/// post-link reconcile, the collision queue-clear, and the discard wipe list.
@MainActor
final class GuestUpgradeStateTests: XCTestCase {

    private let anonUid = "anon-uid-0001"

    private func anonSnapshot() -> AuthUserSnapshot {
        AuthUserSnapshot(uid: anonUid, email: nil, displayName: nil, photoURL: nil,
                         isAnonymous: true, providerIDs: [])
    }

    private func linkedSnapshot() -> AuthUserSnapshot {
        AuthUserSnapshot(uid: anonUid, email: "me@example.com", displayName: "Me", photoURL: nil,
                         isAnonymous: false, providerIDs: [ProviderState.passwordProviderID])
    }

    /// The row `signInAnonymously` leaves behind: empty email, no name.
    private func seedAnonRow(_ database: AppDatabase) throws {
        let now = AppDatabase.currentTimestamp()
        try database.saveUser(User(
            id: anonUid, email: "", displayName: nil, photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
    }

    private func seedSyncItem(_ database: AppDatabase, id: String) throws {
        try database.saveSyncItem(SyncQueueItem(
            id: id, entityType: "tasks", entityId: "entity-\(id)", operationType: .update,
            payload: "{}", status: .pending, retryCount: 0, lastError: nil,
            createdAt: AppDatabase.currentTimestamp(), lastAttemptAt: nil, completedAt: nil, priority: 0
        ))
    }

    /// Every table in the live (fully migrated) schema, minus SQLite/GRDB
    /// internals and `schema_version` (Schema.sql bookkeeping, not user data —
    /// `wipeLocalDatabase` deliberately preserves it, per its doc comment).
    private func liveTables(_ database: AppDatabase) throws -> [String] {
        try database.read { db in
            try String.fetchAll(db, sql: """
                SELECT name FROM sqlite_master
                WHERE type = 'table' AND name NOT LIKE 'sqlite_%'
                  AND name NOT IN ('grdb_migrations', 'schema_version')
                ORDER BY name
                """)
        }
    }

    private func rowCount(_ database: AppDatabase, _ table: String) throws -> Int {
        try database.read { db in try Int.fetchOne(db, sql: "SELECT COUNT(*) FROM \(table)") ?? 0 }
    }

    // MARK: - Post-link reconcile (linkCredential)

    func testLinkReupsertsLocalRowAndClearsAnonFlag() async throws {
        let database = try AppDatabase.makeTestInstance()
        try seedAnonRow(database)
        let client = FakeAuthClient()
        client.current = anonSnapshot()
        client.afterLink = linkedSnapshot()
        let auth = AuthService(authClient: client, database: database)
        auth.isAnonymous = true

        try await auth.linkPassword(email: "me@example.com", password: "secret1")

        let row = try XCTUnwrap(database.fetchUser(id: anonUid))
        XCTAssertEqual(row.email, "me@example.com", "local row not re-upserted after link")
        XCTAssertEqual(row.displayName, "Me")
        XCTAssertEqual(row.version, 2)
        XCTAssertEqual(auth.currentUser?.email, "me@example.com")
        XCTAssertFalse(auth.isAnonymous, "isAnonymous not recomputed after link")
        XCTAssertTrue(auth.providerState.hasPassword)
    }

    func testCollisionLinkFailureLeavesGuestStateUntouched() async throws {
        let database = try AppDatabase.makeTestInstance()
        try seedAnonRow(database)
        let client = FakeAuthClient()
        client.current = anonSnapshot()
        client.linkError = NSError(domain: AuthErrorDomain, code: AuthErrorCode.emailAlreadyInUse.rawValue)
        let auth = AuthService(authClient: client, database: database)
        auth.isAnonymous = true

        do {
            try await auth.linkPassword(email: "taken@example.com", password: "secret1")
            XCTFail("collision should propagate")
        } catch {
            XCTAssertTrue(AuthService.isCredentialCollision(error))
        }

        XCTAssertEqual(try database.fetchUser(id: anonUid)?.email, "")
        XCTAssertEqual(try database.fetchUser(id: anonUid)?.version, 1)
        XCTAssertTrue(auth.isAnonymous)
    }

    // MARK: - clearPendingSyncQueue

    func testClearPendingSyncQueueEmptiesQueueOnly() throws {
        let database = try AppDatabase.makeTestInstance()
        try seedAnonRow(database)
        try seedSyncItem(database, id: "q1")
        try seedSyncItem(database, id: "q2")
        let auth = AuthService(authClient: FakeAuthClient(), database: database)

        auth.clearPendingSyncQueue()

        XCTAssertEqual(try rowCount(database, "sync_queue"), 0)
        XCTAssertNotNil(try database.fetchUser(id: anonUid), "queue clear must not touch guest rows")
    }

    // MARK: - wipeLocalDatabase

    func testUserScopedTablesMatchesLiveSchemaExactly() throws {
        let database = try AppDatabase.makeTestInstance()
        let live = Set(try liveTables(database))
        let wiped = Set(AuthService.userScopedTables)
        XCTAssertFalse(live.isEmpty)
        XCTAssertEqual(live.subtracting(wiped), [], "tables the discard wipe would leave behind")
        // A stale name makes `DELETE FROM` throw, rolling back the WHOLE wipe.
        XCTAssertEqual(wiped.subtracting(live), [], "wipe-list names with no table")
    }

    /// Inserts one row into `table`, driven by the live schema so it never
    /// drifts as columns are added: the PK gets `seed-<table>`, every FK column
    /// points at the referenced table's own seed row (`seed-<parent>`), and any
    /// other NOT NULL column without a default gets a type-appropriate filler.
    /// Must run inside a transaction with `defer_foreign_keys = ON` so insert
    /// order doesn't matter — every parent is seeded by COMMIT.
    private func seedRow(_ db: Database, table: String) throws {
        var fkTargets: [String: String] = [:]
        for fk in try Row.fetchAll(db, sql: "PRAGMA foreign_key_list(\(table))") {
            let from: String = fk["from"]
            let parent: String = fk["table"]
            fkTargets[from] = "seed-\(parent)"
        }
        var columns: [String] = []
        var values: [DatabaseValueConvertible] = []
        for col in try Row.fetchAll(db, sql: "PRAGMA table_info(\(table))") {
            let name: String = col["name"]
            let type = ((col["type"] as String?) ?? "").uppercased()
            let notNull: Bool = col["notnull"]
            let hasDefault = !(col["dflt_value"] as DatabaseValue).isNull
            let isPK = (col["pk"] as Int) > 0
            if isPK {
                columns.append(name)
                values.append(type.contains("INT") ? 1 : "seed-\(table)")
            } else if let target = fkTargets[name] {
                columns.append(name)
                values.append(target)
            } else if notNull && !hasDefault {
                columns.append(name)
                values.append(type.contains("INT") || type.contains("BOOL") || type.contains("REAL") ? 0 : "seed")
            }
        }
        let placeholders = Array(repeating: "?", count: columns.count).joined(separator: ", ")
        try db.execute(
            sql: "INSERT INTO \(table) (\(columns.joined(separator: ", "))) VALUES (\(placeholders))",
            arguments: StatementArguments(values)
        )
    }

    /// Seeds one row into every table named by `AuthService.userScopedTables`
    /// AND every table in the live schema (the union: iterating only the
    /// constant would let a table dropped from it go unseeded, making the
    /// "wiped afterwards" assertion vacuous for exactly the regression it
    /// exists to catch). Then proves each is non-empty before and empty after.
    func testWipeLocalDatabaseEmptiesEveryTable() throws {
        let database = try AppDatabase.makeTestInstance()
        let tables = Set(AuthService.userScopedTables).union(try liveTables(database)).sorted()
        try database.write { db in
            try db.execute(sql: "PRAGMA defer_foreign_keys = ON")
            for table in tables { try seedRow(db, table: table) }
        }
        for table in tables {
            XCTAssertGreaterThan(try rowCount(database, table), 0, "\(table) not seeded — precondition vacuous")
        }
        let auth = AuthService(authClient: FakeAuthClient(), database: database)

        auth.wipeLocalDatabase()

        for table in tables {
            XCTAssertEqual(try rowCount(database, table), 0, "\(table) not wiped")
        }
    }
}
