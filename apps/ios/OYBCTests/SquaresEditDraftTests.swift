import XCTest
@testable import OYBC

/// Pure tests for the Board Edit redesign slice 3 draft kernels
/// (`SquaresEditCount`, `SquaresEditDirty`, `buildSquaresEditCells`) — no
/// `BoardPlayViewModel`, no database. Mirrors web's
/// `squareEditCount.test.ts` + `squaresEditDraft.test.ts` case tables (T4
/// hand-off — the case tables must match across platforms).
final class SquaresEditDraftTests: XCTestCase {

    // MARK: - SquaresEditCount (D11)

    private func input(
        replacements: Int = 0, adds: Int = 0, removals: Int = 0, taskOverrides: Int = 0,
        lockChanges: Int = 0, centerChanged: Bool = false, movedPlacements: Int = 0, shuffled: Bool = false
    ) -> SquaresEditCount.Input {
        .init(
            replacements: replacements, adds: adds, removals: removals, taskOverrides: taskOverrides,
            lockChanges: lockChanges, centerChanged: centerChanged, movedPlacements: movedPlacements,
            shuffled: shuffled
        )
    }

    func test_count_cleanDraft_isZero() {
        XCTAssertEqual(SquaresEditCount.count(input()), 0)
    }

    func test_count_shuffle_isOne() {
        XCTAssertEqual(SquaresEditCount.count(input(movedPlacements: 5, shuffled: true)), 1)
    }

    func test_count_shuffleThenReturnToBaseline_isZero() {
        // The formula reads `movedPlacements`, not the `shuffled` flag alone —
        // once every placement is back at its seeded slot, positionEdits is 0
        // regardless of `shuffled` (D9/OQ9: "still 1 while shuffled is set",
        // which only applies while something is actually moved).
        XCTAssertEqual(SquaresEditCount.count(input(movedPlacements: 0, shuffled: true)), 0)
    }

    func test_count_holdMovesWithoutShuffle_countsEachMove() {
        XCTAssertEqual(SquaresEditCount.count(input(movedPlacements: 3, shuffled: false)), 3)
    }

    func test_count_addRemoveCenter_eachCountOne() {
        XCTAssertEqual(SquaresEditCount.count(input(adds: 1)), 1)
        XCTAssertEqual(SquaresEditCount.count(input(removals: 1)), 1)
        XCTAssertEqual(SquaresEditCount.count(input(centerChanged: true)), 1)
    }

    func test_count_replacementsOverridesLocks_eachCountOne() {
        XCTAssertEqual(SquaresEditCount.count(input(replacements: 1)), 1)
        XCTAssertEqual(SquaresEditCount.count(input(taskOverrides: 1)), 1)
        XCTAssertEqual(SquaresEditCount.count(input(lockChanges: 1)), 1)
    }

    func test_count_composedEdit_sums() {
        let c = SquaresEditCount.count(input(
            replacements: 1, adds: 1, removals: 1, taskOverrides: 1,
            lockChanges: 1, centerChanged: true, movedPlacements: 2, shuffled: false
        ))
        XCTAssertEqual(c, 1 + 1 + 1 + 1 + 1 + 1 + 2)
    }

    // MARK: - SquaresEditDirty (D12)

    private func cell(
        id: String = "bt1", isNew: Bool = false, taskId: String = "t1", isLocked: Bool = false,
        originalRow: Int? = 0, originalCol: Int? = 0, originalTaskId: String? = "t1",
        originalIsLocked: Bool = false
    ) -> SquaresDraftCell {
        SquaresDraftCell(
            id: id, isNew: isNew, taskId: taskId, pending: nil, isLocked: isLocked,
            originalRow: originalRow, originalCol: originalCol,
            originalTaskId: originalTaskId, originalIsLocked: originalIsLocked
        )
    }

    func test_isDirty_unchangedCell_isFalse() {
        XCTAssertFalse(SquaresEditDirty.isDirty(cell: cell(), moved: false, hasTaskOverride: false))
    }

    func test_isDirty_stagedAdd_isTrue() {
        XCTAssertTrue(SquaresEditDirty.isDirty(
            cell: cell(isNew: true, originalRow: nil, originalCol: nil, originalTaskId: nil),
            moved: false, hasTaskOverride: false
        ))
    }

    func test_isDirty_replacedTask_isTrue() {
        XCTAssertTrue(SquaresEditDirty.isDirty(cell: cell(taskId: "t2"), moved: false, hasTaskOverride: false))
    }

    func test_isDirty_taskOverride_isTrue() {
        XCTAssertTrue(SquaresEditDirty.isDirty(cell: cell(), moved: false, hasTaskOverride: true))
    }

    func test_isDirty_lockChanged_isTrue() {
        XCTAssertTrue(SquaresEditDirty.isDirty(cell: cell(isLocked: true), moved: false, hasTaskOverride: false))
    }

    func test_isDirty_moved_isTrue() {
        XCTAssertTrue(SquaresEditDirty.isDirty(cell: cell(), moved: true, hasTaskOverride: false))
    }

    // MARK: - buildSquaresEditCells (D7/D20)

    func test_buildSquaresEditCells_freeCenter_hasNoDraftEntry() {
        let cells = buildSquaresEditCells(draft: [:], gridSize: 3, centerType: .free)
        XCTAssertEqual(cells.count, 9)
        let center = cells[4] // row1 col1, index 4 in a 3x3 grid
        XCTAssertTrue(center.isCenter)
        XCTAssertFalse(center.isEmpty)
        XCTAssertTrue(center.isPinned)
    }

    func test_buildSquaresEditCells_noneCenter_emptyIsPlainDashedSquare() {
        let cells = buildSquaresEditCells(draft: [:], gridSize: 3, centerType: .none)
        let center = cells[4]
        XCTAssertFalse(center.isCenter)
        XCTAssertTrue(center.isEmpty)
        XCTAssertFalse(center.isPinned)
    }

    func test_buildSquaresEditCells_locksAndDirtyFlowThrough() {
        let draft: [String: SquaresDraftCell] = [
            "0-0": cell(id: "bt1", taskId: "t2", originalTaskId: "t1"), // replaced -> dirty
            "0-1": cell(id: "bt2", taskId: "t2", isLocked: true, originalRow: 0, originalCol: 1,
                        originalTaskId: "t2", originalIsLocked: true), // locked, unchanged -> not dirty
        ]
        let cells = buildSquaresEditCells(draft: draft, gridSize: 3, centerType: .free)
        let c00 = cells[0]
        XCTAssertTrue(c00.isDirty)
        let c01 = cells[1]
        XCTAssertTrue(c01.isLocked)
        XCTAssertFalse(c01.isDirty)
    }

    // MARK: - shuffleUnlockedSlots reuse (D10) — sanity, cross-checked
    // against the pinned vectors in ShuffleUnlockedTests.

    func test_shuffle_fixedSlotsNeverMove() {
        let slots: [String?] = ["a", "b", "c", "d"]
        let fixed = [true, false, false, true]
        let result = Shuffle.shuffleUnlockedSlots(slots, fixed: fixed, rng: { 0.0 })
        XCTAssertEqual(result[0], "a")
        XCTAssertEqual(result[3], "d")
        XCTAssertEqual(Set(result.compactMap { $0 }), Set(slots.compactMap { $0 }))
    }

    // MARK: - D9 VoiceOver announcement copy (web aria-live parity)

    func test_moveResult_announcementCopy_matchesWeb() {
        XCTAssertEqual(SquaresEditMoveResult.moved(row: 0, col: 2).announcement(title: "Read"),
                       "Moved Read to row 1, column 3")
        XCTAssertEqual(SquaresEditMoveResult.blockedLocked.announcement(title: "Read"), "Read is locked")
        XCTAssertEqual(SquaresEditMoveResult.blockedEdge.announcement(title: "Read"),
                       "Already at the edge of the board")
        XCTAssertEqual(SquaresEditMoveResult.blockedLocked.announcement(title: ""), "This square is locked")
        XCTAssertNil(SquaresEditMoveResult.ignored.announcement(title: "Read"))
    }
}
