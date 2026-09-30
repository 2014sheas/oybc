import XCTest
import GRDB
@testable import OYBC

/// Profile reorg PR3 — the four "Prompt for {timeframe} board" toggles
/// moved from `BoardSettingsView` to `NotificationPreferencesView`'s new
/// "BOARD RENEWALS" card (`design_handoff_profile_reorg/README.md` §5).
/// Both views write through the exact same call
/// (`AppDatabase.updateUserPreferences`), so this exercises that write path
/// for the four fields directly — the same one
/// `NotificationPreferencesView.setPref` and the retired
/// `BoardSettingsView.bind(_:)` both used.
///
/// These prefs gate the Boards-tab "set up the next window" banner
/// (lazy, checked on app-open) — never an OS notification — so the write
/// itself carries no reconcile; this test only proves the persisted value
/// + version bump, matching `BoardSettingsRosterTests`'s pattern for the
/// adjacent pause/resume write.
final class BoardRenewalsPreferencesTests: XCTestCase {

    private let userId = "u1"

    private func makeDb() throws -> AppDatabase { try AppDatabase.makeTestInstance() }

    private func seedUser(_ db: AppDatabase) throws {
        let now = AppDatabase.currentTimestamp()
        try db.saveUser(User(
            id: userId, email: "t@e.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
    }

    func test_defaults_allFourEnabled() {
        XCTAssertTrue(UserPreferences.defaults.recurringDailyEnabled)
        XCTAssertTrue(UserPreferences.defaults.recurringWeeklyEnabled)
        XCTAssertTrue(UserPreferences.defaults.recurringMonthlyEnabled)
        XCTAssertTrue(UserPreferences.defaults.recurringYearlyEnabled)
    }

    func test_toggleDaily_persistsAndBumpsVersion() throws {
        let db = try makeDb()
        try seedUser(db)

        let updated = try XCTUnwrap(try db.updateUserPreferences(userId: userId) { current in
            var next = current
            next.recurringDailyEnabled = false
            return next
        })
        let updatedPrefs = updated.decodedPreferences

        XCTAssertFalse(updatedPrefs.recurringDailyEnabled)
        // The other three are untouched by a single-field toggle.
        XCTAssertTrue(updatedPrefs.recurringWeeklyEnabled)
        XCTAssertTrue(updatedPrefs.recurringMonthlyEnabled)
        XCTAssertTrue(updatedPrefs.recurringYearlyEnabled)
        XCTAssertEqual(updated.version, 2)

        let reread = try XCTUnwrap(try db.fetchUser(id: userId))
        XCTAssertFalse(reread.decodedPreferences.recurringDailyEnabled)
    }

    func test_toggleAllFour_independently() throws {
        let db = try makeDb()
        try seedUser(db)

        _ = try db.updateUserPreferences(userId: userId) { current in
            var next = current
            next.recurringWeeklyEnabled = false
            return next
        }
        let afterWeekly = try XCTUnwrap(try db.updateUserPreferences(userId: userId) { current in
            var next = current
            next.recurringMonthlyEnabled = false
            return next
        }).decodedPreferences
        XCTAssertFalse(afterWeekly.recurringWeeklyEnabled)
        XCTAssertFalse(afterWeekly.recurringMonthlyEnabled)

        let afterYearly = try XCTUnwrap(try db.updateUserPreferences(userId: userId) { current in
            var next = current
            next.recurringYearlyEnabled = false
            return next
        }).decodedPreferences
        XCTAssertFalse(afterYearly.recurringWeeklyEnabled)
        XCTAssertFalse(afterYearly.recurringMonthlyEnabled)
        XCTAssertFalse(afterYearly.recurringYearlyEnabled)
        XCTAssertTrue(afterYearly.recurringDailyEnabled)
    }
}
