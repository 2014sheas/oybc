import XCTest
@testable import OYBC

/// Board Edit redesign slice 2 (T1) — the pure "…" menu builder
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

    private func items(_ board: Board, _ template: RecurringBoardTemplate? = nil) -> [BoardMenuItem] {
        BoardMenuItems.items(board: board, sourceTemplate: template)
    }

    func test_adhocActive_detailsRepeatArchiveDelete() {
        XCTAssertEqual(items(makeBoard()), [.details, .repeatBoard, .archive, .delete])
    }

    func test_adhocEndedUnsealed_isStillEditable() {
        XCTAssertEqual(items(makeBoard(endDate: "2020-01-31T23:59:59.999")),
                       [.details, .repeatBoard, .archive, .delete])
    }

    func test_adhocSealed_deleteOnly() {
        XCTAssertEqual(items(makeBoard(sealedAt: "2026-10-01T06:00:00.000Z")), [.delete])
    }

    func test_coreActive_coreDefaultsAndDelete() {
        XCTAssertEqual(items(makeBoard(isCore: true)), [.coreDefaults, .delete])
    }

    func test_coreSealed_coreDefaultsAndDelete() {
        XCTAssertEqual(items(makeBoard(isCore: true, sealedAt: "2026-10-01T06:00:00.000Z")),
                       [.coreDefaults, .delete])
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
}
