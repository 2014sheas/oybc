import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the Riso Boards home screen (Phase 1).
///
/// Snapshots the leaf components (RisoBoardCard, RisoMiniGrid,
/// RisoCoreTimeframeGrid, BlipPlaceholder) with injected fixtures, plus
/// a composed home layout in both light and dark modes.
///
/// These tests use the `record: .missing` strategy so the first run
/// auto-records baselines without a manual flag. CI overrides with
/// `SNAPSHOT_TESTING_RECORD=never` so absent baselines fail loudly.
final class RisoBoardsHomeSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - RisoMiniGrid

    func testMiniGridEmpty() {
        let view = RisoMiniGrid(boardId: "board-empty", completedCount: 0, totalCount: 25)
            .padding(8)
            .background(Color.risoPaper2)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 62, height: 62)),
            record: recordMode
        )
    }

    func testMiniGridPartial() {
        let view = RisoMiniGrid(boardId: "board-abc", completedCount: 12, totalCount: 25)
            .padding(8)
            .background(Color.risoPaper2)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 62, height: 62)),
            record: recordMode
        )
    }

    func testMiniGridFull() {
        let view = RisoMiniGrid(boardId: "board-full", completedCount: 25, totalCount: 25)
            .padding(8)
            .background(Color.risoPaper2)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 62, height: 62)),
            record: recordMode
        )
    }

    // MARK: - RisoBoardCard — light

    func testBoardCardActiveLight() {
        let view = boardCardView(
            id: "b-active",
            name: "Weekly Wellness",
            timeframe: .weekly,
            status: .active,
            completed: 12,
            total: 25,
            lines: 1,
            timeframeLabel: "This week · 4 days left",
            isExpiring: false
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 353, height: 160)),
            record: recordMode
        )
    }

    func testBoardCardCompletedLight() {
        let view = boardCardView(
            id: "b-completed",
            name: "January Reading Sprint",
            timeframe: .monthly,
            status: .completed,
            completed: 25,
            total: 25,
            lines: 3,
            timeframeLabel: "January 2026",
            isExpiring: false
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 353, height: 160)),
            record: recordMode
        )
    }

    func testBoardCardDraftLight() {
        let view = boardCardView(
            id: "b-draft",
            name: "My New Board",
            timeframe: .weekly,
            status: .draft,
            completed: 0,
            total: 25,
            lines: 0,
            timeframeLabel: "This week",
            isExpiring: false
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 353, height: 160)),
            record: recordMode
        )
    }

    func testBoardCardExpiringLight() {
        let view = boardCardView(
            id: "b-expiring",
            name: "Fitness February",
            timeframe: .monthly,
            status: .active,
            completed: 20,
            total: 25,
            lines: 2,
            timeframeLabel: "This month · expires soon",
            isExpiring: true
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 353, height: 160)),
            record: recordMode
        )
    }

    // MARK: - RisoBoardCard — dark

    func testBoardCardActiveDark() {
        let view = boardCardView(
            id: "b-active-dark",
            name: "Weekly Wellness",
            timeframe: .weekly,
            status: .active,
            completed: 12,
            total: 25,
            lines: 1,
            timeframeLabel: "This week · 4 days left",
            isExpiring: false
        )
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 353, height: 160),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    func testBoardCardCompletedDark() {
        let view = boardCardView(
            id: "b-completed-dark",
            name: "January Reading Sprint",
            timeframe: .monthly,
            status: .completed,
            completed: 25,
            total: 25,
            lines: 3,
            timeframeLabel: "January 2026",
            isExpiring: false
        )
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 353, height: 160),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - RisoCoreTimeframeGrid — light

    func testCoreGridAllReadyLight() {
        let view = coreGridView(
            dailyBoard: nil,
            weeklyBoard: nil,
            monthlyBoard: nil,
            yearlyBoard: nil
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 353, height: 180)),
            record: recordMode
        )
    }

    func testCoreGridMixedStatusLight() {
        // Daily: ready, Weekly: active, Monthly: expiring, Yearly: active
        let weeklyBoard = SnapshotFixtures.makeBoard(
            id: "b-weekly", name: "Weekly Wellness",
            timeframe: .weekly, status: .active,
            startDate: "2026-06-09T00:00:00.000",
            endDate: "2026-06-15T23:59:59.999"
        )
        let monthlyBoard = SnapshotFixtures.makeBoard(
            id: "b-monthly", name: "June Goals",
            timeframe: .monthly, status: .active,
            startDate: "2026-06-01T00:00:00.000",
            // End date set to yesterday to force "expiring" (past = expiring calc skips, use active)
            endDate: "2026-06-12T01:00:00.000"
        )
        let yearlyBoard = SnapshotFixtures.makeBoard(
            id: "b-yearly", name: "2026 Goals",
            timeframe: .yearly, status: .active,
            startDate: "2026-01-01T00:00:00.000",
            endDate: "2026-12-31T23:59:59.999"
        )
        let view = coreGridView(
            dailyBoard: nil,
            weeklyBoard: weeklyBoard,
            monthlyBoard: monthlyBoard,
            yearlyBoard: yearlyBoard
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 353, height: 180)),
            record: recordMode
        )
    }

    func testCoreGridAllDoneLight() {
        let daily = SnapshotFixtures.makeBoard(id: "b-d", name: "Today", timeframe: .daily, status: .completed)
        let weekly = SnapshotFixtures.makeBoard(id: "b-w", name: "This week", timeframe: .weekly, status: .completed)
        let monthly = SnapshotFixtures.makeBoard(id: "b-m", name: "June", timeframe: .monthly, status: .completed)
        let yearly = SnapshotFixtures.makeBoard(id: "b-y", name: "2026", timeframe: .yearly, status: .completed)
        let view = coreGridView(dailyBoard: daily, weeklyBoard: weekly, monthlyBoard: monthly, yearlyBoard: yearly)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 353, height: 180)),
            record: recordMode
        )
    }

    // MARK: - RisoCoreTimeframeGrid — dark

    func testCoreGridAllReadyDark() {
        let view = coreGridView(
            dailyBoard: nil, weeklyBoard: nil, monthlyBoard: nil, yearlyBoard: nil
        )
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 353, height: 180),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - BlipPlaceholder

    func testBlipPlaceholderLight() {
        let view = ZStack {
            Color.risoPaper
            BlipPlaceholder(size: 72, mood: .calm)
        }
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 120, height: 120)),
            record: recordMode
        )
    }

    func testBlipPlaceholderDark() {
        let view = ZStack {
            Color.risoPaper
            BlipPlaceholder(size: 72, mood: .calm)
        }
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 120, height: 120),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Composed Boards home layout (light + dark)

    /// Renders a composed header + grid + chips + 3 board cards section
    /// in light mode. Uses ScrollView wrapper so the full layout is visible.
    func testBoardsHomeComposedLight() {
        let view = composedHomeView()
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 880)),
            record: recordMode
        )
    }

    func testBoardsHomeComposedDark() {
        let view = composedHomeView()
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 880),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Helpers

    private func boardCardView(
        id: String,
        name: String,
        timeframe: Timeframe,
        status: BoardStatus,
        completed: Int,
        total: Int,
        lines: Int,
        timeframeLabel: String,
        isExpiring: Bool
    ) -> some View {
        let board = makeBoard(
            id: id, name: name, timeframe: timeframe, status: status,
            completed: completed, total: total, lines: lines
        )
        return ZStack {
            Color.risoPaper
            RisoBoardCard(
                board: board,
                timeframeLabel: timeframeLabel,
                isExpiring: isExpiring
            )
            .padding(20)
        }
    }

    private func coreGridView(
        dailyBoard: Board?,
        weeklyBoard: Board?,
        monthlyBoard: Board?,
        yearlyBoard: Board?
    ) -> some View {
        let slots: [CoreBoardSlot] = [
            CoreBoardSlot(timeframe: .daily, windowStart: "2026-06-12T00:00:00.000", windowEnd: "2026-06-12T23:59:59.999", windowLabel: "Today", currentBoard: dailyBoard),
            CoreBoardSlot(timeframe: .weekly, windowStart: "2026-06-09T00:00:00.000", windowEnd: "2026-06-15T23:59:59.999", windowLabel: "This week", currentBoard: weeklyBoard),
            CoreBoardSlot(timeframe: .monthly, windowStart: "2026-06-01T00:00:00.000", windowEnd: "2026-06-30T23:59:59.999", windowLabel: "June 2026", currentBoard: monthlyBoard),
            CoreBoardSlot(timeframe: .yearly, windowStart: "2026-01-01T00:00:00.000", windowEnd: "2026-12-31T23:59:59.999", windowLabel: "2026", currentBoard: yearlyBoard),
        ]
        return ZStack {
            Color.risoPaper
            RisoCoreTimeframeGrid(slots: slots, now: Date())
                .padding(20)
        }
    }

    /// A composed layout that mirrors the Boards home scrollable header:
    /// header row, core grid, filter chips, and three board cards.
    /// Avoids AppDatabase.shared by rendering presentational views directly.
    @ViewBuilder
    private func composedHomeView() -> some View {
        let activeBoard = makeBoard(id: "b1", name: "Weekly Wellness", timeframe: .weekly, status: .active, completed: 12, total: 25, lines: 1)
        let completedBoard = makeBoard(id: "b2", name: "January Reading Sprint", timeframe: .monthly, status: .completed, completed: 25, total: 25, lines: 3)
        let draftBoard = makeBoard(id: "b3", name: "My New Board", timeframe: .weekly, status: .draft, completed: 0, total: 25, lines: 0)

        let slots: [CoreBoardSlot] = [
            CoreBoardSlot(timeframe: .daily, windowStart: "2026-06-12T00:00:00.000", windowEnd: "2026-06-12T23:59:59.999", windowLabel: "Today", currentBoard: nil),
            CoreBoardSlot(timeframe: .weekly, windowStart: "2026-06-09T00:00:00.000", windowEnd: "2026-06-15T23:59:59.999", windowLabel: "This week",
                currentBoard: SnapshotFixtures.makeBoard(id: "bw", name: "Weekly Wellness", timeframe: .weekly, status: .active)),
            CoreBoardSlot(timeframe: .monthly, windowStart: "2026-06-01T00:00:00.000", windowEnd: "2026-06-30T23:59:59.999", windowLabel: "June 2026",
                currentBoard: SnapshotFixtures.makeBoard(id: "bm", name: "June Goals", timeframe: .monthly, status: .active,
                    startDate: "2026-06-01T00:00:00.000", endDate: "2026-06-12T01:00:00.000")),
            CoreBoardSlot(timeframe: .yearly, windowStart: "2026-01-01T00:00:00.000", windowEnd: "2026-12-31T23:59:59.999", windowLabel: "2026",
                currentBoard: SnapshotFixtures.makeBoard(id: "by", name: "2026 Goals", timeframe: .yearly, status: .active)),
        ]

        ZStack(alignment: .top) {
            RisoPaperBackground()
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    // Header
                    HStack(alignment: .top, spacing: 12) {
                        VStack(alignment: .leading, spacing: 0) {
                            Text("Your boards").risoKicker()
                            Text("BINGO,\nbut make it\nyour goals.")
                                .risoH1()
                                .multilineTextAlignment(.leading)
                                .padding(.top, 4)
                        }
                        .frame(maxWidth: .infinity, alignment: .leading)
                        // + button placeholder (no action in snapshot)
                        Image(systemName: "plus")
                            .font(.system(size: 19, weight: .bold))
                            .foregroundStyle(Color.risoInk)
                            .frame(width: 46, height: 46)
                            .risoCard(fill: .risoGold)
                    }
                    .padding(.horizontal, Riso.gutter)
                    .padding(.top, 16)
                    .padding(.bottom, 16)

                    // Core grid
                    RisoCoreTimeframeGrid(slots: slots, now: Date())
                        .padding(.horizontal, Riso.gutter)
                        .padding(.bottom, 4)

                    // Filter chips
                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: 7) {
                            RisoChip(title: "All", isOn: false) {}
                            RisoChip(title: "Active", isOn: true) {}
                            RisoChip(title: "Completed", isOn: false) {}
                            RisoChip(title: "Draft", isOn: false) {}
                        }
                        .padding(.vertical, 2)
                    }
                    .padding(.horizontal, Riso.gutter)
                    .padding(.bottom, 14)

                    // Board cards
                    VStack(spacing: 0) {
                        RisoBoardCard(board: activeBoard, timeframeLabel: "This week · 4 days left", isExpiring: false)
                            .padding(.horizontal, Riso.gutter)
                            .padding(.bottom, 14)
                        RisoBoardCard(board: completedBoard, timeframeLabel: "January 2026", isExpiring: false)
                            .padding(.horizontal, Riso.gutter)
                            .padding(.bottom, 14)
                        RisoBoardCard(board: draftBoard, timeframeLabel: "This week", isExpiring: false)
                            .padding(.horizontal, Riso.gutter)
                            .padding(.bottom, 20)
                    }
                }
            }
        }
    }

    /// Builds a Board fixture inline via JSON round-trip (same technique
    /// as `SnapshotFixtures.makeBoard` — avoids importing that type here
    /// for the simple cases, but note that `composedHomeView` does call
    /// `SnapshotFixtures.makeBoard` for the core grid slots).
    private func makeBoard(
        id: String, name: String,
        timeframe: Timeframe, status: BoardStatus,
        completed: Int = 12, total: Int = 25, lines: Int = 1
    ) -> Board {
        let dict: [String: Any] = [
            "id": id, "userId": "snapshot-user", "name": name,
            "status": status.rawValue, "boardSize": 5,
            "timeframe": timeframe.rawValue,
            "startDate": "2026-06-01T00:00:00.000",
            "endDate": "2026-06-30T23:59:59.999",
            "centerSquareType": "free", "isRandomized": false,
            "totalTasks": total, "completedTasks": completed,
            "linesCompleted": lines, "completedLineIds": "[]",
            "createdAt": "2026-06-01T00:00:00.000",
            "updatedAt": "2026-06-01T00:00:00.000",
            "version": 1, "isCore": false, "isDeleted": false,
        ]
        let data = try! JSONSerialization.data(withJSONObject: dict)
        return try! JSONDecoder().decode(Board.self, from: data)
    }
}
