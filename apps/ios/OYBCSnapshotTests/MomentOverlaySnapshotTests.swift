import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the Bingo / Greenlog moment overlay (handoff §5a/b/e/f).
/// The overlay is rendered at pinned beats via its `beatOverride` seam (no
/// clock, no motion), so each frame is deterministic: the END state of a
/// bingo (5×5 light + dark, 3×3, 4×4), the end state of a greenlog with and
/// without the streak chip, plus one MID-replay frame of each kind.
final class MomentOverlaySnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - Fixtures

    private struct Face {
        var title: String
        var type: CellTaskType = .normal
        var done = false
        var cur: CountValue = 0
        var max: CountValue = 0
        var sub: (done: Int, total: Int) = (0, 0)
    }

    private func input(_ idx: Int, _ f: Face) -> MomentCellInput {
        MomentCellInput(
            idx: idx, title: f.title, taskType: f.type, endCompleted: f.done,
            currentCount: f.cur, maxCount: f.max,
            compoundDoneCount: f.sub.done, compoundChildCount: f.sub.total, compoundRequiredCount: f.sub.total
        )
    }

    /// The handoff's 5×5 (Weekly habits): 13 squares done + FREE; row 2 and
    /// column 3 complete. Column 3 closes at beat 10, row 2 at beat 14.
    private func bingo5x5() -> MomentPresentation {
        func n(_ t: String, _ d: Bool = false) -> Face { Face(title: t, done: d) }
        func c(_ t: String, _ cur: CountValue, _ max: CountValue) -> Face {
            Face(title: t, type: .counting, done: cur >= max, cur: cur, max: max)
        }
        func k(_ t: String) -> Face { Face(title: t, type: .compound, sub: (1, 3)) }
        let faces: [Face?] = [
            n("Run 5k", true), c("Read 20 pages", 12, 20), n("Call mom", true), n("Meditate", true), n("Cook dinner"),
            c("Drink 8 glasses", 8, 8), n("No sugar", true), n("Stretch", true), n("Journal", true), n("Inbox zero", true),
            c("Walk 10k steps", 6, 10), n("Floss", true), nil, n("Lift weights"), n("Budget review"),
            n("Sleep by 11", true), k("Language lesson"), n("Water plants", true), c("Write 500 words", 180, 500), n("Tidy desk", true),
            n("Bike to work"), k("Learn a song"), n("Early rise", true), n("Screen-free hour"), n("Call a friend"),
        ]
        // Completion order: five singles, then column 3's squares, then row 2's.
        let order = [0, 3, 11, 15, 19, 7, 2, 17, 22, 5, 6, 8, 9]
        let replay = BoardMomentReplay(
            order: order.map { MomentOrderEntry(boardTaskId: "bt\($0)", idx: $0, completedAt: nil) },
            freeIdx: 12, lineClosureBeat: ["col_2": 10, "row_1": 14],
            completedTasks: 13, totalTasks: 25, size: 5
        )
        let cells = faces.enumerated().map { i, f in f.map { input(i, $0) } ?? MomentCellInput(idx: i, slot: .free) }
        return MomentPresentation(kind: .bingo, replay: replay, cells: cells)
    }

    /// A small bingo board (3×3 with FREE, or 4×4 without): the first row
    /// complete; the rest undone.
    private func smallBingo(size: Int) -> MomentPresentation {
        let titles = ["Run 5k", "Read 20 pages", "Call mom", "Meditate", "Cook dinner", "No sugar", "Stretch", "Journal",
                      "Inbox zero", "Floss", "Lift weights", "Tidy desk", "Budget review", "Water plants", "Early rise", "Sleep by 11"]
        let hasFree = size % 2 == 1
        let freeIdx = hasFree ? (size / 2) * size + size / 2 : nil
        var t = titles.makeIterator()
        let done = Set(0..<size)
        var cells: [MomentCellInput] = []
        for i in 0..<(size * size) {
            if i == freeIdx { cells.append(MomentCellInput(idx: i, slot: .free)); continue }
            let isCounting = i == 1
            cells.append(MomentCellInput(
                idx: i, title: t.next() ?? "Task", taskType: isCounting ? .counting : .normal,
                endCompleted: done.contains(i), currentCount: isCounting ? 20 : 0, maxCount: isCounting ? 20 : 0
            ))
        }
        let replay = BoardMomentReplay(
            order: (0..<size).map { MomentOrderEntry(boardTaskId: "bt\($0)", idx: $0, completedAt: nil) },
            freeIdx: freeIdx, lineClosureBeat: ["row_0": size + 1],
            completedTasks: size, totalTasks: size * size, size: size
        )
        return MomentPresentation(kind: .bingo, replay: replay, cells: cells)
    }

    private func overlay(
        _ m: MomentPresentation, beat: Int? = nil, lines: Int = 2,
        streak: Int = 0, timeframe: Timeframe = .custom, isCore: Bool = false
    ) -> some View {
        RisoMomentOverlay(
            kind: m.kind, replay: m.replay, cells: m.cells, boardName: "Weekly habits",
            linesCompleted: lines, streak: streak, timeframe: timeframe, isCore: isCore,
            beatOverride: beat ?? momentFinalBeat(m.replay, kind: m.kind)
        )
    }

    private func snap(_ view: some View, dark: Bool = false, name: String = #function) {
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 852),
                traits: dark ? .init(userInterfaceStyle: .dark) : .init()
            ),
            record: recordMode, testName: name
        )
    }

    // MARK: - Bingo

    func testBingo5x5EndLight() { snap(overlay(bingo5x5())) }
    func testBingo5x5EndDark() { snap(overlay(bingo5x5()), dark: true) }
    func testBingo3x3End() { snap(overlay(smallBingo(size: 3), lines: 1)) }
    func testBingo4x4End() { snap(overlay(smallBingo(size: 4), lines: 1)) }
    /// Beat 10: column 3 has just flipped green; row 2 still closing.
    func testBingo5x5MidReplay() { snap(overlay(bingo5x5(), beat: 10, lines: 1)) }

    // MARK: - Greenlog

    func testGreenlog5x5ChipLight() {
        snap(overlay(.greenlogSample, lines: 12, streak: 3, timeframe: .weekly, isCore: true))
    }
    func testGreenlog5x5ChipDark() {
        snap(overlay(.greenlogSample, lines: 12, streak: 3, timeframe: .weekly, isCore: true), dark: true)
    }
    func testGreenlog5x5NoChip() { snap(overlay(.greenlogSample, lines: 12)) }
    /// Beat 28 = 24 landed + 3: the first four sweep bands (r + c ≤ 2) are green.
    func testGreenlog5x5MidSweep() {
        snap(overlay(.greenlogSample, beat: 28, lines: 12, streak: 3, timeframe: .weekly, isCore: true))
    }

    // MARK: - Cell states

    func testCellLineGreenStates() {
        let cells: [AnyView] = [
            AnyView(RisoBoardPlayCell(title: "Run 5k", taskType: .normal, isCompleted: true, isLineGreen: true)),
            AnyView(RisoBoardPlayCell(title: "Read 20", taskType: .counting, isCompleted: true, currentCount: 20, maxCount: 20, isLineGreen: true)),
            AnyView(RisoBoardPlayCell(title: "FREE", taskType: .normal, isCompleted: false, isCenter: true, isLineGreen: true)),
            AnyView(RisoBoardPlayCell(title: "FREE", taskType: .normal, isCompleted: false, isCenter: true)),
        ]
        let view = ZStack {
            RisoPaperBackground()
            HStack(spacing: 7) { ForEach(0..<cells.count, id: \.self) { cells[$0] } }.padding(Riso.gutter)
        }
        assertSnapshot(of: view, as: .image(layout: .fixed(width: 393, height: 120)), record: recordMode)
    }
}
