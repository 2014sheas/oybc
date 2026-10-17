import XCTest
@testable import OYBC

/// The square sheet's pure copy rules (docs/TASK_DETAIL_REDESIGN.md §Square sheet).
/// Web twin: `squareSheetModel.test.ts` — keep the strings identical.
final class SquareSheetFormatTests: XCTestCase {

    func testCountLineNamesGoalUnitAndBoard() {
        XCTAssertEqual(SquareSheetFormat.countLine(goal: 20, unit: "pages", kind: .discrete, board: "Week 42"), "/ 20 pages · Week 42")
        XCTAssertEqual(SquareSheetFormat.countLine(goal: 26.2, unit: "mi", kind: .continuous, board: "Week 42"), "/ 26.2 mi · Week 42")
        XCTAssertEqual(SquareSheetFormat.countLine(goal: 630, unit: "guitar", kind: .duration, board: "Week 42"), "/ 10h 30m · Week 42", "duration drops the unit noun")
        XCTAssertEqual(SquareSheetFormat.countLine(goal: 3, unit: "", kind: .discrete, board: "Today"), "/ 3 · Today")
    }

    func testRestLineIsOmittedOnceTheGoalIsMet() {
        XCTAssertEqual(SquareSheetFormat.restLine(current: 12, goal: 20, kind: .discrete, board: "Week 42"), "8 to go · Week 42")
        XCTAssertEqual(SquareSheetFormat.restLine(current: 270, goal: 630, kind: .duration, board: "Week 42"), "6h to go · Week 42")
        XCTAssertNil(SquareSheetFormat.restLine(current: 20, goal: 20, kind: .discrete, board: "Week 42"))
        XCTAssertNil(SquareSheetFormat.restLine(current: 25, goal: 20, kind: .discrete, board: "Week 42"), "overshoot is a feature")
        XCTAssertNil(SquareSheetFormat.restLine(current: 0, goal: 0, kind: .discrete, board: "Week 42"))
    }

    func testHeroCountShrinksForDuration() {
        XCTAssertEqual(SquareSheetFormat.heroCountSize(.discrete), 52)
        XCTAssertEqual(SquareSheetFormat.heroCountSize(.continuous), 52)
        XCTAssertEqual(SquareSheetFormat.heroCountSize(.duration), 40)
    }

    func testStatusPills() {
        XCTAssertNil(SquareSheetFormat.countStatus(current: 0, goal: 20))
        XCTAssertEqual(SquareSheetFormat.countStatus(current: 12, goal: 20), .inProgress)
        XCTAssertEqual(SquareSheetFormat.countStatus(current: 20, goal: 20), .done)
        XCTAssertEqual(SquareSheetFormat.countStatus(current: 30, goal: 20), .done)
        XCTAssertNil(SquareSheetFormat.compoundStatus(doneCount: 0, isComplete: false))
        XCTAssertEqual(SquareSheetFormat.compoundStatus(doneCount: 2, isComplete: false), .inProgress)
        XCTAssertEqual(SquareSheetFormat.compoundStatus(doneCount: 3, isComplete: true), .done)
        // An OR / M-of-N compound can be complete with fewer children done.
        XCTAssertEqual(SquareSheetFormat.compoundStatus(doneCount: 1, isComplete: true), .done)
    }

    func testSubtaskLineAndLogText() {
        XCTAssertEqual(SquareSheetFormat.subtaskLine(total: 3, board: "Today"), "of 3 sub-tasks · Today")
        XCTAssertEqual(SquareSheetFormat.subtaskLine(total: 1, board: "Today"), "of 1 sub-task · Today")
        XCTAssertEqual(SquareSheetFormat.logText(amount: 5, kind: .discrete, unit: "pages", board: "Week 42", removed: false), "Logged +5 pages · Week 42")
        XCTAssertEqual(SquareSheetFormat.logText(amount: 5, kind: .discrete, unit: "pages", board: "Week 42", removed: true), "Removed 5 pages · Week 42")
        XCTAssertEqual(SquareSheetFormat.logText(amount: 30, kind: .duration, unit: "guitar", board: "Week 42", removed: false), "Logged +30m · Week 42")
    }

    func testClosedTextUsesTheSealDay() {
        let utc = TimeZone(identifier: "UTC")!
        XCTAssertEqual(SquareSheetFormat.closedText(sealedAt: "2026-10-11T12:00:00.000Z", timeZone: utc), "Closed Oct 11")
        XCTAssertEqual(SquareSheetFormat.closedText(sealedAt: nil), "Closed")
        XCTAssertEqual(SquareSheetFormat.closedText(sealedAt: "garbage"), "Closed")
    }

    func testDaysLeft() {
        let now = parseISO8601Date("2026-10-17T12:00:00.000Z")!
        XCTAssertEqual(SquareSheetFormat.daysLeftText(endDate: "2026-10-31T12:00:00.000Z", now: now), "14 days left")
        XCTAssertEqual(SquareSheetFormat.daysLeftText(endDate: "2026-10-18T06:00:00.000Z", now: now), "Last day")
        XCTAssertEqual(SquareSheetFormat.daysLeftText(endDate: "2026-10-19T00:00:00.000Z", now: now), "2 days left")
        XCTAssertNil(SquareSheetFormat.daysLeftText(endDate: "2026-10-01T00:00:00.000Z", now: now), "past")
        XCTAssertNil(SquareSheetFormat.daysLeftText(endDate: nil, now: now))
    }

    func testChildBoxLabels() {
        let toggle = SquareSheetContent.Child(id: "a", title: "Drink water", kind: .normal, isDone: false)
        let done = SquareSheetContent.Child(id: "a", title: "Drink water", kind: .normal, isDone: true)
        let count = SquareSheetContent.ChildCount(current: 1, goal: 3, unit: "", kind: .discrete, chips: [])
        let counting = SquareSheetContent.Child(id: "c", title: "Read", kind: .counting, isDone: false, counting: count)
        XCTAssertEqual(SquareSheetFormat.childBoxLabel(toggle, isOpen: false), "Complete Drink water")
        XCTAssertEqual(SquareSheetFormat.childBoxLabel(done, isOpen: false), "Undo Drink water")
        XCTAssertEqual(SquareSheetFormat.childBoxLabel(counting, isOpen: false), "Log on Read")
        XCTAssertEqual(SquareSheetFormat.childBoxLabel(counting, isOpen: true), "Hide Read")
        XCTAssertEqual(count.meta, "1 / 3")
    }

    func testTapLogChipRowWeights() {
        let chips = CounterLogAmount.tapChips(kind: .discrete, goal: 20, windowedCount: 12) // +1 +10 +25 +8 ✓ Other…
        XCTAssertEqual(chips.map(\.label), ["+1", "+10", "+25", "+8 ✓", "Other…"])
        XCTAssertEqual(chips.map(TapLogChipRow.weight), [1, 1, 1, 1.3, 1.1])
        XCTAssertEqual(TapLogChipRow.fontSize(chips[3], size: .regular), 13, "a 4+ character rest label shrinks")
        XCTAssertEqual(TapLogChipRow.fontSize(chips[0], size: .regular), 15)
        XCTAssertEqual(TapLogChipRow.fontSize(chips[0], size: .compact), 13)
        XCTAssertEqual(TapLogChipRow.Size.regular.height, 44)
        XCTAssertEqual(TapLogChipRow.Size.compact.height, 34)
    }

    // MARK: - Strip invalidation

    func testStripSurvivesOnlyAWriteThatStarted() {
        let strip = SquareLogStrip(boardTaskId: "bt1", scopeTaskId: "t1", text: "Logged +5 pages · Week 42", undo: .counterLog(sourceTaskId: "t1"))
        XCTAssertEqual(SquareLogStrip.afterWrite(started: true, strip), strip)
        XCTAssertNil(SquareLogStrip.afterWrite(started: false, strip), "a dropped write must not leave a stale Undo")
    }

    func testStripRendersOnlyForItsSquareAndScope() {
        let strip = SquareLogStrip(boardTaskId: "bt1", scopeTaskId: "c", text: "x", undo: .restoreToggle(taskId: "c", wasDone: false))
        XCTAssertTrue(strip.isVisible(boardTaskId: "bt1", scopeTaskId: "c"))
        XCTAssertFalse(strip.isVisible(boardTaskId: "bt2", scopeTaskId: "c"), "switching square hides it")
        XCTAssertFalse(strip.isVisible(boardTaskId: "bt1", scopeTaskId: "other"))
    }

    func testToggleText() {
        XCTAssertEqual(SquareSheetFormat.toggleText(title: "Drink water", nowDone: true), "Drink water · done")
        XCTAssertEqual(SquareSheetFormat.toggleText(title: "Drink water", nowDone: false), "Drink water · not done")
    }
}
