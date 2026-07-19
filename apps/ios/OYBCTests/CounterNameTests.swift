import XCTest
@testable import OYBC

/// Unit tests for `CounterName.formatCounterName`.
///
/// Parity target: `packages/shared/tests/algorithms/counterName.test.ts`.
/// Mirrors the TS case list 1:1 so a divergence between the Swift port and
/// the TypeScript source-of-truth is caught immediately.
final class CounterNameTests: XCTestCase {

    // MARK: - Derivation table

    func test_elidesDefaultDoVerb_capitalizingTheNoun() {
        XCTAssertEqual(CounterName.formatCounterName(action: "Do", unit: "push-ups"), "Push-ups")
    }

    func test_keepsNonDoVerb_capitalizingOnlyTheVerb() {
        XCTAssertEqual(CounterName.formatCounterName(action: "Run", unit: "miles"), "Run miles")
    }

    func test_keepsNonDoVerb_secondExample() {
        XCTAssertEqual(CounterName.formatCounterName(action: "Read", unit: "pages"), "Read pages")
    }

    // MARK: - "Do" elision is case-insensitive

    func test_elidesLowercaseDo() {
        XCTAssertEqual(CounterName.formatCounterName(action: "do", unit: "sit-ups"), "Sit-ups")
    }

    func test_elidesUppercaseDo() {
        XCTAssertEqual(CounterName.formatCounterName(action: "DO", unit: "sit-ups"), "Sit-ups")
    }

    func test_elidesMixedCaseDo() {
        XCTAssertEqual(CounterName.formatCounterName(action: "dO", unit: "sit-ups"), "Sit-ups")
    }

    // MARK: - Blank/nil action backfills to "Do"

    func test_treatsEmptyStringAction_asDo() {
        XCTAssertEqual(CounterName.formatCounterName(action: "", unit: "burpees"), "Burpees")
    }

    func test_treatsWhitespaceOnlyAction_asDo() {
        XCTAssertEqual(CounterName.formatCounterName(action: "   ", unit: "burpees"), "Burpees")
    }

    func test_treatsNilAction_asDo() {
        XCTAssertEqual(CounterName.formatCounterName(action: nil, unit: "burpees"), "Burpees")
    }

    // MARK: - Trimming

    func test_trimsSurroundingWhitespace_onBothActionAndUnit() {
        XCTAssertEqual(CounterName.formatCounterName(action: "  Run  ", unit: "  miles  "), "Run miles")
    }

    func test_trimsDoVerb_beforeComparingCaseInsensitively() {
        XCTAssertEqual(CounterName.formatCounterName(action: "  do  ", unit: "push-ups"), "Push-ups")
    }

    // MARK: - Empty/nil noun

    func test_fallsBackToEmpty_whenVerbIsDoAndNounIsBlank() {
        XCTAssertEqual(CounterName.formatCounterName(action: "Do", unit: ""), "")
    }

    func test_fallsBackToEmpty_whenVerbIsDoAndNounIsNil() {
        XCTAssertEqual(CounterName.formatCounterName(action: "Do", unit: nil), "")
    }

    func test_fallsBackToEmpty_whenBothActionAndUnitAreBlankOrNil() {
        XCTAssertEqual(CounterName.formatCounterName(action: nil, unit: nil), "")
        XCTAssertEqual(CounterName.formatCounterName(action: "", unit: ""), "")
    }

    func test_returnsCapitalizedVerbAlone_whenNonDoAndNounIsBlank() {
        XCTAssertEqual(CounterName.formatCounterName(action: "Run", unit: ""), "Run")
    }

    func test_returnsCapitalizedVerbAlone_whenNonDoAndNounIsNil() {
        XCTAssertEqual(CounterName.formatCounterName(action: "Run", unit: nil), "Run")
    }

    // MARK: - First-letter capitalization preserves the rest

    func test_preservesInternalCasingOfNoun_doElidedBranch() {
        XCTAssertEqual(CounterName.formatCounterName(action: "Do", unit: "push-UPs"), "Push-UPs")
    }

    func test_preservesInternalCasingOfVerb() {
        XCTAssertEqual(CounterName.formatCounterName(action: "rUN", unit: "miles"), "RUN miles")
    }

    func test_doesNotAlterNounCasing_whenVerbIsNonDo() {
        XCTAssertEqual(CounterName.formatCounterName(action: "Read", unit: "PAGES"), "Read PAGES")
    }
}
