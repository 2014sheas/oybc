import XCTest
@testable import OYBC

final class CountingStepperModelTests: XCTestCase {
    func testContinuousOpensOnTheRememberedCustomAmount() {
        let m = CountingStepperModel.initial(kind: .continuous, goal: 26.2, defaultLogAmount: 3.1, isShared: false)
        XCTAssertEqual(m.chips.map(\.label), ["6.6", "13.1", "26.2", "#"])
        XCTAssertTrue(m.isCustom)
        XCTAssertEqual(m.amountText, "3.1")
        XCTAssertEqual(m.amount, 3.1)
        XCTAssertEqual(m.addLabel(unit: "mi"), "+ 3.1 mi")
    }
    func testChipAndTypedTextSwitchCustomness() {
        var m = CountingStepperModel.initial(kind: .continuous, goal: 26.2, defaultLogAmount: nil, isShared: false)
        XCTAssertEqual(m.amount, 6.6)
        XCTAssertFalse(m.isCustom)
        m.setText("31")
        XCTAssertEqual(m.amount, 31)
        XCTAssertTrue(m.isCustom)
        m.selectChip(13.1)
        XCTAssertEqual(m.amountText, "13.1")
        XCTAssertFalse(m.isCustom)
        m.setText("3.125")
        XCTAssertNil(m.amount, "an invalid entry disables − / +")
    }
    func testDurationQuarterIsToTheMinute() {
        let m = CountingStepperModel.initial(kind: .duration, goal: 630, defaultLogAmount: nil, isShared: false)
        XCTAssertEqual(m.amount, 158)
        XCTAssertEqual(m.addLabel(unit: ""), "+ 2h 38m")
    }
    func testDiscreteStandaloneHasNoChipsAndStepsOne() {
        let m = CountingStepperModel.initial(kind: .discrete, goal: 10, defaultLogAmount: 10, isShared: false)
        XCTAssertFalse(m.showsChips)
        XCTAssertEqual(m.amount, 1)
    }
    func testDiscreteSharedKeepsPlusOnePlusTen() {
        let m = CountingStepperModel.initial(kind: .discrete, goal: 200, defaultLogAmount: 10, isShared: true)
        XCTAssertEqual(m.chips.map(\.label), ["+1", "+10", "#"])
        XCTAssertEqual(m.amount, 10)
    }
    /// Web twin `countingLogModel.test.ts` — a typed chip value selects that chip.
    func testTypingAChipValueIsNotCustom() {
        var m = CountingStepperModel.initial(kind: .continuous, goal: 26.2, defaultLogAmount: nil, isShared: false)
        m.setText("13,1")
        XCTAssertEqual(m.amount, 13.1)
        XCTAssertFalse(m.isCustom)
    }
}
