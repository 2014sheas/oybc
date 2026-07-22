import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the Riso play-board visual layer (Phase 2).
///
/// Covers every leaf presentational component in both "day press" (light) and
/// "night press" (dark) modes, plus a composed static grid fixture. Because
/// `BoardPlayView` itself self-loads from `AppDatabase.shared`, we snapshot
/// the leaf components directly — the DB-backed container needs interactive
/// verification per CLAUDE.md conventions.
///
/// Animation states (cell pop, toast drop-in, confetti fall) cannot be
/// captured in static snapshots — those require interactive user verification.
/// Static snapshots capture the *end states* of each animated transition.
final class RisoPlayBoardSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - Play cells (all variants)

    func testCellRestingLight() {
        let view = cellGrid([
            RisoBoardPlayCell(title: "Meditate", taskType: .normal, isCompleted: false),
            RisoBoardPlayCell(title: "Run 5 km every morning before breakfast", taskType: .normal, isCompleted: false),
            RisoBoardPlayCell(title: "Journal", taskType: .normal, isCompleted: false),
        ])
        assertSnapshot(of: view, as: .image(layout: .fixed(width: 393, height: 200)), record: recordMode)
    }

    func testCellRestingDark() {
        let view = cellGrid([
            RisoBoardPlayCell(title: "Meditate", taskType: .normal, isCompleted: false),
            RisoBoardPlayCell(title: "Run 5 km every morning before breakfast", taskType: .normal, isCompleted: false),
            RisoBoardPlayCell(title: "Journal", taskType: .normal, isCompleted: false),
        ])
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 200), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }

    func testCellDoneNormalLight() {
        let view = cellGrid([
            RisoBoardPlayCell(title: "Meditate", taskType: .normal, isCompleted: true),
            RisoBoardPlayCell(title: "Walk 10k steps", taskType: .normal, isCompleted: true),
            RisoBoardPlayCell(title: "Short task", taskType: .normal, isCompleted: false),
        ])
        assertSnapshot(of: view, as: .image(layout: .fixed(width: 393, height: 200)), record: recordMode)
    }

    func testCellDoneNormalDark() {
        let view = cellGrid([
            RisoBoardPlayCell(title: "Meditate", taskType: .normal, isCompleted: true),
            RisoBoardPlayCell(title: "Walk 10k steps", taskType: .normal, isCompleted: true),
            RisoBoardPlayCell(title: "Short task", taskType: .normal, isCompleted: false),
        ])
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 200), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }

    func testCellCountingWithProgressLight() {
        let view = cellGrid([
            RisoBoardPlayCell(title: "Steps", taskType: .counting, isCompleted: false, currentCount: 6, maxCount: 10),
            RisoBoardPlayCell(title: "Run", taskType: .counting, isCompleted: true, currentCount: 5, maxCount: 5),
            RisoBoardPlayCell(title: "Drink water", taskType: .counting, isCompleted: false, currentCount: 0, maxCount: 8),
        ])
        assertSnapshot(of: view, as: .image(layout: .fixed(width: 393, height: 200)), record: recordMode)
    }

    func testCellCountingWithProgressDark() {
        let view = cellGrid([
            RisoBoardPlayCell(title: "Steps", taskType: .counting, isCompleted: false, currentCount: 6, maxCount: 10),
            RisoBoardPlayCell(title: "Run", taskType: .counting, isCompleted: true, currentCount: 5, maxCount: 5),
            RisoBoardPlayCell(title: "Drink water", taskType: .counting, isCompleted: false, currentCount: 0, maxCount: 8),
        ])
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 200), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }

    func testCellCompoundLight() {
        let view = cellGrid([
            RisoBoardPlayCell(title: "Morning routine", taskType: .compound, isCompleted: false, compoundDoneCount: 2, compoundChildCount: 4),
            RisoBoardPlayCell(title: "All done", taskType: .compound, isCompleted: true, compoundDoneCount: 3, compoundChildCount: 3),
            RisoBoardPlayCell(title: "Not started", taskType: .compound, isCompleted: false, compoundDoneCount: 0, compoundChildCount: 5),
        ])
        assertSnapshot(of: view, as: .image(layout: .fixed(width: 393, height: 200)), record: recordMode)
    }

    func testCellCompoundDark() {
        let view = cellGrid([
            RisoBoardPlayCell(title: "Morning routine", taskType: .compound, isCompleted: false, compoundDoneCount: 2, compoundChildCount: 4),
            RisoBoardPlayCell(title: "All done", taskType: .compound, isCompleted: true, compoundDoneCount: 3, compoundChildCount: 3),
            RisoBoardPlayCell(title: "Not started", taskType: .compound, isCompleted: false, compoundDoneCount: 0, compoundChildCount: 5),
        ])
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 200), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }

    /// Operator-aware compound bars (bugfix): OR shows done-of-1, M_OF_N
    /// shows done-of-threshold — never done-of-all-children.
    func testCellCompoundOperatorAwareBarsLight() {
        let view = cellGrid([
            RisoBoardPlayCell(title: "Any chore", taskType: .compound, isCompleted: true, compoundDoneCount: 1, compoundChildCount: 4, compoundRequiredCount: 1),
            RisoBoardPlayCell(title: "2 of 5 habits", taskType: .compound, isCompleted: false, compoundDoneCount: 1, compoundChildCount: 5, compoundRequiredCount: 2),
            RisoBoardPlayCell(title: "All of 3", taskType: .compound, isCompleted: false, compoundDoneCount: 2, compoundChildCount: 3, compoundRequiredCount: 3),
        ])
        assertSnapshot(of: view, as: .image(layout: .fixed(width: 393, height: 200)), record: recordMode)
    }

    func testCellFreeLight() {
        let view = cellGrid([
            RisoBoardPlayCell(title: "FREE", taskType: .normal, isCompleted: false, isCenter: true),
            RisoBoardPlayCell(title: "Normal", taskType: .normal, isCompleted: false),
            RisoBoardPlayCell(title: "Done", taskType: .normal, isCompleted: true),
        ])
        assertSnapshot(of: view, as: .image(layout: .fixed(width: 393, height: 200)), record: recordMode)
    }

    func testCellFreeDark() {
        let view = cellGrid([
            RisoBoardPlayCell(title: "FREE", taskType: .normal, isCompleted: false, isCenter: true),
            RisoBoardPlayCell(title: "Normal", taskType: .normal, isCompleted: false),
            RisoBoardPlayCell(title: "Done", taskType: .normal, isCompleted: true),
        ])
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 200), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }

    /// Regression for issue #345: a CUSTOM_FREE center cell must render its
    /// custom name, not a hardcoded "FREE". `BoardPlayView` passes the board's
    /// `centerSquareCustomName` as the cell `title`; `centerCellContent` now
    /// renders that title (falling back to "FREE" only when empty).
    func testCellCustomFreeCenterLight() {
        let view = cellGrid([
            RisoBoardPlayCell(title: "REST DAY", taskType: .normal, isCompleted: false, isCenter: true),
            RisoBoardPlayCell(title: "Treat yourself", taskType: .normal, isCompleted: false, isCenter: true),
            RisoBoardPlayCell(title: "FREE", taskType: .normal, isCompleted: false, isCenter: true),
        ])
        assertSnapshot(of: view, as: .image(layout: .fixed(width: 393, height: 200)), record: recordMode)
    }

    func testCellCustomFreeCenterDark() {
        let view = cellGrid([
            RisoBoardPlayCell(title: "REST DAY", taskType: .normal, isCompleted: false, isCenter: true),
            RisoBoardPlayCell(title: "Treat yourself", taskType: .normal, isCompleted: false, isCenter: true),
            RisoBoardPlayCell(title: "FREE", taskType: .normal, isCompleted: false, isCenter: true),
        ])
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 200), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }

    func testCellBingoLineGoldRingLight() {
        let view = cellGrid([
            RisoBoardPlayCell(title: "Bingo incomplete", taskType: .normal, isCompleted: false, isBingoLine: true),
            RisoBoardPlayCell(title: "Bingo complete", taskType: .normal, isCompleted: true, isBingoLine: true),
            RisoBoardPlayCell(title: "No bingo", taskType: .normal, isCompleted: false, isBingoLine: false),
        ])
        assertSnapshot(of: view, as: .image(layout: .fixed(width: 393, height: 200)), record: recordMode)
    }

    func testCellBingoLineGoldRingDark() {
        let view = cellGrid([
            RisoBoardPlayCell(title: "Bingo incomplete", taskType: .normal, isCompleted: false, isBingoLine: true),
            RisoBoardPlayCell(title: "Bingo complete", taskType: .normal, isCompleted: true, isBingoLine: true),
            RisoBoardPlayCell(title: "No bingo", taskType: .normal, isCompleted: false, isBingoLine: false),
        ])
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 200), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }

    // MARK: - Stat bar

    func testStatBarLight() {
        let view = statBarHost(completed: 12, total: 25, bingos: 1, expiry: "4d")
        assertSnapshot(of: view, as: .image(layout: .fixed(width: 393, height: 100)), record: recordMode)
    }

    func testStatBarDark() {
        let view = statBarHost(completed: 12, total: 25, bingos: 1, expiry: "4d")
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 100), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }

    func testStatBarAllCompleteLight() {
        let view = statBarHost(completed: 25, total: 25, bingos: 5, expiry: "Expired")
        assertSnapshot(of: view, as: .image(layout: .fixed(width: 393, height: 100)), record: recordMode)
    }

    func testStatBarAllCompleteDark() {
        let view = statBarHost(completed: 25, total: 25, bingos: 5, expiry: "Expired")
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 100), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }

    // MARK: - Bingo toast

    func testBingoToastLight() {
        let view = toastHost()
        assertSnapshot(of: view, as: .image(layout: .fixed(width: 393, height: 120)), record: recordMode)
    }

    func testBingoToastDark() {
        let view = toastHost()
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 120), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }

    // MARK: - GREENLOG overlay

    func testGreenlogOverlayLight() {
        let view = greenlogHost()
        assertSnapshot(of: view, as: .image(layout: .fixed(width: 393, height: 852)), record: recordMode)
    }

    func testGreenlogOverlayDark() {
        let view = greenlogHost()
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 852), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }

    // MARK: - Composed 5×5 grid with mixed states (static fixture)

    func testComposedGridLight() {
        let view = composedGridHost()
        assertSnapshot(of: view, as: .image(layout: .fixed(width: 393, height: 500)), record: recordMode)
    }

    func testComposedGridDark() {
        let view = composedGridHost()
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 500), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }

    // MARK: - Helpers

    /// Wraps an array of cells in a 3-column grid on a paper background.
    @ViewBuilder
    private func cellGrid(_ cells: [RisoBoardPlayCell]) -> some View {
        ZStack {
            RisoPaperBackground()
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: Riso.cellGap), count: 3),
                spacing: Riso.cellGap
            ) {
                ForEach(0..<cells.count, id: \.self) { i in
                    cells[i]
                }
            }
            .padding(Riso.gutter)
        }
    }

    @ViewBuilder
    private func statBarHost(completed: Int, total: Int, bingos: Int, expiry: String) -> some View {
        ZStack {
            RisoPaperBackground()
            RisoStatBar(
                completedTasks: completed,
                totalTasks: total,
                linesCompleted: bingos,
                expiryText: expiry
            )
            .padding(Riso.gutter)
        }
    }

    @ViewBuilder
    private func toastHost() -> some View {
        ZStack {
            RisoPaperBackground()
            RisoBingoToast(subtitle: "Row 2 complete!", bingoCount: 2)
                .padding(Riso.gutter)
        }
    }

    @ViewBuilder
    private func greenlogHost() -> some View {
        RisoGreenlogOverlay(
            completedTasks: 25,
            totalTasks: 25,
            linesCompleted: 12,
            boardName: "Weekly Wellness",
            streak: "7d"
        )
    }

    /// 5×5 static grid with representative cell states: done (normal, counting,
    /// compound), FREE center, bingo-line ring, and resting cells.
    /// No DB access — all props injected directly.
    @ViewBuilder
    private func composedGridHost() -> some View {
        ZStack {
            RisoPaperBackground()
            let states: [(String, CellTaskType, Bool, Bool, Bool, Int, Int, Int, Int)] = [
                // (title, type, done, bingoLine, isCenter, cur, max, subDone, subTotal)
                ("Meditate",      .normal,   true,  true,  false, 0,  0,  0, 0),
                ("Read 30 min",   .normal,   false, true,  false, 0,  0,  0, 0),
                ("Walk",          .normal,   true,  true,  false, 0,  0,  0, 0),
                ("Journal",       .normal,   false, true,  false, 0,  0,  0, 0),
                ("Plants",        .normal,   true,  true,  false, 0,  0,  0, 0),
                ("Run",           .counting, true,  false, false, 5,  5,  0, 0),
                ("Steps",         .counting, false, false, false, 6,  10, 0, 0),
                ("Drink",         .counting, false, false, false, 0,  8,  0, 0),
                ("Morning",       .compound, false, false, false, 0,  0,  2, 4),
                ("Routine all",   .compound, true,  false, false, 0,  0,  3, 3),
                ("Stretch",       .normal,   true,  false, false, 0,  0,  0, 0),
                ("Yoga",          .normal,   false, false, false, 0,  0,  0, 0),
                ("FREE",          .normal,   false, false, true,  0,  0,  0, 0),
                ("Budget",        .normal,   false, false, false, 0,  0,  0, 0),
                ("Inbox zero",    .normal,   false, false, false, 0,  0,  0, 0),
                ("Floss",         .normal,   true,  false, false, 0,  0,  0, 0),
                ("Sleep 8h",      .normal,   false, false, false, 0,  0,  0, 0),
                ("Gratitude",     .normal,   true,  false, false, 0,  0,  0, 0),
                ("Spanish",       .counting, false, false, false, 1,  3,  0, 0),
                ("Call family",   .normal,   false, false, false, 0,  0,  0, 0),
                ("No social",     .normal,   true,  false, false, 0,  0,  0, 0),
                ("Early bed",     .normal,   false, false, false, 0,  0,  0, 0),
                ("Plan week",     .normal,   true,  false, false, 0,  0,  0, 0),
                ("Read news",     .normal,   false, false, false, 0,  0,  0, 0),
                ("Push-ups",      .counting, false, false, false, 20, 30, 0, 0),
            ]
            LazyVGrid(
                columns: Array(repeating: GridItem(.flexible(), spacing: Riso.cellGap), count: 5),
                spacing: Riso.cellGap
            ) {
                ForEach(0..<states.count, id: \.self) { i in
                    let s = states[i]
                    RisoBoardPlayCell(
                        title: s.0,
                        taskType: s.1,
                        isCompleted: s.2,
                        isBingoLine: s.3,
                        isCenter: s.4,
                        currentCount: s.5,
                        maxCount: s.6,
                        compoundDoneCount: s.7,
                        compoundChildCount: s.8
                    )
                }
            }
            .padding(Riso.gutter)
        }
    }
}
