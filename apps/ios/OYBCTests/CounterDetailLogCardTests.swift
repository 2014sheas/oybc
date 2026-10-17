import XCTest
@testable import OYBC

final class CounterDetailLogCardTests: XCTestCase {
    func testHeaderTitleDropsTheUnitNounForDuration() {
        XCTAssertEqual(CounterDetailLogCard.headerTitle(kind: .duration, unit: "guitar"), "Log")
        XCTAssertEqual(CounterDetailLogCard.headerTitle(kind: .discrete, unit: "pages"), "Log pages")
        XCTAssertEqual(CounterDetailLogCard.headerTitle(kind: .continuous, unit: nil), "Log")
    }

    /// The card's chip row is the one-gesture row with no goal: presets then "Other…", never a rest chip.
    func testChipRowIsTheFixedPresetsAndOtherWithNoRestChip() {
        XCTAssertEqual(CounterLogAmount.tapChips(kind: .discrete, goal: nil).map(\.label), ["+1", "+10", "+25", "Other…"])
        XCTAssertEqual(CounterLogAmount.tapChips(kind: .continuous, goal: nil).map(\.label), ["+0.5", "+1", "+5", "Other…"])
        XCTAssertEqual(CounterLogAmount.tapChips(kind: .duration, goal: nil).map(\.label), ["+15m", "+30m", "+1h", "Other…"])
    }

    func testMemberValueLabelIsKindAwareAndGrouped() {
        XCTAssertEqual(SharedCounterMemberRow.loggedLabel(logged: 512, goal: 1000, kind: .discrete), "512/\(formatCountTotal(1000, kind: .discrete))")
        XCTAssertEqual(SharedCounterMemberRow.loggedLabel(logged: 12.4, goal: 26.2, kind: .continuous), "12.4/26.2")
        XCTAssertEqual(SharedCounterMemberRow.loggedLabel(logged: 270, goal: 630, kind: .duration), "4h 30m/10h 30m")
    }
}
