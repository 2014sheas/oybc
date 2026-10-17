import XCTest
@testable import OYBC

final class TaskCountDisplayTests: XCTestCase {
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
        var emptyAction = LinkedWindowKit.task("e", maxCount: 5)
        emptyAction.action = ""
        XCTAssertNil(TaskCountDisplay.goalSubtitle(for: emptyAction))
    }
}
