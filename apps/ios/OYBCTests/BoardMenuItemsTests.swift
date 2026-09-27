import XCTest
@testable import OYBC

/// Board Edit redesign slice 2 (T1) — the pure BOARD-section builder
/// (`BoardMenuItems`). Same case table as web `boardMenu.test.ts`.
final class BoardMenuItemsTests: XCTestCase {

    private func makeBoard(
        status: BoardStatus = .active,
        isCore: Bool = false,
        sealedAt: String? = nil,
        endDate: String? = "2026-09-30T23:59:59.999",
        center: CenterSquareType = .free,
        spawnedFromTemplateId: String? = nil
    ) -> Board {
        var dict: [String: Any] = [
            "id": "b1", "userId": "u1", "name": "Board", "status": status.rawValue,
            "boardSize": 3, "timeframe": Timeframe.monthly.rawValue,
            "startDate": "2026-09-01T00:00:00.000",
            "centerSquareType": center.rawValue, "isRandomized": false,
            "totalTasks": 9, "completedTasks": 0, "linesCompleted": 0,
            "createdAt": "2026-09-01T00:00:00.000", "updatedAt": "2026-09-01T00:00:00.000",
            "version": 1, "isDeleted": false, "isCore": isCore,
        ]
        if let endDate { dict["endDate"] = endDate }
        if let sealedAt { dict["sealedAt"] = sealedAt }
        if let spawnedFromTemplateId { dict["spawnedFromTemplateId"] = spawnedFromTemplateId }
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }

    private func makeTemplate() -> RecurringBoardTemplate {
        RecurringBoardTemplate(
            id: "tpl-1", userId: "u1", name: "Board", timeframe: .monthly, boardSize: 3,
            centerSquareType: .free, isRandomized: false, seedTaskIds: [],
            lastSpawnedWindowKey: nil, isActive: true,
            createdAt: "2026-09-01T00:00:00.000Z", updatedAt: "2026-09-01T00:00:00.000Z",
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        )
    }

    private func ms(_ iso: String) -> Double {
        (DateFormatting.parseISO(iso)?.timeIntervalSince1970 ?? 0) * 1000
    }

    /// Mid-window "now" for the still-live cases (board's default `endDate`
    /// is "2026-09-30T23:59:59.999").
    private var liveNowMs: Double { ms("2026-09-15T00:00:00.000Z") }
    /// Past-endDate "now" for the Ended cases.
    private var endedNowMs: Double { ms("2026-10-02T00:00:00.000Z") }

    private func items(_ board: Board, _ template: RecurringBoardTemplate? = nil, now: Double? = nil) -> [BoardMenuItem] {
        BoardMenuItems.items(board: board, sourceTemplate: template, now: now ?? liveNowMs)
    }

    func test_adhocActive_detailsRepeatArchiveDelete() {
        XCTAssertEqual(items(makeBoard()), [.details, .repeatBoard, .archive, .delete])
    }

    /// Board Edit redesign slice 4 (D12): an ended-but-unsealed ad-hoc board
    /// leads with Close board, then keeps the editable-shaped rest of the
    /// row (Board details is still offered — extending a custom board's
    /// endDate un-ends it).
    func test_adhocEnded_closeThenDetailsRepeatArchiveDelete() {
        XCTAssertEqual(
            items(makeBoard(endDate: "2020-01-31T23:59:59.999"), now: endedNowMs),
            [.close, .details, .repeatBoard, .archive, .delete]
        )
    }

    /// A board past its `endDate` at the OLD `now` reads as still-live at an
    /// earlier `now` — the same board, different instant.
    func test_adhocNotYetEnded_isStillFullyEditable() {
        XCTAssertEqual(
            items(makeBoard(endDate: "2020-01-31T23:59:59.999"), now: ms("2020-01-01T00:00:00.000Z")),
            [.details, .repeatBoard, .archive, .delete]
        )
    }

    /// Board Edit redesign slice 4 (D12): a closed (sealed) ad-hoc board
    /// leads with Reopen board — no Board details row.
    func test_adhocClosed_reopenRepeatArchiveDelete() {
        XCTAssertEqual(items(makeBoard(sealedAt: "2026-10-01T06:00:00.000Z")),
                       [.reopen, .repeatBoard, .archive, .delete])
    }

    func test_coreActive_coreDefaultsAndDelete() {
        XCTAssertEqual(items(makeBoard(isCore: true)), [.coreDefaults, .delete])
    }

    /// Board Edit redesign slice 4 (D12): core, ended (not yet sealed).
    func test_coreEnded_closeCoreDefaultsDelete() {
        XCTAssertEqual(
            items(makeBoard(isCore: true, endDate: "2020-01-31T23:59:59.999"), now: endedNowMs),
            [.close, .coreDefaults, .delete]
        )
    }

    /// Board Edit redesign slice 4 (D12): core, closed (sealed).
    func test_coreClosed_reopenCoreDefaultsDelete() {
        XCTAssertEqual(items(makeBoard(isCore: true, sealedAt: "2026-10-01T06:00:00.000Z")),
                       [.reopen, .coreDefaults, .delete])
    }

    /// OQ5: no Close/Reopen on an archived board even when its window has
    /// ended or it's sealed — unchanged from slice 2.
    func test_archivedEnded_deleteOnly() {
        XCTAssertEqual(
            items(makeBoard(status: .archived, endDate: "2020-01-31T23:59:59.999"), now: endedNowMs),
            [.delete]
        )
    }

    func test_archivedSealed_deleteOnly() {
        XCTAssertEqual(items(makeBoard(status: .archived, sealedAt: "2026-10-01T06:00:00.000Z")), [.delete])
    }

    func test_archived_deleteOnly() {
        XCTAssertEqual(items(makeBoard(status: .archived)), [.delete])
    }

    func test_draft_noMenu() {
        XCTAssertEqual(items(makeBoard(status: .draft)), [])
    }

    /// Board Edit slice 3 (D5): a legacy CHOSEN one-off reads as NONE + a
    /// locked center, so it is repeat-eligible like any locked board.
    func test_chosenCenterOneOff_showsRepeat() {
        XCTAssertEqual(items(makeBoard(center: .chosen)), [.details, .repeatBoard, .archive, .delete])
        XCTAssertTrue(BoardMenuItems.isRepeatEligible(board: makeBoard(center: .chosen), sourceTemplate: nil))
    }

    func test_unresolvedTemplate_hidesRepeat() {
        XCTAssertEqual(items(makeBoard(spawnedFromTemplateId: "tpl-1")), [.details, .archive, .delete])
    }

    func test_repeatingBoard_resolvedTemplate_showsRepeat() {
        XCTAssertEqual(items(makeBoard(spawnedFromTemplateId: "tpl-1"), makeTemplate()),
                       [.details, .repeatBoard, .archive, .delete])
        // A CHOSEN center doesn't hide Repeat on an already-repeating board
        // (pause / resume only; no spawn-pool validation).
        XCTAssertTrue(BoardMenuItems.isRepeatEligible(
            board: makeBoard(center: .chosen, spawnedFromTemplateId: "tpl-1"),
            sourceTemplate: makeTemplate()))
    }

    func test_itemPresentation() {
        XCTAssertEqual(BoardMenuItem.details.label, "Board details…")
        XCTAssertEqual(BoardMenuItem.coreDefaults.label, "Core defaults…")
        XCTAssertEqual(BoardMenuItem.repeatBoard.label, "Repeat this board…")
        XCTAssertEqual(BoardMenuItem.repeatBoard.rawValue, "repeat")
        XCTAssertTrue(BoardMenuItem.delete.isDestructive)
        XCTAssertFalse(BoardMenuItem.archive.isDestructive)
    }

    // MARK: - Edit consolidation (I1) — canEditSquares / squaresLockedReason /
    // showsEditButton / draftPolicy. Case table mirrored line-for-line with
    // web `boardMenu.test.ts`.

    func test_canEditSquares_activeLive() {
        XCTAssertTrue(BoardMenuItems.canEditSquares(board: makeBoard(), now: liveNowMs))
    }

    /// A board past its `endDate` at a LATER `now` still reads as editable
    /// at an earlier `now` — same board, different instant.
    func test_canEditSquares_activeNotYetEnded() {
        let board = makeBoard(endDate: "2020-01-31T23:59:59.999")
        XCTAssertTrue(BoardMenuItems.canEditSquares(board: board, now: ms("2020-01-01T00:00:00.000Z")))
    }

    func test_canEditSquares_endedUnsealed_false() {
        let board = makeBoard(endDate: "2020-01-31T23:59:59.999")
        XCTAssertFalse(BoardMenuItems.canEditSquares(board: board, now: endedNowMs))
    }

    func test_canEditSquares_closed_false() {
        let board = makeBoard(sealedAt: "2026-10-01T06:00:00.000Z")
        XCTAssertFalse(BoardMenuItems.canEditSquares(board: board, now: liveNowMs))
    }

    func test_canEditSquares_archived_false() {
        XCTAssertFalse(BoardMenuItems.canEditSquares(board: makeBoard(status: .archived), now: liveNowMs))
    }

    func test_canEditSquares_archivedSealed_false() {
        let board = makeBoard(status: .archived, sealedAt: "2026-10-01T06:00:00.000Z")
        XCTAssertFalse(BoardMenuItems.canEditSquares(board: board, now: liveNowMs))
    }

    func test_canEditSquares_completedUnsealed_false() {
        XCTAssertFalse(BoardMenuItems.canEditSquares(board: makeBoard(status: .completed), now: liveNowMs))
    }

    func test_canEditSquares_draft_false() {
        XCTAssertFalse(BoardMenuItems.canEditSquares(board: makeBoard(status: .draft), now: liveNowMs))
    }

    func test_squaresLockedReason_editable_nil() {
        XCTAssertNil(BoardMenuItems.squaresLockedReason(board: makeBoard(), now: liveNowMs))
    }

    func test_squaresLockedReason_endedUnsealed() {
        let board = makeBoard(endDate: "2020-01-31T23:59:59.999")
        XCTAssertEqual(
            BoardMenuItems.squaresLockedReason(board: board, now: endedNowMs),
            "This board has ended, so its squares can't change."
        )
    }

    func test_squaresLockedReason_closed() {
        let board = makeBoard(sealedAt: "2026-10-01T06:00:00.000Z")
        XCTAssertEqual(
            BoardMenuItems.squaresLockedReason(board: board, now: liveNowMs),
            "This board has ended, so its squares can't change."
        )
    }

    func test_squaresLockedReason_archived() {
        XCTAssertEqual(
            BoardMenuItems.squaresLockedReason(board: makeBoard(status: .archived), now: liveNowMs),
            "This board is archived, so its squares can't change."
        )
    }

    /// Archived wins over ended/closed copy even when both are true.
    func test_squaresLockedReason_archivedSealed_isArchivedCopy() {
        let board = makeBoard(status: .archived, sealedAt: "2026-10-01T06:00:00.000Z")
        XCTAssertEqual(
            BoardMenuItems.squaresLockedReason(board: board, now: liveNowMs),
            "This board is archived, so its squares can't change."
        )
    }

    func test_squaresLockedReason_completedUnsealed() {
        XCTAssertEqual(
            BoardMenuItems.squaresLockedReason(board: makeBoard(status: .completed), now: liveNowMs),
            "This board is complete, so its squares can't change."
        )
    }

    func test_showsEditButton_falseOnlyForDraft() {
        XCTAssertTrue(BoardMenuItems.showsEditButton(board: makeBoard(status: .active)))
        XCTAssertTrue(BoardMenuItems.showsEditButton(board: makeBoard(status: .completed)))
        XCTAssertTrue(BoardMenuItems.showsEditButton(board: makeBoard(status: .archived)))
        XCTAssertTrue(BoardMenuItems.showsEditButton(
            board: makeBoard(sealedAt: "2026-10-01T06:00:00.000Z")))
        XCTAssertFalse(BoardMenuItems.showsEditButton(board: makeBoard(status: .draft)))
    }

    func test_draftPolicy_allSevenKinds() {
        XCTAssertEqual(BoardMenuItems.draftPolicy(for: .details), .keep)
        XCTAssertEqual(BoardMenuItems.draftPolicy(for: .repeatBoard), .keep)
        XCTAssertEqual(BoardMenuItems.draftPolicy(for: .coreDefaults), .keep)
        XCTAssertEqual(BoardMenuItems.draftPolicy(for: .archive), .discardInConfirm)
        XCTAssertEqual(BoardMenuItems.draftPolicy(for: .delete), .discardInConfirm)
        XCTAssertEqual(BoardMenuItems.draftPolicy(for: .close), .discardFirst)
        XCTAssertEqual(BoardMenuItems.draftPolicy(for: .reopen), .discardFirst)
    }

    func test_discardSquaresSuffix_copy() {
        XCTAssertEqual(BoardMenuItems.discardSquaresSuffix, " Your unsaved square changes will be discarded.")
    }

    /// Invariant: whenever squares are editable, the BOARD section never
    /// offers Close or Reopen (those rows only exist when `canEditSquares`
    /// is false — D3/D8's `discardFirst` reasoning depends on this).
    func test_invariant_canEditSquares_impliesNoCloseOrReopen() {
        let cases: [(Board, Double)] = [
            (makeBoard(), liveNowMs),
            (makeBoard(endDate: "2020-01-31T23:59:59.999"), ms("2020-01-01T00:00:00.000Z")),
            (makeBoard(isCore: true), liveNowMs),
        ]
        for (board, now) in cases {
            guard BoardMenuItems.canEditSquares(board: board, now: now) else { continue }
            let kinds = items(board, now: now)
            XCTAssertFalse(kinds.contains(.close), "canEditSquares true but Close offered: \(board)")
            XCTAssertFalse(kinds.contains(.reopen), "canEditSquares true but Reopen offered: \(board)")
        }
    }
}
