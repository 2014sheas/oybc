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
        let rel = RelativeTime.formatRelativeTime(updated, now: now) ?? ""
        XCTAssertEqual(TaskDetailFormat.footer(type: .normal, completions: 3, updatedAt: updated, now: now), "Completed 3× all-time · updated \(rel)")
        // Only a Simple task's completions are recorded occurrences (#384).
        for type in [TaskType.counting, .compound, .achievement] {
            XCTAssertEqual(TaskDetailFormat.footer(type: type, completions: 0, updatedAt: updated, now: now), "Updated \(rel)")
            XCTAssertEqual(TaskDetailFormat.footer(type: type, completions: 4, updatedAt: "not a date", now: now), "")
        }
    }

    func testInteractivePopOnlyBeginsWithSomethingToPopTo() {
        XCTAssertFalse(InteractivePopEnabler.shouldBegin(viewControllerCount: 0))
        XCTAssertFalse(InteractivePopEnabler.shouldBegin(viewControllerCount: 1), "a root screen must not swallow the gesture")
        XCTAssertTrue(InteractivePopEnabler.shouldBegin(viewControllerCount: 2))
    }

    func testMissedRules_readTheBoardsRow() {
        let normal = Task(id: "n", userId: "u", title: "n", type: .normal, action: nil, unit: nil, maxCount: nil, totalCompletions: 0, totalInstances: 0, createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z", version: 1, isDeleted: false)
        func row(goal: CountValue? = nil, total: Int? = nil) -> TaskPlacementRows.Row {
            .init(boardId: "b", boardTaskId: "bt", memberTaskId: "n", viaCompoundId: nil, done: false,
                  count: goal == nil ? nil : 0, goal: goal, childrenDone: total == nil ? nil : 0, childrenTotal: total)
        }
        var counting = normal
        counting.type = .counting
        var compound = normal
        compound.type = .compound
        var achievement = normal
        achievement.type = .achievement
        XCTAssertTrue(TaskDetailViewModel.canBeMissed(normal, row: row()))
        XCTAssertFalse(TaskDetailViewModel.canBeMissed(counting, row: row(goal: 0)), "no goal on that board → nothing to miss")
        XCTAssertTrue(TaskDetailViewModel.canBeMissed(counting, row: row(goal: 5)))
        XCTAssertFalse(TaskDetailViewModel.canBeMissed(compound, row: row(total: 0)))
        XCTAssertTrue(TaskDetailViewModel.canBeMissed(compound, row: row(total: 2)))
        XCTAssertFalse(TaskDetailViewModel.canBeMissed(achievement, row: row()))
    }

    func testRowValue_formatsTheKernelRow() {
        let t = Task(id: "c", userId: "u", title: "c", type: .counting, action: nil, unit: nil, maxCount: 20, totalCompletions: 0, totalInstances: 0, createdAt: "2026-01-01T00:00:00.000Z", updatedAt: "2026-01-01T00:00:00.000Z", version: 1, isDeleted: false)
        let counting = TaskPlacementRows.Row(boardId: "b", boardTaskId: "bt", memberTaskId: "c", viaCompoundId: "P", done: false, count: 12, goal: 20, childrenDone: nil, childrenTotal: nil)
        XCTAssertEqual(TaskDetailViewModel.rowValue(counting, member: t, taskById: ["c": t]), .init(value: "12", sub: "/20", done: false, fraction: 0.6))
        let compound = TaskPlacementRows.Row(boardId: "b", boardTaskId: "bt", memberTaskId: "c", viaCompoundId: nil, done: false, count: nil, goal: nil, childrenDone: 1, childrenTotal: 4)
        XCTAssertEqual(TaskDetailViewModel.rowValue(compound, member: t, taskById: [:]), .init(value: "1", sub: "/4", done: false, fraction: 0.25))
        let normal = TaskPlacementRows.Row(boardId: "b", boardTaskId: "bt", memberTaskId: "c", viaCompoundId: nil, done: true, count: nil, goal: nil, childrenDone: nil, childrenTotal: nil)
        XCTAssertEqual(TaskDetailViewModel.rowValue(normal, member: t, taskById: [:]), .init(value: "Done", sub: nil, done: true, fraction: 1))
    }
}
