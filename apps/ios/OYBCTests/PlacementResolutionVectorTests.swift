import XCTest
@testable import OYBC

/// Cross-platform placement-resolution enforcement (Board-integrity PR-2,
/// issue #359).
///
/// Runs the hand-authored fixture (`Fixtures/placementResolutionVectors.json`,
/// synced from `packages/shared/tests/fixtures/placementResolutionVectors.json`)
/// through iOS's `PlacementIntegrity` (`Services/PlacementIntegrity.swift`).
/// The SAME fixture is exercised on the shared side by
/// `packages/shared/tests/algorithms/placementResolution.test.ts` against
/// `resolvePlacements` / `computePlacementIntegrityRepair`. Both suites
/// passing against the same vectors is what proves the two hand-mirrored
/// implementations agree, not just an audit claim.
final class PlacementResolutionVectorTests: XCTestCase {

    private struct RawPlacement: Decodable {
        let id: String
        let row: Int
        let col: Int
        let taskId: String
        let version: Int
        let updatedAt: String
        let isDeleted: Bool?
    }

    private struct ResolvePlacementsVector: Decodable {
        let name: String
        let boardSize: Int
        let placements: [RawPlacement]
        let expectedSurvivorIds: [String]
    }

    private struct RepairVector: Decodable {
        let name: String
        let boardSize: Int
        let livePlacements: [RawPlacement]
        let expectedTombstoneIds: [String]
    }

    private struct Fixture: Decodable {
        let resolvePlacementsVectors: [ResolvePlacementsVector]
        let repairVectors: [RepairVector]
    }

    private func loadFixture() throws -> Fixture {
        guard let url = Bundle(for: PlacementResolutionVectorTests.self).url(
            forResource: "placementResolutionVectors",
            withExtension: "json"
        ) else {
            XCTFail(
                "placementResolutionVectors.json not found in test bundle — check project.yml's " +
                "OYBCTests `resources` entry for Fixtures, and that xcodegen generate has been re-run."
            )
            throw XCTSkip("Fixture missing")
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(Fixture.self, from: data)
    }

    /// Fills in the `BoardTask` fields the vectors omit (irrelevant to the
    /// winner rule) — twin of the TS suite's `toBoardTask`.
    private func toBoardTask(_ raw: RawPlacement) -> BoardTask {
        BoardTask(
            id: raw.id, boardId: "board-1", taskId: raw.taskId,
            row: raw.row, col: raw.col, isCenter: false,
            createdAt: raw.updatedAt, updatedAt: raw.updatedAt,
            lastSyncedAt: nil, version: raw.version,
            isDeleted: raw.isDeleted ?? false
        )
    }

    // MARK: - resolvePlacements

    func testResolvePlacementsVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.resolvePlacementsVectors.isEmpty)
        for v in fixture.resolvePlacementsVectors {
            let rows = v.placements.map(toBoardTask)
            let resolved = PlacementIntegrity.resolvePlacements(rows, boardSize: v.boardSize)
            XCTAssertEqual(
                Set(resolved.map(\.id)), Set(v.expectedSurvivorIds),
                "Vector '\(v.name)'"
            )
        }
    }

    func testResolvePlacements_isOrderIndependent() throws {
        let fixture = try loadFixture()
        guard let vector = fixture.resolvePlacementsVectors.first(where: { $0.name == "three-way-collision-single-winner" }) else {
            return XCTFail("expected vector 'three-way-collision-single-winner' in fixture")
        }
        let rows = vector.placements.map(toBoardTask)
        let forward = PlacementIntegrity.resolvePlacements(rows, boardSize: vector.boardSize)
        let reversed = PlacementIntegrity.resolvePlacements(rows.reversed(), boardSize: vector.boardSize)
        XCTAssertEqual(forward.map(\.id), reversed.map(\.id))
    }

    func testResolvePlacements_outputSortedByRowColId() {
        let rows = [
            toBoardTask(RawPlacement(id: "bt-z", row: 2, col: 0, taskId: "t1", version: 1, updatedAt: "2026-06-01T00:00:00.000Z", isDeleted: nil)),
            toBoardTask(RawPlacement(id: "bt-a", row: 0, col: 1, taskId: "t2", version: 1, updatedAt: "2026-06-01T00:00:00.000Z", isDeleted: nil)),
            toBoardTask(RawPlacement(id: "bt-m", row: 0, col: 0, taskId: "t3", version: 1, updatedAt: "2026-06-01T00:00:00.000Z", isDeleted: nil)),
        ]
        let resolved = PlacementIntegrity.resolvePlacements(rows, boardSize: 3)
        XCTAssertEqual(resolved.map(\.id), ["bt-m", "bt-a", "bt-z"])
    }

    // MARK: - computeRepair

    func testRepairVectors() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.repairVectors.isEmpty)
        for v in fixture.repairVectors {
            let rows = v.livePlacements.map(toBoardTask)
            let result = PlacementIntegrity.computeRepair(rows, boardSize: v.boardSize)
            XCTAssertEqual(
                Set(result.toTombstone.map(\.id)), Set(v.expectedTombstoneIds),
                "Vector '\(v.name)'"
            )
        }
    }

    func testRepairVectors_areIdempotent() throws {
        let fixture = try loadFixture()
        for v in fixture.repairVectors {
            let rows = v.livePlacements.map(toBoardTask)
            let first = PlacementIntegrity.computeRepair(rows, boardSize: v.boardSize)
            let tombstonedIds = Set(first.toTombstone.map(\.id))
            let survivors = rows.filter { !tombstonedIds.contains($0.id) }
            let second = PlacementIntegrity.computeRepair(survivors, boardSize: v.boardSize)
            XCTAssertTrue(second.toTombstone.isEmpty, "Vector '\(v.name)' should be a zero-write no-op the second time")
        }
    }

    func testRepairVectors_isOrderIndependent() throws {
        let fixture = try loadFixture()
        guard let vector = fixture.repairVectors.first(where: { $0.name == "combined-cell-collision-then-task-duplicate-cascades-to-one-survivor" }) else {
            return XCTFail("expected vector 'combined-cell-collision-then-task-duplicate-cascades-to-one-survivor' in fixture")
        }
        let rows = vector.livePlacements.map(toBoardTask)
        let forward = PlacementIntegrity.computeRepair(rows, boardSize: vector.boardSize)
        let reversed = PlacementIntegrity.computeRepair(rows.reversed(), boardSize: vector.boardSize)
        XCTAssertEqual(Set(forward.toTombstone.map(\.id)), Set(reversed.toTombstone.map(\.id)))
    }
}
