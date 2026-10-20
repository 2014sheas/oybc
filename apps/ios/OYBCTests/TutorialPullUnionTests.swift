import XCTest
import GRDB
@testable import OYBC

/// A user-doc pull never regresses tutorial progress, whichever side wins
/// last-write-wins (twin of web's `unionTutorialProgress` call in its pull).
final class TutorialPullUnionTests: XCTestCase {

    private let userId = "u1"

    private func seedUser(_ db: AppDatabase, progress: TutorialProgress, version: Int) throws {
        var prefs = UserPreferences.defaults
        prefs.tutorialProgress = progress
        let now = AppDatabase.currentTimestamp()
        try db.saveUser(User(
            id: userId, email: "t@example.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(prefs), createdAt: now, updatedAt: now, lastSyncedAt: nil, version: version
        ))
    }

    private func remoteDoc(_ db: AppDatabase, progress: TutorialProgress, version: Int) throws -> [String: Any] {
        var doc = try db.read { try AppDatabase.fetchPullLocalRecord(db: $0, grdbTable: "users", id: userId) } ?? [:]
        var prefs = UserPreferences.defaults
        prefs.tutorialProgress = progress
        let json = try XCTUnwrap(User.encodePreferences(prefs))
        doc["preferences"] = try JSONSerialization.jsonObject(with: Data(json.utf8))
        doc["version"] = version
        doc["updatedAt"] = AppDatabase.currentTimestamp()
        return doc
    }

    func test_remoteWinsWithOlderProgress_keepsTheFinishedLesson() throws {
        let db = try AppDatabase.makeTestInstance()
        var local = TutorialProgress.empty
        local.set(.createTask, .done)
        try seedUser(db, progress: local, version: 2)
        let remote = try remoteDoc(db, progress: .empty, version: 9)
        let outcome = try db.write { try AppDatabase.applyPulledUserDocTx(db: $0, userId: userId, remoteData: remote) }
        XCTAssertTrue(outcome.applied)
        let stored = try XCTUnwrap(db.fetchUser(id: userId))
        XCTAssertEqual(stored.version, 9, "the remote document won")
        XCTAssertEqual(stored.decodedPreferences.tutorialProgress.state(of: .createTask), .done)
    }

    func test_localWinsButRemoteKnewMore_foldsItInAndReasserts() throws {
        let db = try AppDatabase.makeTestInstance()
        try seedUser(db, progress: .empty, version: 9)
        var remoteProgress = TutorialProgress.empty
        remoteProgress.set(.createBoard, .done)
        remoteProgress.cardDismissed = true
        let remote = try remoteDoc(db, progress: remoteProgress, version: 2)
        let outcome = try db.write { try AppDatabase.applyPulledUserDocTx(db: $0, userId: userId, remoteData: remote) }
        XCTAssertFalse(outcome.applied)
        let stored = try XCTUnwrap(db.fetchUser(id: userId))
        XCTAssertEqual(stored.decodedPreferences.tutorialProgress.state(of: .createBoard), .done)
        XCTAssertTrue(stored.decodedPreferences.tutorialProgress.cardDismissed)
        XCTAssertEqual(stored.version, 10, "folded progress bumps the version so it wins the push")
        XCTAssertTrue(try db.fetchPendingSyncItems().contains { $0.entityType == "users" })
    }
}
