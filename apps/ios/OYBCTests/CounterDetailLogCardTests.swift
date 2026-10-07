import XCTest
@testable import OYBC

final class CounterDetailLogCardTests: XCTestCase {
    func testContinuousCustomDefault() {
        let m = CounterDetailLogCard.Model(kind: .continuous, unit: "mi", defaultLogAmount: 3.1)
        XCTAssertEqual(m.chips.map(\.label), ["0.5", "1", "5", "#"])
        XCTAssertTrue(m.isCustom)
        XCTAssertEqual(m.selectedChipIndex, 3)
        XCTAssertEqual(m.chipLabel(at: 3), "#3.1")
        XCTAssertEqual(m.addLabel, "＋ Add 3.1 mi")
    }
    func testDurationPresetDefault() {
        let m = CounterDetailLogCard.Model(kind: .duration, unit: "guitar", defaultLogAmount: 30)
        XCTAssertEqual(m.chips.map(\.label), ["15m", "30m", "1h", "#"])
        XCTAssertEqual(m.selectedChipIndex, 1)
        XCTAssertEqual(m.addLabel, "＋ Add 30m")
        XCTAssertEqual(m.removeA11y, "Remove 30m")
    }
    func testConfirmCustomParsesAtTheKind() {
        var m = CounterDetailLogCard.Model(kind: .continuous, unit: "mi", defaultLogAmount: nil)
        XCTAssertFalse(m.confirmCustom("3.125"))
        XCTAssertTrue(m.confirmCustom("4,9"))
        XCTAssertEqual(m.selectedAmount, 4.9)
        XCTAssertTrue(m.isCustom)
    }
    func testDiscreteUnchanged() {
        let m = CounterDetailLogCard.Model(kind: .discrete, unit: "pages", defaultLogAmount: 10)
        XCTAssertEqual(m.chips.map(\.label), ["1", "10", "25", "#"])
        XCTAssertEqual(m.selectedChipIndex, 1)
        XCTAssertEqual(m.addLabel, "＋ Add 10")
    }
    func testSelectingAPresetClearsCustom() {
        var m = CounterDetailLogCard.Model(kind: .continuous, unit: "mi", defaultLogAmount: 3.1)
        m.select(5)
        XCTAssertFalse(m.isCustom)
        XCTAssertEqual(m.selectedChipIndex, 2)
    }
    func testMemberValueLabelIsKindAwareAndGrouped() {
        XCTAssertEqual(SharedCounterMemberRow.loggedLabel(logged: 512, goal: 1000, kind: .discrete), "512/\(formatCountTotal(1000, kind: .discrete))")
        XCTAssertEqual(SharedCounterMemberRow.loggedLabel(logged: 12.4, goal: 26.2, kind: .continuous), "12.4/26.2")
        XCTAssertEqual(SharedCounterMemberRow.loggedLabel(logged: 270, goal: 630, kind: .duration), "4h 30m/10h 30m")
    }
}
