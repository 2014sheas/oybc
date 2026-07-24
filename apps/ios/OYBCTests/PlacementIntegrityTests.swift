import XCTest
@testable import OYBC

/// Board-integrity PR-2 (issue #359, docs/BOARD_INTEGRITY.md) —
/// `PlacementIntegrity`'s deterministic winner rule, `resolvePlacements`
/// (cell-collision-only, render/derivation), and `computeRepair` (the full
/// 3-phase repair core: OOB → cell collision → same-task duplicate).
///
/// Hand-written unit coverage for behaviors the fixture-driven
/// `PlacementResolutionVectorTests.swift` doesn't isolate as cleanly (the
/// winner-rule tie-break levels individually, `resolvePlacements`
/// deliberately NOT collapsing same-task duplicates). The fixture suite is
/// the cross-platform source of truth; these are supplementary.
final class PlacementIntegrityTests: XCTestCase {

    private func bt(
        _ id: String,
        row: Int,
        col: Int,
        taskId: String,
        version: Int = 1,
        updatedAt: String = "2026-07-01T00:00:00.000Z",
        boardId: String = "b1"
    ) -> BoardTask {
        BoardTask(
            id: id, boardId: boardId, taskId: taskId, row: row, col: col,
            isCenter: false, createdAt: updatedAt, updatedAt: updatedAt,
            lastSyncedAt: nil, version: version
        )
    }

    // MARK: - Winner rule tie-breaks (isolated)

    func test_wins_higherVersionWinsRegardlessOfDate() {
        let older = bt("a", row: 0, col: 0, taskId: "t1", version: 2, updatedAt: "2026-01-01T00:00:00.000Z")
        let newer = bt("b", row: 0, col: 0, taskId: "t1", version: 1, updatedAt: "2026-06-01T00:00:00.000Z")
        XCTAssertTrue(PlacementIntegrity.wins(older, over: newer))
        XCTAssertFalse(PlacementIntegrity.wins(newer, over: older))
    }

    func test_wins_sameVersionNewerUpdatedAtWins() {
        let a = bt("a", row: 0, col: 0, taskId: "t1", version: 1, updatedAt: "2026-01-01T00:00:00.000Z")
        let b = bt("b", row: 0, col: 0, taskId: "t1", version: 1, updatedAt: "2026-06-01T00:00:00.000Z")
        XCTAssertTrue(PlacementIntegrity.wins(b, over: a))
        XCTAssertFalse(PlacementIntegrity.wins(a, over: b))
    }

    func test_wins_sameVersionSameUpdatedAtLowestIdWins() {
        let a = bt("aaa", row: 0, col: 0, taskId: "t1", version: 1, updatedAt: "2026-01-01T00:00:00.000Z")
        let b = bt("bbb", row: 0, col: 0, taskId: "t1", version: 1, updatedAt: "2026-01-01T00:00:00.000Z")
        XCTAssertTrue(PlacementIntegrity.wins(a, over: b))
        XCTAssertFalse(PlacementIntegrity.wins(b, over: a))
    }

    /// Twin of the TS unit test: an unparseable `updatedAt` on both sides
    /// degrades straight to the id tie-break, never a raw string compare.
    func test_wins_unparseableUpdatedAtDegradesToIdTieBreak() {
        let a = bt("bt-a", row: 0, col: 0, taskId: "t1", version: 1, updatedAt: "not-a-date")
        let b = bt("bt-b", row: 0, col: 0, taskId: "t2", version: 1, updatedAt: "also-not-a-date")
        XCTAssertTrue(PlacementIntegrity.wins(a, over: b), "'bt-a' < 'bt-b'")
        XCTAssertEqual(PlacementIntegrity.pickWinner([b, a]).id, "bt-a")
    }

    func test_pickWinner_singleRowGroupReturnsThatRow() {
        let only = bt("only", row: 0, col: 0, taskId: "t1")
        XCTAssertEqual(PlacementIntegrity.pickWinner([only]).id, "only")
    }

    // MARK: - resolvePlacements: same-cell collision

    func test_resolvePlacements_sameCellCollision_higherVersionSurvives() {
        let loser = bt("lose", row: 0, col: 0, taskId: "t1", version: 1)
        let winner = bt("win", row: 0, col: 0, taskId: "t2", version: 2)
        let result = PlacementIntegrity.resolvePlacements([loser, winner], boardSize: 3)

        XCTAssertEqual(result.map(\.id), ["win"])
    }

    func test_resolvePlacements_noCollision_bothSurvive() {
        let a = bt("a", row: 0, col: 0, taskId: "t1")
        let b = bt("b", row: 1, col: 1, taskId: "t2")
        let result = PlacementIntegrity.resolvePlacements([a, b], boardSize: 3)

        XCTAssertEqual(Set(result.map(\.id)), ["a", "b"])
    }

    /// Deliberate divergence from `computeRepair`: `resolvePlacements` does
    /// NOT collapse a same task placed at two DIFFERENT (non-colliding)
    /// cells — that's a repair-pass concern, not a per-cell rendering one.
    /// Both cells legitimately render/derive independently.
    func test_resolvePlacements_doesNotCollapseSameTaskAcrossDifferentCells() {
        let a = bt("a", row: 0, col: 0, taskId: "shared")
        let b = bt("b", row: 1, col: 1, taskId: "shared")
        let result = PlacementIntegrity.resolvePlacements([a, b], boardSize: 3)

        XCTAssertEqual(Set(result.map(\.id)), ["a", "b"], "resolvePlacements only resolves CELL collisions")
    }

    // MARK: - resolvePlacements: out-of-bounds has no winner

    func test_resolvePlacements_outOfBoundsRow_dropped() {
        let oob = bt("oob", row: 7, col: 0, taskId: "t1")
        let live = bt("live", row: 0, col: 0, taskId: "t2")
        let result = PlacementIntegrity.resolvePlacements([oob, live], boardSize: 5)

        XCTAssertEqual(result.map(\.id), ["live"])
    }

    func test_resolvePlacements_negativeColumn_dropped() {
        let oob = bt("oob", row: 0, col: -1, taskId: "t1")
        let result = PlacementIntegrity.resolvePlacements([oob], boardSize: 5)

        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - resolvePlacements: tombstones filtered defensively

    func test_resolvePlacements_tombstonedRowIsExcluded() {
        var deleted = bt("dead", row: 0, col: 0, taskId: "t1")
        deleted.isDeleted = true
        let result = PlacementIntegrity.resolvePlacements([deleted], boardSize: 3)

        XCTAssertTrue(result.isEmpty)
    }

    // MARK: - resolvePlacements: sorted (row, col, id) output

    func test_resolvePlacements_sortsByRowThenColThenId() {
        let a = bt("z", row: 1, col: 0, taskId: "t1")
        let b = bt("a", row: 0, col: 1, taskId: "t2")
        let c = bt("m", row: 0, col: 0, taskId: "t3")
        let result = PlacementIntegrity.resolvePlacements([a, b, c], boardSize: 3)

        XCTAssertEqual(result.map(\.id), ["m", "a", "z"])
    }

    func test_resolvePlacements_isIdempotent() {
        let rows = [
            bt("a", row: 0, col: 0, taskId: "t1"),
            bt("b", row: 0, col: 0, taskId: "t2", version: 2),
            bt("c", row: 1, col: 1, taskId: "t3"),
        ]
        let once = PlacementIntegrity.resolvePlacements(rows, boardSize: 3)
        let twice = PlacementIntegrity.resolvePlacements(once, boardSize: 3)

        XCTAssertEqual(once.map(\.id), twice.map(\.id))
    }

    func test_resolvePlacements_isOrderIndependent() {
        let rows = [
            bt("bt-1", row: 4, col: 4, taskId: "t1", version: 1),
            bt("bt-2", row: 4, col: 4, taskId: "t2", version: 5),
            bt("bt-3", row: 4, col: 4, taskId: "t3", version: 3),
        ]
        let forward = PlacementIntegrity.resolvePlacements(rows, boardSize: 5)
        let reversed = PlacementIntegrity.resolvePlacements(rows.reversed(), boardSize: 5)

        XCTAssertEqual(forward.map(\.id), reversed.map(\.id))
    }

    // MARK: - computeRepair: three-phase resolution

    func test_computeRepair_cleanBoard_zeroTombstones() {
        let rows = [
            bt("bt-a", row: 0, col: 0, taskId: "t1"),
            bt("bt-b", row: 1, col: 1, taskId: "t2"),
            bt("bt-c", row: 2, col: 2, taskId: "t3"),
        ]
        let result = PlacementIntegrity.computeRepair(rows, boardSize: 3)
        XCTAssertTrue(result.toTombstone.isEmpty)
    }

    func test_computeRepair_cellCollision_tombstonesLoser() {
        let loser = bt("lose", row: 0, col: 0, taskId: "t1", version: 1)
        let winner = bt("win", row: 0, col: 0, taskId: "t2", version: 2)
        let result = PlacementIntegrity.computeRepair([loser, winner], boardSize: 3)

        XCTAssertEqual(result.toTombstone.map(\.id), ["lose"])
    }

    /// Unlike `resolvePlacements`, `computeRepair` DOES collapse a same
    /// task placed at two different (non-colliding) cells — this is the
    /// board-wide invariant only the repair pass enforces.
    func test_computeRepair_sameTaskDifferentCells_tombstonesLoser() {
        let loser = bt("lose", row: 0, col: 0, taskId: "shared", version: 1)
        let winner = bt("win", row: 1, col: 1, taskId: "shared", version: 3)
        let result = PlacementIntegrity.computeRepair([loser, winner], boardSize: 3)

        XCTAssertEqual(result.toTombstone.map(\.id), ["lose"])
    }

    func test_computeRepair_outOfBounds_tombstonedUnconditionally() {
        // Even the HIGHEST version loses when out of bounds — no winner rule
        // applies to violation class 1.
        let oob = bt("oob", row: 7, col: 0, taskId: "t1", version: 99)
        let ok = bt("ok", row: 0, col: 0, taskId: "t1", version: 1)
        let result = PlacementIntegrity.computeRepair([oob, ok], boardSize: 3)

        XCTAssertEqual(result.toTombstone.map(\.id), ["oob"])
    }

    /// Cell collision resolves FIRST; same-task dedup then evaluates only
    /// the cell-collision survivors, so a chain reaction cascades to
    /// exactly one final survivor.
    func test_computeRepair_cellCollisionThenTaskDuplicate_cascadesToOneSurvivor() {
        let dAtOrigin = bt("bt-d-at-00", row: 0, col: 0, taskId: "task-D", version: 1)
        let aAtOrigin = bt("bt-a-at-00", row: 0, col: 0, taskId: "task-A", version: 2)
        let aElsewhere = bt("bt-a-at-11", row: 1, col: 1, taskId: "task-A", version: 3)

        let result = PlacementIntegrity.computeRepair([dAtOrigin, aAtOrigin, aElsewhere], boardSize: 3)

        XCTAssertEqual(Set(result.toTombstone.map(\.id)), ["bt-d-at-00", "bt-a-at-00"])
    }

    func test_computeRepair_threeWayCollision_tombstonesBothLosers() {
        let a = bt("bt-1", row: 4, col: 4, taskId: "task-1", version: 1)
        let b = bt("bt-2", row: 4, col: 4, taskId: "task-2", version: 5)
        let c = bt("bt-3", row: 4, col: 4, taskId: "task-3", version: 3)

        let result = PlacementIntegrity.computeRepair([a, b, c], boardSize: 5)

        XCTAssertEqual(Set(result.toTombstone.map(\.id)), ["bt-1", "bt-3"])
    }

    func test_computeRepair_isIdempotent() {
        let rows = [
            bt("lose", row: 0, col: 0, taskId: "t1", version: 1),
            bt("win", row: 0, col: 0, taskId: "t2", version: 2),
        ]
        let first = PlacementIntegrity.computeRepair(rows, boardSize: 3)
        let tombstonedIds = Set(first.toTombstone.map(\.id))
        let survivors = rows.filter { !tombstonedIds.contains($0.id) }
        let second = PlacementIntegrity.computeRepair(survivors, boardSize: 3)

        XCTAssertTrue(second.toTombstone.isEmpty)
    }

    func test_computeRepair_isOrderIndependent() {
        let dAtOrigin = bt("bt-d-at-00", row: 0, col: 0, taskId: "task-D", version: 1)
        let aAtOrigin = bt("bt-a-at-00", row: 0, col: 0, taskId: "task-A", version: 2)
        let aElsewhere = bt("bt-a-at-11", row: 1, col: 1, taskId: "task-A", version: 3)
        let rows = [dAtOrigin, aAtOrigin, aElsewhere]

        let forward = PlacementIntegrity.computeRepair(rows, boardSize: 3)
        let reversed = PlacementIntegrity.computeRepair(rows.reversed(), boardSize: 3)

        XCTAssertEqual(Set(forward.toTombstone.map(\.id)), Set(reversed.toTombstone.map(\.id)))
    }
}
