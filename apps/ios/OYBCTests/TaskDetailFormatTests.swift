import XCTest
@testable import OYBC

/// Task Detail's pure copy rules. Web twin: `taskDetailFormat.test.ts` — keep the strings identical.
final class TaskDetailFormatTests: XCTestCase {

    private let utc = TimeZone(identifier: "UTC")!
    private let now = parseISO8601Date("2026-10-17T12:00:00.000Z")!

    private func task(_ type: TaskType, trigger: AchievementTrigger? = nil, shared: String? = nil, isCounter: Bool = false) -> Task {
        var t = Task(
            id: "t", userId: "u", title: "T", type: type, action: nil, unit: nil, maxCount: nil, totalCompletions: 0, totalInstances: 0,
            createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z", version: 1, isDeleted: false
        )
        t.achievementTrigger = trigger
        t.sharedCounterId = shared
        t.isCounter = isCounter
        return t
    }

    func testKickers() {
        XCTAssertEqual(TaskDetailFormat.kicker(task: task(.counting, shared: "root"), countKind: .discrete, counterName: nil, ruleLabel: nil), "Counting · linked counter")
        XCTAssertEqual(TaskDetailFormat.kicker(task: task(.counting), countKind: .duration, counterName: nil, ruleLabel: nil), "Counting · duration")
        XCTAssertEqual(TaskDetailFormat.kicker(task: task(.counting), countKind: .continuous, counterName: nil, ruleLabel: nil), "Counting · continuous")
        XCTAssertEqual(TaskDetailFormat.kicker(task: task(.counting), countKind: .discrete, counterName: nil, ruleLabel: nil), "Counting")
        XCTAssertEqual(TaskDetailFormat.kicker(task: task(.normal), countKind: .discrete, counterName: "Books", ruleLabel: nil), "Normal · counts toward Books")
        XCTAssertEqual(TaskDetailFormat.kicker(task: task(.normal), countKind: .discrete, counterName: nil, ruleLabel: nil), "Normal")
        XCTAssertEqual(TaskDetailFormat.kicker(task: task(.compound), countKind: .discrete, counterName: nil, ruleLabel: "All of 3"), "Compound · all of 3")
        XCTAssertEqual(TaskDetailFormat.kicker(task: task(.achievement, trigger: .bingo), countKind: .discrete, counterName: nil, ruleLabel: nil), "Achievement · first bingo")
        XCTAssertEqual(TaskDetailFormat.kicker(task: task(.achievement), countKind: .discrete, counterName: nil, ruleLabel: nil), "Achievement · greenlog")
    }

    func testNormalStatusNamesTheWindow() {
        XCTAssertEqual(TaskDetailFormat.normalStatus(isDone: false, timeframe: .weekly), "Not done this week")
        XCTAssertEqual(TaskDetailFormat.normalStatus(isDone: false, timeframe: .daily), "Not done today")
        XCTAssertEqual(TaskDetailFormat.normalStatus(isDone: false, timeframe: .custom), "Not done")
        XCTAssertEqual(TaskDetailFormat.normalStatus(isDone: true, timeframe: .weekly), "Done")
    }

    func testActiveCaption() {
        XCTAssertEqual(
            TaskDetailFormat.activeCaption(timeframe: .weekly, endDate: "2026-10-19T00:00:00.000Z", now: now, timeZone: utc),
            "This week · ends Mon · 2 days left"
        )
        XCTAssertEqual(
            TaskDetailFormat.activeCaption(timeframe: .monthly, endDate: "2026-10-31T12:00:00.000Z", now: now, timeZone: utc),
            "This month · ends Oct 31 · 14 days left"
        )
        XCTAssertEqual(TaskDetailFormat.activeCaption(timeframe: .indefinite, endDate: nil, now: now), "Ongoing")
    }

    func testPastCaptionAndRange() {
        XCTAssertEqual(TaskDetailFormat.range(start: "2026-10-05T00:00:00.000Z", end: "2026-10-11T23:00:00.000Z", timeZone: utc), "Oct 5–11")
        XCTAssertEqual(TaskDetailFormat.range(start: "2026-09-28T00:00:00.000Z", end: "2026-10-04T12:00:00.000Z", timeZone: utc), "Sep 28 – Oct 4")
        XCTAssertEqual(
            TaskDetailFormat.pastCaption(isDraft: false, timeframe: .weekly, start: "2026-10-05T00:00:00.000Z", end: "2026-10-11T23:00:00.000Z", status: "expired", timeZone: utc),
            "Oct 5–11 · expired"
        )
        XCTAssertEqual(
            TaskDetailFormat.pastCaption(isDraft: true, timeframe: .custom, start: "2026-10-05T00:00:00.000Z", end: nil, status: "draft"),
            "Custom · not started"
        )
    }

    func testActivityDateAndFooter() {
        XCTAssertEqual(TaskDetailFormat.activityDate("2026-10-15T08:00:00.000Z", now: now, timeZone: utc), "Oct 15")
        XCTAssertEqual(TaskDetailFormat.activityDate("2025-09-02T08:00:00.000Z", now: now, timeZone: utc), "Sep 2, 2025")
        let updated = "2026-10-15T12:00:00.000Z"
        XCTAssertEqual(TaskDetailFormat.footer(completions: 3, updatedAt: updated, now: now), "Completed 3× all-time · updated \(RelativeTime.formatRelativeTime(updated, now: now) ?? "")")
    }

    func testInteractivePopOnlyBeginsWithSomethingToPopTo() {
        XCTAssertFalse(InteractivePopEnabler.shouldBegin(viewControllerCount: 0))
        XCTAssertFalse(InteractivePopEnabler.shouldBegin(viewControllerCount: 1), "a root screen must not swallow the gesture")
        XCTAssertTrue(InteractivePopEnabler.shouldBegin(viewControllerCount: 2))
    }

    func testMissedAndReadEndRules() {
        let normal = Task(id: "n", userId: "u", title: "n", type: .normal, action: nil, unit: nil, maxCount: nil, totalCompletions: 0, totalInstances: 0, createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z", version: 1, isDeleted: false)
        var counting = normal
        counting.type = .counting
        XCTAssertTrue(TaskDetailViewModel.canBeMissed(normal))
        XCTAssertFalse(TaskDetailViewModel.canBeMissed(counting), "no goal → nothing to miss")
        counting.maxCount = 5
        XCTAssertTrue(TaskDetailViewModel.canBeMissed(counting))
        var achievement = normal
        achievement.type = .achievement
        XCTAssertFalse(TaskDetailViewModel.canBeMissed(achievement))
    }
}
