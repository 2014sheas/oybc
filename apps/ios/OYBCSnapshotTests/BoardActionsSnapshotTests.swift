import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the Board Edit redesign slice 2 title-row "…" menu
/// + its three sheets (`BoardPlayHeaderView`'s new menu slot,
/// `BoardDetailsSheetView`, `BoardRepeatSheetView`). Each view is a pure
/// leaf (props/bindings only, no `AppDatabase.shared` access), so no DB or
/// `@EnvironmentObject` wiring is needed — mirrors `BoardEditPanelSnapshotTests`.
///
/// `testDetailsMonthlyReadOnlyWindow` intentionally uses a FIXED board
/// (`SnapshotFixtures.makeBoard`'s hardcoded April 2026 dates), so the
/// rendered read-only window note reflects the board's own stored dates
/// (`BoardSetupFormView.storedWindow`, local-ISO so no UTC day shift),
/// never `now` — this is NOT one of the calendar-dependent snapshots
/// (`reference_snapshot_date_dependent.md`).
final class BoardActionsSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - Header (Board Edit consolidation, D1/D2 — single Edit button)

    func testHeaderAdhocActiveLight() {
        assertSnapshot(
            of: header(),
            as: .image(layout: .fixed(width: 393, height: 140)),
            record: recordMode
        )
    }

    func testHeaderAdhocActiveDark() {
        assertSnapshot(
            of: header(),
            as: .image(
                layout: .fixed(width: 393, height: 140),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    func testHeaderCoreActive() {
        assertSnapshot(
            of: header(kicker: "MONTHLY BOARD"),
            as: .image(layout: .fixed(width: 393, height: 140)),
            record: recordMode
        )
    }

    /// D2 — Edit still shows on a sealed/completed board (any non-draft
    /// board); only the isSealed CLOSED badge changes here.
    func testHeaderSealed() {
        assertSnapshot(
            of: header(status: .completed, isSealed: true),
            as: .image(layout: .fixed(width: 393, height: 140)),
            record: recordMode
        )
    }

    // MARK: - Board details sheet

    func testDetailsCustomLight() {
        let board = SnapshotFixtures.makeBoard(
            id: "bd-custom", name: "Spring Sprint", boardSize: 3,
            timeframe: .custom,
            startDate: "2026-04-01T00:00:00.000", endDate: "2026-04-30T23:59:59.999"
        )
        assertSnapshot(
            of: BoardDetailsSheetView(board: board, weekStartDay: "monday", onSave: { _ in }, onDismiss: {}),
            as: .image(layout: .fixed(width: 393, height: 700)),
            record: recordMode
        )
    }

    func testDetailsCustomDark() {
        let board = SnapshotFixtures.makeBoard(
            id: "bd-custom-dark", name: "Spring Sprint", boardSize: 3,
            timeframe: .custom,
            startDate: "2026-04-01T00:00:00.000", endDate: "2026-04-30T23:59:59.999"
        )
        assertSnapshot(
            of: BoardDetailsSheetView(board: board, weekStartDay: "monday", onSave: { _ in }, onDismiss: {}),
            as: .image(
                layout: .fixed(width: 393, height: 700),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    func testDetailsOngoing() {
        let board = SnapshotFixtures.makeBoard(
            id: "bd-ongoing", name: "Ongoing Habit Tracker", boardSize: 3,
            timeframe: .indefinite,
            startDate: "2026-04-01T00:00:00.000", endDate: "2026-04-30T23:59:59.999"
        )
        assertSnapshot(
            of: BoardDetailsSheetView(board: board, weekStartDay: "monday", onSave: { _ in }, onDismiss: {}),
            as: .image(layout: .fixed(width: 393, height: 700)),
            record: recordMode
        )
    }

    /// A calendar-timeframe (monthly) board renders the READ-ONLY computed
    /// window note (no date pickers) — the note formats the BOARD's own
    /// stored dates, not `now`, so this snapshot is deterministic.
    func testDetailsMonthlyReadOnlyWindow() {
        let board = SnapshotFixtures.makeBoard(
            id: "bd-monthly", name: "April Goals", boardSize: 5,
            timeframe: .monthly,
            startDate: "2026-04-01T00:00:00.000", endDate: "2026-04-30T23:59:59.999"
        )
        assertSnapshot(
            of: BoardDetailsSheetView(board: board, weekStartDay: "monday", onSave: { _ in }, onDismiss: {}),
            as: .image(layout: .fixed(width: 393, height: 700)),
            record: recordMode
        )
    }

    // MARK: - Repeat this board sheet

    func testRepeatOneOffCadenceStaged() {
        let board = SnapshotFixtures.makeBoard(id: "br-oneoff", name: "Spring Goals", boardSize: 3)
        assertSnapshot(
            of: BoardRepeatSheetView(
                board: board,
                sourceTemplate: nil,
                onSave: { _ in },
                onDismiss: {},
                initialCadence: .weekly
            ),
            as: .image(layout: .fixed(width: 393, height: 400)),
            record: recordMode
        )
    }

    func testRepeatRepeatingPaused() {
        let board = SnapshotFixtures.makeBoard(
            id: "br-repeating", name: "Spring Goals", boardSize: 3,
            spawnedFromTemplateId: "br-template-1"
        )
        let template = SnapshotFixtures.makeRecurringTemplate(
            id: "br-template-1", name: "Morning Kickstart", timeframe: .weekly, isActive: true
        )
        assertSnapshot(
            of: BoardRepeatSheetView(
                board: board,
                sourceTemplate: template,
                spawnNoteProvider: { "Picked 8 of 12 — 6 pulled in, 2 added today" },
                onSave: { _ in },
                onDismiss: {},
                initialRepeatActive: false
            ),
            as: .image(layout: .fixed(width: 393, height: 400)),
            record: recordMode
        )
    }

    // MARK: - View builder

    private func header(
        kicker: String = "MONTHLY BOARD",
        status: BoardStatus = .active,
        isSealed: Bool = false,
        canEdit: Bool = true
    ) -> some View {
        BoardPlayHeaderView(
            kicker: kicker,
            name: "Spring Goals",
            streakValue: nil,
            status: status,
            isSealed: isSealed,
            showRecurringBadge: false,
            canEdit: canEdit,
            onEdit: {}
        )
        .padding(.horizontal, Riso.gutter)
        .padding(.top, 12)
        .background(Color.risoPaper)
    }
}
