import XCTest
@testable import OYBC

/// Cross-platform LWW conflict-resolution enforcement (workstream C4 /
/// issue #261).
///
/// Runs the hand-authored vector fixture
/// (`packages/shared/tests/fixtures/lwwVectors.json`) through iOS's
/// `resolveConflict(local:remote:)` in `SyncService.swift`. The SAME
/// fixture is exercised on the shared/web side by
/// `packages/shared/tests/algorithms/lwwResolve.test.ts` against
/// `@oybc/shared`'s `resolveConflict` (which `packages/shared/src/algorithms/lwwResolve.ts`
/// now owns — web's `conflictResolver.ts` re-exports it). Both suites
/// passing against the same vectors is what proves the two hand-mirrored
/// implementations agree, not just an audit claim.
final class LwwVectorTests: XCTestCase {

    private struct LwwVector: Decodable {
        let name: String
        let localVersion: Int
        let localUpdatedAt: String
        let remoteVersion: Int
        let remoteUpdatedAt: String
        let winner: String
    }

    private struct LwwFixture: Decodable {
        let vectors: [LwwVector]
    }

    private func loadFixture() throws -> LwwFixture {
        guard let url = Bundle(for: LwwVectorTests.self).url(
            forResource: "lwwVectors",
            withExtension: "json"
        ) else {
            XCTFail(
                "lwwVectors.json not found in test bundle — check project.yml's " +
                "OYBCTests `resources` entry for packages/shared/tests/fixtures, " +
                "and that xcodegen generate has been re-run."
            )
            throw XCTSkip("Fixture missing")
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(LwwFixture.self, from: data)
    }

    func testFixtureIsNonEmpty() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.vectors.isEmpty)
    }

    func testAllVectorsMatchExpectedWinner() throws {
        let fixture = try loadFixture()
        for vector in fixture.vectors {
            let local: [String: Any] = [
                "version": vector.localVersion,
                "updatedAt": vector.localUpdatedAt,
            ]
            let remote: [String: Any] = [
                "version": vector.remoteVersion,
                "updatedAt": vector.remoteUpdatedAt,
            ]
            let winner = resolveConflict(local: local, remote: remote)
            XCTAssertEqual(
                winner,
                vector.winner,
                "Vector '\(vector.name)' expected winner '\(vector.winner)' but got '\(winner)'."
            )
        }
    }
}
