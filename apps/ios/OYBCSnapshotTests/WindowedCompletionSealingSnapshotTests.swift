import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for Windowed Completion PR C slice 2/2 — the
/// board-sealing UX (docs/WINDOWED_COMPLETION.md §Sealing, §Effects of
/// sealed, Decision 9). Per the doc's testing matrix: closing-out banner
/// (0/1/3 boards), sealed board grid (read-only rendering), and the
/// disabled-with-explanation un-complete affordance.
///
/// `BoardPlayView` self-loads from `AppDatabase.shared`, so (per CLAUDE.md's
/// snapshot conventions) the sealed-grid coverage composes the pure leaf
/// `RisoBoardPlayCell` with `isLocked: true` — exactly the props a sealed
/// board's grid renders — rather than instantiating the DB-backed container.
/// The frozen-snapshot READ logic itself (`sealedCompletedCells` membership,
/// counting max/max-vs-0/max) is covered at the DB layer by `SealingTests`.
final class WindowedCompletionSealingSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - Sealed board grid (read-only rendering)

    /// A sealed board's header (name + `RisoSealedBadge` in place of the live
    /// status badge) above a grid where every cell is `isLocked: true` — no
    /// tap/context-menu affordance, `done` read from the frozen snapshot.
    /// Mixes normal (done/not-done) and counting (max/max vs 0/max — sealed
    /// boards only snapshot completion, never partial progress) cells.
    @ViewBuilder
    private func sealedGridHost() -> some View {
        ZStack {
            RisoPaperBackground()
            VStack(alignment: .leading, spacing: 14) {
                HStack {
                    VStack(alignment: .leading, spacing: 3) {
                        Text("DAILY BOARD")
                            .risoKicker()
                        Text("Morning Routine")
                            .font(.risoHead(20, .extraBold))
                            .foregroundStyle(Color.risoInk)
                    }
                    Spacer()
                    RisoSealedBadge()
                }
                LazyVGrid(
                    columns: Array(repeating: GridItem(.flexible(), spacing: Riso.cellGap), count: 3),
                    spacing: Riso.cellGap
                ) {
                    // Row 1 — normal cells: one frozen green, one frozen grey.
                    RisoBoardPlayCell(title: "Meditate", taskType: .normal, isCompleted: true, isLocked: true)
                    RisoBoardPlayCell(title: "Journal", taskType: .normal, isCompleted: false, isLocked: true)
                    // Counting, frozen green → honest max/max read (only
                    // completion was snapshotted, never partial progress).
                    RisoBoardPlayCell(title: "Pushups", taskType: .counting, isCompleted: true, isLocked: true, currentCount: 3, maxCount: 3)
                    // Counting, frozen grey → honest 0/max read.
                    RisoBoardPlayCell(title: "Drink water", taskType: .counting, isCompleted: false, isLocked: true, currentCount: 0, maxCount: 8)
                    RisoBoardPlayCell(title: "Read", taskType: .compound, isCompleted: true, isLocked: true, compoundDoneCount: 2, compoundChildCount: 2)
                    RisoBoardPlayCell(title: "Walk", taskType: .normal, isCompleted: false, isLocked: true)
                }
            }
            .padding(Riso.gutter)
        }
    }

    func testSealedGridLight() {
        assertSnapshot(of: sealedGridHost(), as: .image(layout: .fixed(width: 393, height: 420)), record: recordMode)
    }

    func testSealedGridDark() {
        assertSnapshot(
            of: sealedGridHost(),
            as: .image(layout: .fixed(width: 393, height: 420), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }

    // MARK: - Disabled-with-explanation un-complete affordance (Decision 9)

    private func toggleHost(isCompleted: Bool, sealBlocked: Bool) -> some View {
        ZStack {
            RisoPaperBackground()
            CompletionToggleView(isCompleted: isCompleted, sealBlocked: sealBlocked, action: {})
                .padding(Riso.gutter)
        }
    }

    func testCompletionToggleSealBlockedLight() {
        assertSnapshot(
            of: toggleHost(isCompleted: true, sealBlocked: true),
            as: .image(layout: .fixed(width: 393, height: 110)),
            record: recordMode
        )
    }

    func testCompletionToggleSealBlockedDark() {
        assertSnapshot(
            of: toggleHost(isCompleted: true, sealBlocked: true),
            as: .image(layout: .fixed(width: 393, height: 110), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }

    /// Contrast case — an ordinary (unblocked) complete state, no caption.
    func testCompletionToggleUnblockedLight() {
        assertSnapshot(
            of: toggleHost(isCompleted: true, sealBlocked: false),
            as: .image(layout: .fixed(width: 393, height: 90)),
            record: recordMode
        )
    }

    // MARK: - Closing-out banner (0 / 1 / 3 boards)

    private func closingBoard(id: String, name: String, timeframe: Timeframe) -> Board {
        SnapshotFixtures.makeBoard(
            id: id, name: name, boardSize: 5, timeframe: timeframe,
            startDate: "2026-04-01T00:00:00.000Z", endDate: "2026-04-01T23:59:59.000Z"
        )
    }

    private func bannerHost(_ boards: [Board]) -> some View {
        ZStack {
            RisoPaperBackground()
            VStack {
                ClosingOutBannerView(boards: boards, onLog: { _ in }, onSeal: { _ in })
                Spacer(minLength: 0)
            }
            .padding(Riso.gutter)
        }
    }

    func testClosingOutBannerZeroBoards() {
        // Renders nothing — a fixed-height host makes an empty result visible
        // as blank paper rather than a zero-size snapshot.
        assertSnapshot(of: bannerHost([]), as: .image(layout: .fixed(width: 393, height: 80)), record: recordMode)
    }

    func testClosingOutBannerOneBoard() {
        let boards = [closingBoard(id: "b-1", name: "Daily Reset", timeframe: .daily)]
        assertSnapshot(of: bannerHost(boards), as: .image(layout: .fixed(width: 393, height: 220)), record: recordMode)
    }

    func testClosingOutBannerThreeBoardsLight() {
        let boards = [
            closingBoard(id: "b-1", name: "Daily Reset", timeframe: .daily),
            closingBoard(id: "b-2", name: "Weekly Wellness", timeframe: .weekly),
            closingBoard(id: "b-3", name: "January Reading Sprint", timeframe: .monthly),
        ]
        assertSnapshot(of: bannerHost(boards), as: .image(layout: .fixed(width: 393, height: 420)), record: recordMode)
    }

    func testClosingOutBannerThreeBoardsDark() {
        let boards = [
            closingBoard(id: "b-1", name: "Daily Reset", timeframe: .daily),
            closingBoard(id: "b-2", name: "Weekly Wellness", timeframe: .weekly),
            closingBoard(id: "b-3", name: "January Reading Sprint", timeframe: .monthly),
        ]
        assertSnapshot(
            of: bannerHost(boards),
            as: .image(layout: .fixed(width: 393, height: 420), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }

    // MARK: - Sealed badge on the board-list card (RisoBoardCard)

    func testBoardCardSealedLight() {
        let board = closingBoard(id: "b-sealed", name: "January Reading Sprint", timeframe: .monthly)
        // Simulate a sealed board via JSON round-trip (Board's custom Codable
        // decoder has no memberwise `sealedAt` setter).
        var dict = try! JSONSerialization.jsonObject(with: JSONEncoder().encode(board)) as! [String: Any]
        dict["sealedAt"] = "2026-05-01T06:00:00.000Z"
        dict["sealedCompletedCells"] = "[0,1,2]"
        let sealedData = try! JSONSerialization.data(withJSONObject: dict)
        let sealed = try! JSONDecoder().decode(Board.self, from: sealedData)

        let view = ZStack {
            RisoPaperBackground()
            RisoBoardCard(board: sealed, timeframeLabel: "January 2026", isExpiring: false)
                .padding(Riso.gutter)
        }
        assertSnapshot(of: view, as: .image(layout: .fixed(width: 393, height: 200)), record: recordMode)
    }
}
