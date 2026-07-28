import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot tests for `TaskDeleteConfirmView` (Riso reskin) — renders the REAL
/// view (init-seedable from `task` + `impact`), not a mirror.
///
/// Determinism: affected boards use explicit far-past / far-future `endDate`s so
/// `isBoardExpired` (which compares against `Date()`) is stable across runs —
/// past ⇒ red EXPIRED pill, future ⇒ status badge.
///
/// Variants (light + dark each):
///   1. Rich — 3 boards (active / completed / expired) + compound-parent detach
///   2. Subtasks released — no boards, parent-link count (compound being deleted)
///   3. Empty — no boards, no other rows ("No other rows affected.")
final class RisoDeleteConfirmSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // Far-future / far-past windows for deterministic expiry.
    private let future = "2030-12-31T23:59:59.000Z"
    private let pastStart = "2020-01-01T00:00:00.000Z"
    private let pastEnd = "2020-01-31T23:59:59.000Z"

    private func boards() -> [Board] {
        [
            SnapshotFixtures.makeBoard(id: "b-active", name: "April Reading Sprint", status: .active, endDate: future),
            SnapshotFixtures.makeBoard(id: "b-done", name: "Q1 Fitness", status: .completed, endDate: future),
            SnapshotFixtures.makeBoard(id: "b-exp", name: "January Detox", status: .active, startDate: pastStart, endDate: pastEnd),
        ]
    }

    private func richView() -> some View {
        let task = SnapshotFixtures.makeTask(id: "t1", title: "Drink water", type: .normal)
        let impact = AppDatabase.TaskDeletionImpact(
            boardTaskCount: 4,
            affectedBoardIds: ["b-active", "b-done", "b-exp"],
            affectedBoards: boards(),
            childLinkCount: 2,
            parentLinkCount: 0,
            counterMemberCount: 0,
            counterMembers: []
        )
        return TaskDeleteConfirmView(task: task, impact: impact, onConfirm: {}, onCancel: {})
    }

    private func releasedView() -> some View {
        let task = SnapshotFixtures.makeTask(id: "t2", title: "Morning routine", type: .compound)
        let impact = AppDatabase.TaskDeletionImpact(
            boardTaskCount: 0,
            affectedBoardIds: [],
            affectedBoards: [],
            childLinkCount: 0,
            parentLinkCount: 3,
            counterMemberCount: 0,
            counterMembers: []
        )
        return TaskDeleteConfirmView(task: task, impact: impact, onConfirm: {}, onCancel: {})
    }

    private func emptyView() -> some View {
        let task = SnapshotFixtures.makeTask(id: "t3", title: "Unused task", type: .normal)
        let impact = AppDatabase.TaskDeletionImpact(
            boardTaskCount: 0,
            affectedBoardIds: [],
            affectedBoards: [],
            childLinkCount: 0,
            parentLinkCount: 0,
            counterMemberCount: 0,
            counterMembers: []
        )
        return TaskDeleteConfirmView(task: task, impact: impact, onConfirm: {}, onCancel: {})
    }

    // MARK: - Rich

    func testRichLight() {
        assertSnapshot(of: richView(), as: .image(layout: .fixed(width: 393, height: 560)), record: recordMode)
    }

    func testRichDark() {
        assertSnapshot(of: richView(), as: .image(layout: .fixed(width: 393, height: 560), traits: .init(userInterfaceStyle: .dark)), record: recordMode)
    }

    // MARK: - Subtasks released

    func testReleasedLight() {
        assertSnapshot(of: releasedView(), as: .image(layout: .fixed(width: 393, height: 360)), record: recordMode)
    }

    func testReleasedDark() {
        assertSnapshot(of: releasedView(), as: .image(layout: .fixed(width: 393, height: 360), traits: .init(userInterfaceStyle: .dark)), record: recordMode)
    }

    // MARK: - Empty

    func testEmptyLight() {
        assertSnapshot(of: emptyView(), as: .image(layout: .fixed(width: 393, height: 320)), record: recordMode)
    }

    func testEmptyDark() {
        assertSnapshot(of: emptyView(), as: .image(layout: .fixed(width: 393, height: 320), traits: .init(userInterfaceStyle: .dark)), record: recordMode)
    }
}
