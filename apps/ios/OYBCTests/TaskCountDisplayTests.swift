import XCTest
@testable import OYBC

final class TaskCountDisplayTests: XCTestCase {
    func testCountingSubtitlePerKind() {
        var run = LinkedWindowKit.task("r", maxCount: 26.2, currentCount: 12.4)
        run.countKind = .continuous
        run.unit = "mi"
        XCTAssertEqual(TaskCountDisplay.countingSubtitle(for: run), "Run · 12.4 / 26.2 mi")
        var practice = LinkedWindowKit.task("p", maxCount: 630, currentCount: 270)
        practice.countKind = .duration
        practice.action = "Practice"
        practice.unit = ""
        XCTAssertEqual(TaskCountDisplay.countingSubtitle(for: practice), "Practice · 4h 30m / 10h 30m")
        let discrete = LinkedWindowKit.task("d", maxCount: 10, currentCount: 6)
        XCTAssertEqual(TaskCountDisplay.countingSubtitle(for: discrete), "Run · 6 / 10 miles")
    }

    func testGoalSubtitlePerKind() {
        var run = LinkedWindowKit.task("r", maxCount: 26.2)
        run.countKind = .continuous
        XCTAssertEqual(TaskCountDisplay.goalSubtitle(for: run), "Run · goal 26.2 miles")
        var practice = LinkedWindowKit.task("p", maxCount: 630)
        practice.countKind = .duration
        practice.action = "Practice"
        practice.unit = nil
        XCTAssertEqual(TaskCountDisplay.goalSubtitle(for: practice), "Practice · goal 10h 30m")
        var noUnit = LinkedWindowKit.task("n", maxCount: 5)
        noUnit.unit = ""
        XCTAssertNil(TaskCountDisplay.goalSubtitle(for: noUnit))
    }
}
