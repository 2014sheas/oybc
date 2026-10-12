import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for `ShareBoardSheet` (5c bingo / 5d greenlog) and the
/// `ShareStoryPoster` raster target. Everything is prop-driven: the poster's
/// cells come from `momentPosterCells` over a hand-built replay, so no DB.
/// Activity sheet / Photos save are not capturable statically.
final class ShareBoardSheetSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - Fixtures

    private static let titles = [
        "Run 5k", "Read 20 pages", "Call mom", "Meditate", "Cook dinner",
        "Drink 8 glasses", "No sugar", "Stretch", "Journal", "Inbox zero",
        "Walk 10k steps", "Floss", "FREE", "Lift weights", "Budget review",
        "Sleep by 11", "Language lesson", "Water plants", "Write 500 words", "Tidy desk",
        "Bike to work", "Learn a song", "Early rise", "Screen-free hour", "Call a friend",
    ]

    private func types(_ idx: Int) -> CellTaskType {
        idx % 7 == 3 ? .counting : (idx % 11 == 5 ? .compound : .normal)
    }

    /// A replay over `size`: `done` cells landed in order; FREE centre on odd boards.
    private func replay(size: Int, done: [Int], lines: [String: Int] = [:]) -> BoardMomentReplay {
        let free = size % 2 == 1 ? (size / 2) * size + size / 2 : nil
        return BoardMomentReplay(
            order: done.map { MomentOrderEntry(boardTaskId: "bt\($0)", idx: $0, completedAt: nil) },
            freeIdx: free, lineClosureBeat: lines,
            completedTasks: done.count + (free == nil ? 0 : 1), totalTasks: size * size, size: size
        )
    }

    private func cells(size: Int, replay: BoardMomentReplay, kind: MomentTrigger.Kind) -> [PosterCell] {
        let inputs = (0..<(size * size)).map { i in
            PosterCellInput(
                idx: i, label: i == replay.freeIdx ? "FREE" : Self.titles[i % Self.titles.count],
                type: types(i), isFree: i == replay.freeIdx
            )
        }
        return momentPosterCells(replay: replay, cells: inputs, kind: kind)
    }

    /// 5x5 bingo: row 1 + the FREE row/col partially; row_1 and col_2 closed.
    private var bingo5: (BoardShareContent, [PosterCell]) {
        let done = [5, 6, 7, 8, 9, 2, 12 - 5, 17, 22, 0, 4, 10, 15, 21, 18]
            .filter { $0 != 12 }
        let r = replay(size: 5, done: Array(Set(done)).sorted(), lines: ["row_1": 5, "col_2": 9])
        let c = BoardShareContent(
            kind: .bingo, boardName: "October reset", completedTasks: 13, totalTasks: 25, linesCompleted: 2,
            boardSize: 5, streak: 2, timeframe: .weekly, isCore: true
        )
        return (c, cells(size: 5, replay: r, kind: .bingo))
    }

    private var greenlog5: (BoardShareContent, [PosterCell]) {
        let r = replay(size: 5, done: (0..<25).filter { $0 != 12 })
        let c = BoardShareContent(
            kind: .greenlog, boardName: "October reset", completedTasks: 25, totalTasks: 25, linesCompleted: 12,
            boardSize: 5, streak: 3, timeframe: .weekly, isCore: true
        )
        return (c, cells(size: 5, replay: r, kind: .greenlog))
    }

    private func smallBingo(size: Int) -> (BoardShareContent, [PosterCell]) {
        let n = size * size
        let done = Array(0..<size) + [size + 1, n - 1]
        let r = replay(size: size, done: Array(Set(done)).filter { $0 != r_free(size) }.sorted(), lines: ["row_0": size])
        let c = BoardShareContent(
            kind: .bingo, boardName: "Tiny board", completedTasks: r.completedTasks, totalTasks: n,
            linesCompleted: 1, boardSize: size
        )
        return (c, cells(size: size, replay: r, kind: .bingo))
    }

    private func r_free(_ size: Int) -> Int { size % 2 == 1 ? (size / 2) * size + size / 2 : -1 }

    // MARK: - Full sheet

    func testBingoSheetLight() {
        assertSnapshot(of: sheetHost(bingo5), as: .image(layout: .fixed(width: 393, height: 820)), record: recordMode)
    }

    func testBingoSheetDark() {
        assertSnapshot(
            of: sheetHost(bingo5),
            as: .image(layout: .fixed(width: 393, height: 820), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }

    func testGreenlogSheetLight() {
        assertSnapshot(of: sheetHost(greenlog5), as: .image(layout: .fixed(width: 393, height: 820)), record: recordMode)
    }

    func testGreenlogSheetDark() {
        assertSnapshot(
            of: sheetHost(greenlog5),
            as: .image(layout: .fixed(width: 393, height: 820), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }

    // MARK: - Poster (the raster target)

    func testPosterBingoNamesOn() {
        assertSnapshot(of: posterHost(bingo5, names: true), as: posterLayout, record: recordMode)
    }

    func testPosterBingoNamesOff() {
        assertSnapshot(of: posterHost(bingo5, names: false), as: posterLayout, record: recordMode)
    }

    func testPosterGreenlog() {
        assertSnapshot(of: posterHost(greenlog5, names: true), as: posterLayout, record: recordMode)
    }

    func testPoster3x3() {
        assertSnapshot(of: posterHost(smallBingo(size: 3), names: true), as: posterLayout, record: recordMode)
    }

    func testPoster4x4() {
        assertSnapshot(of: posterHost(smallBingo(size: 4), names: true), as: posterLayout, record: recordMode)
    }

    /// The export is dark-proof: a dark-mode host renders the same poster.
    func testPosterBingoDarkHost() {
        assertSnapshot(
            of: posterHost(bingo5, names: true),
            as: .image(layout: .fixed(width: 300, height: 480), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }

    // MARK: - Helpers

    private var posterLayout: Snapshotting<AnyView, UIImage> {
        .image(layout: .fixed(width: 300, height: 480))
    }

    private func sheetHost(_ s: (BoardShareContent, [PosterCell])) -> some View {
        ShareBoardSheet(content: s.0, cells: s.1, boardId: "board-abc-123-def")
            .frame(maxWidth: .infinity)
            .background(Color.risoPaper)
    }

    private func posterHost(_ s: (BoardShareContent, [PosterCell]), names: Bool) -> AnyView {
        AnyView(
            ZStack {
                Color.gray.opacity(0.25).ignoresSafeArea()
                ShareStoryPoster(content: s.0, cells: s.1, showTaskNames: names)
            }
        )
    }
}
