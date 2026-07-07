import XCTest
@testable import OYBC

/// Cross-platform additive-merge enforcement (workstream C1 / issue #267).
///
/// Runs the hand-authored fixture (`packages/shared/tests/fixtures/sharedCounterMergeVectors.json`)
/// through iOS's `additiveMergeCount` / `needsAdditiveMerge` in
/// `Helpers/SharedCounterMerge.swift`. The SAME fixture is exercised on the
/// shared/web side by `packages/shared/tests/algorithms/sharedCounterMerge.test.ts`
/// against `@oybc/shared`'s `sharedCounterMerge.ts`. Both suites passing
/// against the same vectors is what proves the two hand-mirrored
/// implementations agree, not just an audit claim.
final class SharedCounterMergeVectorTests: XCTestCase {

    private struct MergeVector: Decodable {
        let name: String
        let localCount: Int
        let remoteCount: Int
        let lastSyncedCount: Int?
        let merged: Int
        let mergeApplied: Bool
    }

    private struct NeedsMergeVector: Decodable {
        let name: String
        let localCount: Int
        let remoteCount: Int
        let lastSyncedCount: Int?
        let expected: Bool
    }

    private struct Fixture: Decodable {
        let additiveMergeCount: [MergeVector]
        let needsAdditiveMerge: [NeedsMergeVector]
    }

    private func loadFixture() throws -> Fixture {
        guard let url = Bundle(for: SharedCounterMergeVectorTests.self).url(
            forResource: "sharedCounterMergeVectors",
            withExtension: "json"
        ) else {
            XCTFail(
                "sharedCounterMergeVectors.json not found in test bundle — check project.yml's " +
                "OYBCTests `resources` entry for Fixtures, and that xcodegen generate has been re-run."
            )
            throw XCTSkip("Fixture missing")
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    func testAdditiveMergeCountVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.additiveMergeCount.isEmpty)
        for v in fixture.additiveMergeCount {
            let result = additiveMergeCount(localCount: v.localCount, remoteCount: v.remoteCount, lastSyncedCount: v.lastSyncedCount)
            XCTAssertEqual(result.merged, v.merged, "Vector '\(v.name)' merged mismatch")
            XCTAssertEqual(result.mergeApplied, v.mergeApplied, "Vector '\(v.name)' mergeApplied mismatch")
        }
    }

    func testNeedsAdditiveMergeVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.needsAdditiveMerge.isEmpty)
        for v in fixture.needsAdditiveMerge {
            let result = needsAdditiveMerge(localCount: v.localCount, remoteCount: v.remoteCount, lastSyncedCount: v.lastSyncedCount)
            XCTAssertEqual(result, v.expected, "Vector '\(v.name)' mismatch")
        }
    }
}
