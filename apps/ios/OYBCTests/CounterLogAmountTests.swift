import XCTest
@testable import OYBC

/// `CounterLogAmount` — the amount-chip helpers shared by the Counter Detail
/// Log card and the board-play square sheet. Swift twin of
/// web's `amountChips.test.ts`; keep the two pinned to the same numbers.
final class CounterLogAmountTests: XCTestCase {

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
    private struct QuickV: Decodable { let name: String; let kind: CountKind; let goal: Double; let `default`: Double?; let expected: Double }
    private struct PillV: Decodable { let name: String; let kind: CountKind; let `default`: Double?; let label: String; let opensDetail: Bool }
    private struct ToastV: Decodable { let name: String; let amount: Double; let unit: String; let verb: String; let kind: CountKind; let counterName: String?; let boardNames: [String]?; let expected: String }
    private struct TapV: Decodable { let name: String; let kind: CountKind; let goal: Double?; let count: Double; let expected: [String]; let values: [Double?]?; let roles: [String]? }
    private struct LogFixture: Decodable {
        let goalChips: [ChipsV]; let hubChipLabels: [LabelsV]; let lateLogChips: [ChipsV]
        let quickAmount: [QuickV]; let pill: [PillV]; let toast: [ToastV]
        let tapChips: [TapV]
    }

    func testLogAmountVectors() throws {
        let url = try XCTUnwrap(Bundle(for: Self.self).url(forResource: "logAmountVectors", withExtension: "json"))
        let f = try JSONDecoder().decode(LogFixture.self, from: Data(contentsOf: url))
        for v in f.goalChips { XCTAssertEqual(CounterLogAmount.goalChipAmounts(goal: v.goal ?? 0, kind: v.kind), v.expected, v.name) }
        for v in f.hubChipLabels { XCTAssertEqual(CounterLogAmount.hubChips(kind: v.kind).map(\.label), v.expected, v.name) }
        for v in f.lateLogChips { XCTAssertEqual(CounterLogAmount.lateLogChipAmounts(kind: v.kind, goal: v.goal ?? 0), v.expected, v.name) }
        for v in f.quickAmount {
            XCTAssertEqual(CounterLogAmount.quickAmount(kind: v.kind, chips: CounterLogAmount.hubChips(kind: v.kind), defaultLogAmount: v.default), v.expected, v.name)
        }
        for v in f.pill {
            XCTAssertEqual(CounterLogAmount.pillLabel(kind: v.kind, defaultLogAmount: v.default), v.label, v.name)
            XCTAssertEqual(CounterLogAmount.pillOpensDetail(kind: v.kind, defaultLogAmount: v.default), v.opensDetail, v.name)
        }
        for v in f.toast {
            if v.boardNames != nil {
                XCTAssertEqual(BoardPlayViewModel.sharedCreditToastText(
                    counterName: v.counterName ?? "", amount: v.amount, kind: v.kind, isIncrement: v.verb == "logged"
                ), v.expected, v.name)
            } else {
                XCTAssertEqual(CounterLogToastView.text(amount: v.amount, unit: v.unit, verb: v.verb == "logged" ? .logged : .removed, kind: v.kind), v.expected, v.name)
            }
        }
        for v in f.tapChips {
            let chips = CounterLogAmount.tapChips(kind: v.kind, goal: v.goal, windowedCount: v.count)
            XCTAssertEqual(chips.map(\.label), v.expected, v.name)
            if let values = v.values { XCTAssertEqual(chips.map(\.value), values, v.name) }
            if let roles = v.roles { XCTAssertEqual(chips.map(\.role.rawValue), roles, v.name) }
        }
    }
}
