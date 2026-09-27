import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for Board Edit redesign slice 4 (T5): the ENDED header
/// pill, the ended banner, and the ended-still-logging stat card. Each view
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

    // MARK: - View builder

    private func header() -> some View {
        BoardPlayHeaderView(
            kicker: "MONTHLY BOARD",
            name: "Spring Goals",
            streakValue: nil,
            status: .active,
            isSealed: false,
            isEnded: true,
            showRecurringBadge: false,
            canEdit: false,
            onEdit: {},
            menuItems: [.close, .details, .repeatBoard, .archive, .delete],
            onMenuSelect: { _ in }
        )
        .padding(.horizontal, Riso.gutter)
        .padding(.top, 12)
        .background(Color.risoPaper)
    }
}
