import XCTest
@testable import OYBC

/// Cross-platform shared-counter math enforcement (workstream C1 / issue #267).
///
/// Runs the hand-authored fixture (`packages/shared/tests/fixtures/sharedCounterVectors.json`)
/// through iOS's `deriveDisplayedCount` / `propagateIncrement` in
/// `Helpers/SharedCounter.swift`. The SAME fixture is exercised on the
/// shared/web side by `packages/shared/tests/algorithms/sharedCounter.test.ts`
/// against `@oybc/shared`'s `sharedCounter.ts`. Both suites passing against
/// the same vectors is what proves the two hand-mirrored implementations
/// agree, not just an audit claim.
final class SharedCounterVectorTests: XCTestCase {

    private struct DeriveVector: Decodable {
        let name: String
        let baseline: Int
        let maxCount: Int
        let currentCount: Int
        let displayed: Int
        let isCompleted: Bool
    }

    private struct LinkedTaskVector: Decodable {
        let id: String
        let baseline: Int?
        let maxCount: Int?
        let isCompleted: Bool
    }

    private struct ExpectedIncrement: Decodable {
        let taskId: String
        let newCurrentCount: Int
        let newIsCompleted: Bool
        let displayed: Int
    }

    private struct PropagateVector: Decodable {
        let name: String
        let sourceAfterCurrentCount: Int
        let linkedTasks: [LinkedTaskVector]
        let expected: [ExpectedIncrement]
    }

    private struct Fixture: Decodable {
        let deriveDisplayedCount: [DeriveVector]
        let propagateIncrement: [PropagateVector]
    }

    private func loadFixture() throws -> Fixture {
        guard let url = Bundle(for: SharedCounterVectorTests.self).url(
            forResource: "sharedCounterVectors",
            withExtension: "json"
        ) else {
            XCTFail(
                "sharedCounterVectors.json not found in test bundle — check project.yml's " +
                "OYBCTests `resources` entry for Fixtures, and that xcodegen generate has been re-run."
            )
            throw XCTSkip("Fixture missing")
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    func testDeriveDisplayedCountVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.deriveDisplayedCount.isEmpty)
        for v in fixture.deriveDisplayedCount {
            let result = deriveDisplayedCount(
                derivedBaseline: v.baseline, derivedMaxCount: v.maxCount, sourceCurrentCount: v.currentCount
            )
            XCTAssertEqual(result.displayed, v.displayed, "Vector '\(v.name)' displayed mismatch")
            XCTAssertEqual(result.isCompleted, v.isCompleted, "Vector '\(v.name)' isCompleted mismatch")
        }
    }

    func testPropagateIncrementVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.propagateIncrement.isEmpty)
        for v in fixture.propagateIncrement {
            let linked = v.linkedTasks.map {
                PropagateIncrementLinkedTask(id: $0.id, baseline: $0.baseline, maxCount: $0.maxCount, isCompleted: $0.isCompleted)
            }
            let results = propagateIncrement(sourceAfterCurrentCount: v.sourceAfterCurrentCount, linkedTasks: linked)
            XCTAssertEqual(results.count, v.expected.count, "Vector '\(v.name)' result count mismatch")
            for (i, expected) in v.expected.enumerated() where i < results.count {
                XCTAssertEqual(results[i].taskId, expected.taskId, "Vector '\(v.name)' index \(i) taskId")
                XCTAssertEqual(results[i].newCurrentCount, expected.newCurrentCount, "Vector '\(v.name)' index \(i) newCurrentCount")
                XCTAssertEqual(results[i].newIsCompleted, expected.newIsCompleted, "Vector '\(v.name)' index \(i) newIsCompleted")
                XCTAssertEqual(results[i].displayed, expected.displayed, "Vector '\(v.name)' index \(i) displayed")
            }
        }
    }
}
