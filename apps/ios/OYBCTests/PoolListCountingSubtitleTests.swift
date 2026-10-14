import XCTest
@testable import OYBC

final class PoolListCountingSubtitleTests: XCTestCase {
    private func task(kind: CountKind?, max: CountValue, unit: String) -> OYBC.Task {
        var t = LinkedWindowKit.task("t", maxCount: max)
        t.unit = unit
        t.countKind = kind
        return t
    }

    func testShowsTheGoalAloneWithNoActionOrUnit() {
        XCTAssertEqual(RisoPoolListView.countingSubtitle(task(kind: nil, max: 5, unit: "mi")), "goal 5")
        XCTAssertEqual(RisoPoolListView.countingSubtitle(task(kind: .continuous, max: 26.2, unit: "mi")), "goal 26.2")
    }

    func testDurationShowsHoursAndMinutesWithNoUnit() {
        XCTAssertEqual(RisoPoolListView.countingSubtitle(task(kind: .duration, max: 90, unit: "")), "goal 1h 30m")
    }
}
