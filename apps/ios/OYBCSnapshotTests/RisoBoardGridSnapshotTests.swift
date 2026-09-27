import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Board Edit redesign slice 1 — the shared board grid (`RisoBoardGrid` +
/// `RisoBoardPlayCell`) with the slice-1 corner chips: a 3×3 with a locked
/// square, a locked square that also carries a staged edit, a plain staged
/// edit, the FREE center, a counting and a compound cell, light and dark.
final class RisoBoardGridSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    func testGridWithChipsLight() {
        assertSnapshot(
            of: makeGrid(),
            as: .image(layout: .fixed(width: 393, height: 420)),
            record: recordMode
        )
    }

    func testGridWithChipsDark() {
        assertSnapshot(
            of: makeGrid(),
            as: .image(
                layout: .fixed(width: 393, height: 420),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    private func makeGrid() -> some View {
        ZStack {
            Color.risoPaper.ignoresSafeArea()
            RisoBoardGrid(gridSize: 3) { row, col, index in
                switch index {
                case 0:
                    RisoBoardPlayCell(title: "Morning workout", taskType: .normal, isCompleted: false, showsLockChip: true)
                case 1:
                    RisoBoardPlayCell(title: "Cook a meal", taskType: .normal, isCompleted: true)
                case 2:
                    RisoBoardPlayCell(title: "Call a friend", taskType: .normal, isCompleted: false, showsDirtyChip: true)
                case 3:
                    RisoBoardPlayCell(title: "Read 50 pages", taskType: .counting, isCompleted: false,
                                      showsLockChip: true, showsDirtyChip: true, currentCount: 20, maxCount: 50)
                case 4:
                    RisoBoardPlayCell(title: "FREE", taskType: .normal, isCompleted: false, isCenter: true)
                case 5:
                    RisoBoardPlayCell(title: "Write in journal", taskType: .normal, isCompleted: false)
                case 6:
                    RisoBoardPlayCell(title: "Weekend reset", taskType: .compound, isCompleted: false,
                                      compoundDoneCount: 1, compoundChildCount: 3)
                case 7:
                    RisoBoardPlayCell(title: "Stretch", taskType: .normal, isCompleted: true, showsLockChip: true)
                default:
                    RisoBoardPlayCell(title: "Drink 8 glasses", taskType: .counting, isCompleted: true,
                                      currentCount: 8, maxCount: 8)
                }
            }
            .padding(Riso.gutter)
        }
    }
}
