import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for Board Edit redesign slice 4 (T5): the ENDED header
/// pill, the ended banner, the ended-still-logging stat card, and the
/// closed-board late-log sheet (i10/i11: normal, undo, counting, compound). Each view
/// is a pure leaf (props only, no `AppDatabase.shared` / `@EnvironmentObject`
/// access), matching `BoardActionsSnapshotTests`'s posture.
final class BoardCloseReopenSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - Header ENDED pill

    func testHeaderEndedLight() {
        assertSnapshot(
            of: header(),
            as: .image(layout: .fixed(width: 393, height: 140)),
            record: recordMode
        )
    }

    func testHeaderEndedDark() {
        assertSnapshot(
            of: header(),
            as: .image(
                layout: .fixed(width: 393, height: 140),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Ended banner

    func testEndedBanner() {
        assertSnapshot(
            of: RisoEndedBannerView(date: "Sep 30")
                .padding(Riso.gutter)
                .background(Color.risoPaper),
            as: .image(layout: .fixed(width: 393, height: 90)),
            record: recordMode
        )
    }

    // MARK: - Stat bar — ended, still logging

    func testStatBarEndedStillLogging() {
        assertSnapshot(
            of: RisoStatBar(
                completedTasks: 12,
                totalTasks: 25,
                linesCompleted: 1,
                expiryText: "Expired",
                endedStillLoggingDate: "Sep 30"
            )
            .padding(Riso.gutter)
            .background(Color.risoPaper),
            as: .image(layout: .fixed(width: 393, height: 100)),
            record: recordMode
        )
    }

    // MARK: - Late-log sheet (i10 / i11)

    func testLateLogNormalLight() {
        assertSnapshot(of: lateLog(.normal), as: .image(layout: .fixed(width: 393, height: 190)), record: recordMode)
    }

    func testLateLogNormalDark() {
        assertSnapshot(
            of: lateLog(.normal),
            as: .image(layout: .fixed(width: 393, height: 190), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }

    func testLateLogNormalUndo() {
        assertSnapshot(
            of: lateLog(.normal, isUndoable: true),
            as: .image(layout: .fixed(width: 393, height: 190)),
            record: recordMode
        )
    }

    func testLateLogCounting() {
        assertSnapshot(
            of: lateLog(.counting(current: 3, max: 5, unit: "mi"), isUndoable: true),
            as: .image(layout: .fixed(width: 393, height: 260)),
            record: recordMode
        )
    }

    func testLateLogCompoundRuleUnmet() {
        let parts = [
            LateLogCompoundPart(id: "a", title: "Stretch", isStageable: true, alreadyDone: true),
            LateLogCompoundPart(id: "b", title: "Run 3 mi", isStageable: true, alreadyDone: false),
            LateLogCompoundPart(id: "c", title: "Weekly miles", isStageable: false, alreadyDone: false),
        ]
        assertSnapshot(
            of: lateLog(.compound(parts: parts), canCommit: false),
            as: .image(layout: .fixed(width: 393, height: 190 + 3 * 44)),
            record: recordMode
        )
    }

    // MARK: - View builders

    private func lateLog(
        _ kind: LateLogSheetView.Kind, isUndoable: Bool = false, canCommit: Bool = true
    ) -> some View {
        LateLogSheetView(
            windowLabel: "Sep 1 – 30",
            taskTitle: "Morning run",
            kind: kind,
            isUndoable: isUndoable,
            canCommitCompound: { _ in canCommit }
        )
    }

    /// D2 — an ended-but-unsealed board still offers Edit (any non-draft
    /// board); its BOARD section leads with Close instead of Delete-only.
    private func header() -> some View {
        BoardPlayHeaderView(
            kicker: "MONTHLY BOARD",
            name: "Spring Goals",
            streakValue: nil,
            status: .active,
            isSealed: false,
            isEnded: true,
            showRecurringBadge: false,
            canEdit: true,
            onEdit: {}
        )
        .padding(.horizontal, Riso.gutter)
        .padding(.top, 12)
        .background(Color.risoPaper)
    }
}
