import XCTest
@testable import OYBC

/// `CounterLogAmount` — the amount-chip helpers shared by the Counter Detail
/// Log card and the board-play `RisoCountingStepperSheet`. Swift twin of
/// web's `amountChips.test.ts`; keep the two pinned to the same numbers.
final class CounterLogAmountTests: XCTestCase {

    // MARK: - initialChip(_:)

    func testInitialChipReturnsRememberedDefaultWhenItIsAPreset() {
        XCTAssertEqual(CounterLogAmount.initialChip(1), 1)
        XCTAssertEqual(CounterLogAmount.initialChip(10), 10)
        XCTAssertEqual(CounterLogAmount.initialChip(25), 25)
    }

    /// A fresh counter (no remembered default) must open on +1, matching the
    /// one-tap paths (`defaultLogAmount ?? 1`) — not +10.
    func testInitialChipFallsBackToOneForMissingOrOffPresetDefault() {
        XCTAssertEqual(CounterLogAmount.initialChip(nil), 1)
        XCTAssertEqual(CounterLogAmount.initialChip(7), 1)
    }

    // MARK: - parseCustom(_:)

    func testParseCustomAcceptsPositiveIntegers() {
        XCTAssertEqual(CounterLogAmount.parseCustom("1"), 1)
        XCTAssertEqual(CounterLogAmount.parseCustom("  42  "), 42, "whitespace trimmed")
    }

    func testParseCustomRejectsNonPositiveOrNonNumeric() {
        XCTAssertNil(CounterLogAmount.parseCustom(""))
        XCTAssertNil(CounterLogAmount.parseCustom("0"))
        XCTAssertNil(CounterLogAmount.parseCustom("-3"))
        XCTAssertNil(CounterLogAmount.parseCustom("+3"))
        XCTAssertNil(CounterLogAmount.parseCustom("2.5"))
        XCTAssertNil(CounterLogAmount.parseCustom("abc"))
    }
}
