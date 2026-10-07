import XCTest
@testable import OYBC

/// Cross-platform pins for `CountValue.swift`, driven by the same
/// `countValueVectors.json` as `packages/shared/tests/algorithms/countValue.test.ts`.
final class CountValueVectorTests: XCTestCase {
    private struct NumVector: Decodable { let name: String; let x: Double; let expected: Double }
    private struct BoolVector: Decodable { let name: String; let x: Double; let expected: Bool }
    private struct FinalizeVector: Decodable { let name: String; let sum: Double; let kind: CountKind; let expected: Double }
    private struct FormatVector: Decodable { let name: String; let value: Double; let kind: CountKind; let locale: String; let expected: String }
    private struct InputVector: Decodable { let name: String; let value: Double; let kind: CountKind; let expected: String }
    private struct Fields: Decodable { let maxCount: Double?; let defaultLogAmount: Double? }
    private struct SwitchVector: Decodable { let name: String; let from: CountKind; let to: CountKind; let fields: Fields; let expected: Fields? }
    private struct Fixture: Decodable {
        let quantize: [NumVector]
        let isQuantized: [BoolVector]
        let finalize: [FinalizeVector]
        let format: [FormatVector]
        let formatForInput: [InputVector]
        let `switch`: [SwitchVector]
    }

    private func loadFixture() throws -> Fixture {
        guard let url = Bundle(for: CountValueVectorTests.self).url(forResource: "countValueVectors", withExtension: "json") else {
            XCTFail("countValueVectors.json missing from the test bundle — re-run gen:sync-fixtures and xcodegen generate.")
            throw XCTSkip("Fixture missing")
        }
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testQuantize() throws {
        for v in try loadFixture().quantize { XCTAssertEqual(quantizeCount(v.x), v.expected, v.name) }
    }
    func testIsQuantized() throws {
        for v in try loadFixture().isQuantized { XCTAssertEqual(isQuantizedCount(v.x), v.expected, v.name) }
    }
    func testFinalize() throws {
        for v in try loadFixture().finalize { XCTAssertEqual(finalizeWindowCount(v.sum, kind: v.kind), v.expected, v.name) }
    }
    func testFormat() throws {
        for v in try loadFixture().format {
            XCTAssertEqual(formatCount(v.value, kind: v.kind, locale: Locale(identifier: v.locale)), v.expected, v.name)
        }
    }
    func testFormatForInput() throws {
        for v in try loadFixture().formatForInput {
            XCTAssertEqual(formatCountForInput(v.value, kind: v.kind), v.expected, v.name)
        }
    }
    func testSwitch() throws {
        for v in try loadFixture().switch {
            let got = planCountKindSwitch(maxCount: v.fields.maxCount, defaultLogAmount: v.fields.defaultLogAmount, from: v.from, to: v.to)
            if let exp = v.expected {
                XCTAssertEqual(got, CountKindSwitchPatch(maxCount: exp.maxCount, defaultLogAmount: exp.defaultLogAmount), v.name)
            } else {
                XCTAssertNil(got, v.name)
            }
        }
    }
    func testKindDecodesAndDefaults() throws {
        XCTAssertEqual(resolveCountKind(nil), .discrete)
        XCTAssertEqual(try JSONDecoder().decode(CountKind.self, from: Data("\"continuous\"".utf8)), .continuous)
        XCTAssertEqual(countTargetStep(.continuous), 0.1)
        XCTAssertEqual(countTargetStep(.duration), 1)
    }
}
