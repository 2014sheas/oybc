import XCTest
@testable import OYBC

final class GoalEntryModelTests: XCTestCase {
    func testKeyboards() {
        XCTAssertEqual(GoalEntryModel.keyboard(for: .discrete), .numberPad)
        XCTAssertEqual(GoalEntryModel.keyboard(for: .continuous), .decimalPad)
        XCTAssertEqual(GoalEntryModel.keyboard(for: .duration), .numberPad)
    }
    func testWheelRoundTrip() {
        XCTAssertEqual(GoalEntryModel.wheelFields("10h 30m").hours, 10)
        XCTAssertEqual(GoalEntryModel.wheelFields("10h 30m").minutes, 30)
        XCTAssertEqual(GoalEntryModel.wheelFields("").hours, 0)
        XCTAssertEqual(GoalEntryModel.text(hours: 2, minutes: 40), "2h 40m")
        XCTAssertEqual(GoalEntryModel.text(hours: 0, minutes: 0), "", "0h 0m is no entry, never a 0 goal")
        XCTAssertEqual(parseCountInput(GoalEntryModel.text(hours: 1, minutes: 5), kind: .duration), 65)
    }
}
