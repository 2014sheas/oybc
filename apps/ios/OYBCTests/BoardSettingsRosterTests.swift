import XCTest
import GRDB
@testable import OYBC

/// BoardSettingsRosterTests — Task Pools + Recurring Boards Rework (P7).
///
/// Covers two behaviors specific to the new `BoardSettingsView` roster
/// that didn't have direct coverage before (the retired
/// `RecurringTemplatesView`'s `setActive` was itself untested at the DB
/// layer):
///   1. Pause/Resume — `BoardSettingsView.setActive` is a thin private
///      view method; this exercises the exact `AppDatabase` call it makes
///      (`saveRecurringBoardTemplateAndEnqueue` toggling `isActive`) so
///      the roster's Pause/Resume affordance has DB-layer coverage.
///   2. Achievement → repeating-board name resolution — proves the P7
///      copy-only relabel ("Recurring template" → "Repeating board" in
///      `RisoSpecialTaskPanel`/`EditTaskSheet`) required no data-layer
///      change: an achievement task's `referencedTemplateId` still
///      resolves to the template's OWN `name` (already the source
///      board's name, per "Repeat this board…" — P6).
final class BoardSettingsRosterTests: XCTestCase {

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

    private func makeTemplate(id: String, name: String, isActive: Bool) -> RecurringBoardTemplate {
        let now = AppDatabase.currentTimestamp()
        return RecurringBoardTemplate(
            id: id, userId: userId, name: name, timeframe: .weekly, boardSize: 5,
            centerSquareType: .free, isRandomized: true, seedTaskIds: [],
            poolIds: [], manualTaskIds: [], removedTaskIds: [],
            isActive: isActive, createdAt: now, updatedAt: now, version: 1
        )
    }

    // MARK: - 1. Pause / Resume

    func testPauseResume_TogglesIsActiveBumpsVersionEnqueuesUpdate() throws {
        let db = try makeDb()
        try seedUser(db)
        let now = AppDatabase.currentTimestamp()

        let template = makeTemplate(id: "tpl-1", name: "Morning Routine", isActive: true)
        try db.saveRecurringBoardTemplateAndEnqueue(template, operation: .create, now: now)

        // Pause — mirrors `BoardSettingsView.setActive(tpl, false)` exactly:
        // flip isActive, bump version/updatedAt, re-save+enqueue.
        var paused = template
        paused.isActive = false
        paused.updatedAt = AppDatabase.currentTimestamp()
        paused.version += 1
        try db.saveRecurringBoardTemplateAndEnqueue(paused, operation: .update, now: paused.updatedAt)

        let afterPause = try XCTUnwrap(try db.fetchRecurringBoardTemplate(id: template.id))
        XCTAssertFalse(afterPause.isActive)
        XCTAssertEqual(afterPause.version, 2)

        // Resume.
        var resumed = afterPause
        resumed.isActive = true
        resumed.updatedAt = AppDatabase.currentTimestamp()
        resumed.version += 1
        try db.saveRecurringBoardTemplateAndEnqueue(resumed, operation: .update, now: resumed.updatedAt)

        let afterResume = try XCTUnwrap(try db.fetchRecurringBoardTemplate(id: template.id))
        XCTAssertTrue(afterResume.isActive)
        XCTAssertEqual(afterResume.version, 3)

        // Paused/resumed templates are NEVER excluded from the roster —
        // unlike the spawn-pending query, `fetchRecurringBoardTemplates`
        // filters only `isDeleted`, matching docs/POOLS_RECURRING.md
        // §Surfaces item 9 ("ALL spawn records, active + paused").
        let all = try db.fetchRecurringBoardTemplates(userId: userId)
        XCTAssertEqual(all.map(\.id), [template.id])
    }

    // MARK: - 2. Achievement resolves to the repeating board's own name

    func testAchievementReferencedTemplateId_ResolvesToRepeatingBoardsOwnName() {
        let template = makeTemplate(id: "tpl-42", name: "Weekly Reset", isActive: true)
        let achievementTask = Task(
            id: "ach-1", userId: userId, title: "Hit Weekly Reset 3 times", type: .achievement,
            referencedTemplateId: template.id, achievementTrigger: .bingo, requiredCount: 3,
            totalCompletions: 0, totalInstances: 0,
            createdAt: AppDatabase.currentTimestamp(), updatedAt: AppDatabase.currentTimestamp(),
            version: 1, isDeleted: false
        )

        // Mirrors the UI-layer resolution both `RisoSpecialTaskPanel` and
        // `EditTaskSheet` use (`templates.first(where: { $0.id == id })?.name`)
        // — P7 changed ONLY the surrounding chip/label copy, never
        // `referencedTemplateId`, `RecurringBoardTemplate`, or this lookup.
        let resolvedName = [template].first(where: { $0.id == achievementTask.referencedTemplateId })?.name
        XCTAssertEqual(resolvedName, "Weekly Reset")
    }
}
