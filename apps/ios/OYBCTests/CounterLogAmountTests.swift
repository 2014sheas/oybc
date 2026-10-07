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

    private struct ChipsV: Decodable { let name: String; let goal: Double?; let kind: CountKind; let expected: [Double] }
    private struct LabelsV: Decodable { let name: String; let goal: Double?; let kind: CountKind; let expected: [String] }
    private struct Sel: Decodable, Equatable { let amount: Double; let isCustom: Bool }
    private struct SelV: Decodable { let name: String; let kind: CountKind; let goal: Double; let `default`: Double?; let expected: Sel }
    private struct QuickV: Decodable { let name: String; let kind: CountKind; let goal: Double; let `default`: Double?; let expected: Double }
    private struct PillV: Decodable { let name: String; let kind: CountKind; let `default`: Double?; let label: String; let opensDetail: Bool }
    private struct ToastV: Decodable { let name: String; let amount: Double; let unit: String; let verb: String; let kind: CountKind; let counterName: String?; let boardNames: [String]?; let expected: String }
    private struct CustomV: Decodable { let name: String; let amount: Double; let kind: CountKind; let expected: String }
    private struct LogFixture: Decodable {
        let goalChips: [ChipsV]; let boardSheetChipLabels: [LabelsV]; let hubChipLabels: [LabelsV]; let lateLogChips: [ChipsV]
        let initialSelection: [SelV]; let quickAmount: [QuickV]; let pill: [PillV]; let toast: [ToastV]
        let customChipLabel: [CustomV]
    }

    func testLogAmountVectors() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "logAmountVectors", withExtension: "json"))
        let f = try JSONDecoder().decode(LogFixture.self, from: Data(contentsOf: url))
        for v in f.goalChips { XCTAssertEqual(CounterLogAmount.goalChipAmounts(goal: v.goal ?? 0, kind: v.kind), v.expected, v.name) }
        for v in f.boardSheetChipLabels { XCTAssertEqual(CounterLogAmount.boardSheetChips(kind: v.kind, goal: v.goal ?? 0).map(\.label), v.expected, v.name) }
        for v in f.hubChipLabels { XCTAssertEqual(CounterLogAmount.hubChips(kind: v.kind).map(\.label), v.expected, v.name) }
        for v in f.lateLogChips { XCTAssertEqual(CounterLogAmount.lateLogChipAmounts(kind: v.kind, goal: v.goal ?? 0), v.expected, v.name) }
        for v in f.initialSelection {
            let s = CounterLogAmount.initialSelection(kind: v.kind, chips: CounterLogAmount.boardSheetChips(kind: v.kind, goal: v.goal), defaultLogAmount: v.default)
            XCTAssertEqual(Sel(amount: s.amount, isCustom: s.isCustom), v.expected, v.name)
        }
        for v in f.quickAmount {
            XCTAssertEqual(CounterLogAmount.quickAmount(kind: v.kind, chips: CounterLogAmount.boardSheetChips(kind: v.kind, goal: v.goal), defaultLogAmount: v.default), v.expected, v.name)
        }
        for v in f.pill {
            XCTAssertEqual(CounterLogAmount.pillLabel(kind: v.kind, defaultLogAmount: v.default), v.label, v.name)
            XCTAssertEqual(CounterLogAmount.pillOpensDetail(kind: v.kind, defaultLogAmount: v.default), v.opensDetail, v.name)
        }
        for v in f.toast {
            if let names = v.boardNames {
                let boards = names.enumerated().map { AppDatabase.AffectedBoard(boardId: "b\($0.offset)", boardName: $0.element) }
                XCTAssertEqual(BoardPlayViewModel.sharedCreditToastText(
                    counterName: v.counterName ?? "", amount: v.amount, kind: v.kind, otherBoards: boards, isIncrement: v.verb == "logged"
                ), v.expected, v.name)
            } else {
                XCTAssertEqual(CounterLogToastView.text(amount: v.amount, unit: v.unit, verb: v.verb == "logged" ? .logged : .removed, kind: v.kind), v.expected, v.name)
            }
        }
        for v in f.customChipLabel { XCTAssertEqual(CounterLogAmount.customChipLabel(v.amount, kind: v.kind), v.expected, v.name) }
    }
}
