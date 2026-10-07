import XCTest
@testable import OYBC

/// Cross-platform pins for `CountEntry.swift`, driven by the same
/// `countEntryVectors.json` as `packages/shared/tests/algorithms/countEntry.test.ts`.
final class CountEntryVectorTests: XCTestCase {
    private struct ParseVector: Decodable { let name: String; let raw: String; let kind: CountKind; let allowZero: Bool?; let expected: Double? }
    private struct Fields: Decodable, Equatable { let hours: String; let minutes: String }
    private struct ToFieldsVector: Decodable { let name: String; let minutes: Double?; let expected: Fields }
    private struct FromFieldsVector: Decodable { let name: String; let hours: String; let minutes: String; let expected: String }
    private struct SuffixVector: Decodable { let name: String; let kind: CountKind; let unit: String; let expected: String }
    private struct LockVector: Decodable { let name: String; let mode: KindPickerMode; let kind: CountKind; let expected: KindPickerLock }
    private struct SegmentVector: Decodable { let name: String; let lock: KindPickerLock; let segment: CountKind; let selected: CountKind; let locked: Bool; let glyph: Bool }
    private struct Fixture: Decodable {
        let parse: [ParseVector]
        let durationToFields: [ToFieldsVector]
        let durationFromFields: [FromFieldsVector]
        let unitSuffix: [SuffixVector]
        let pickerLock: [LockVector]
        let segmentState: [SegmentVector]
    }

    private func loadFixture() throws -> Fixture {
        guard let url = Bundle(for: CountEntryVectorTests.self).url(forResource: "countEntryVectors", withExtension: "json") else {
            XCTFail("countEntryVectors.json missing from the test bundle — re-run gen:sync-fixtures and xcodegen generate.")
            throw XCTSkip("Fixture missing")
        }
        return try JSONDecoder().decode(Fixture.self, from: Data(contentsOf: url))
    }

    func testParse() throws {
        for v in try loadFixture().parse {
            XCTAssertEqual(parseCountInput(v.raw, kind: v.kind, allowZero: v.allowZero ?? false), v.expected, v.name)
        }
    }
    func testDurationToFields() throws {
        for v in try loadFixture().durationToFields {
            let f = durationToFields(v.minutes)
            XCTAssertEqual(Fields(hours: f.hours, minutes: f.minutes), v.expected, v.name)
        }
    }
    func testDurationFromFields() throws {
        for v in try loadFixture().durationFromFields {
            XCTAssertEqual(durationFromFields(hours: v.hours, minutes: v.minutes), v.expected, v.name)
        }
    }
    func testUnitSuffix() throws {
        for v in try loadFixture().unitSuffix { XCTAssertEqual(countUnitSuffix(v.kind, unit: v.unit), v.expected, v.name) }
    }
    func testPickerLock() throws {
        for v in try loadFixture().pickerLock { XCTAssertEqual(kindPickerLock(mode: v.mode, kind: v.kind), v.expected, v.name) }
    }
    func testSegmentState() throws {
        for v in try loadFixture().segmentState {
            XCTAssertEqual(isKindSegmentLocked(v.lock, segment: v.segment), v.locked, v.name)
            XCTAssertEqual(kindSegmentShowsLock(v.lock, segment: v.segment, selected: v.selected), v.glyph, v.name)
        }
    }
    func testLabels() {
        XCTAssertEqual(CountKind.allCases.map(\.label), ["Discrete", "Continuous", "Duration"])
    }
    func testFamilyKind() {
        var root = LinkedWindowKit.task("root", maxCount: 26.2)
        root.countKind = .continuous
        let linked = LinkedWindowKit.task("row", maxCount: 6.2, sharedCounterId: "root", baseline: 0)
        XCTAssertEqual(resolveFamilyCountKind(linked, lookup: { $0 == "root" ? root : nil }), .continuous)
        XCTAssertEqual(resolveFamilyCountKind(linked, lookup: { _ in nil }), .discrete)
    }
}
