import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Counter kinds handoff C1 — the board cell's per-kind count: the ×goal tag,
/// the `cur/max` → `cur` → fill-only bar tiers and the gold overshoot fill.
/// Worst cases at 3×3 (113pt), 4×4 (83pt), 5×5 (65pt) on a 393pt phone.
final class RisoBoardCellKindsSnapshotTests: XCTestCase {
    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    private struct Worst {
        let title: String
        let kind: CountKind
        let cur: CountValue
        let max: CountValue
        var done = false
        var shared = false
    }

    private let worst: [Worst] = [
        .init(title: "Run 26.2 mi", kind: .continuous, cur: 12.75, max: 26.2),
        .init(title: "Swim 1000 m", kind: .continuous, cur: 128.5, max: 1000),
        .init(title: "Practice 10h", kind: .duration, cur: 270, max: 600),
        .init(title: "Code 500h", kind: .duration, cur: 6735, max: 30000),
        .init(title: "Run 26.2 mi", kind: .continuous, cur: 28.4, max: 26.2, done: true),
        .init(title: "Read 300 pages", kind: .discrete, cur: 120, max: 300, shared: true),
    ]

    private func grid(_ n: Int, cell: CGFloat) -> some View {
        let total = n * n
        let worst = self.worst
        return LazyVGrid(columns: Array(repeating: GridItem(.fixed(cell), spacing: 6), count: n), spacing: 6) {
            ForEach(0..<total, id: \.self) { i in
                if i == total / 2 {
                    RisoBoardPlayCell(title: "FREE", taskType: .normal, isCompleted: false, isCenter: true)
                } else {
                    let w = worst[i % worst.count]
                    RisoBoardPlayCell(title: w.title, taskType: .counting, isCompleted: w.done,
                                      currentCount: w.cur, maxCount: w.max, countKind: w.kind, isSharedCounter: w.shared)
                }
            }
        }
        .frame(width: CGFloat(n) * cell + CGFloat(n - 1) * 6)
        .padding(12)
        .background(Color.risoPaper)
    }

    private func snap(_ n: Int, _ cell: CGFloat, dark: Bool, testName: String = #function, line: UInt = #line) {
        let side = CGFloat(n) * cell + CGFloat(n - 1) * 6 + 24
        assertSnapshot(
            of: grid(n, cell: cell),
            as: .image(layout: .fixed(width: side, height: side),
                       traits: .init(userInterfaceStyle: dark ? .dark : .light)),
            record: recordMode, testName: testName, line: line
        )
    }

    func testGrid3Light() { snap(3, 113, dark: false) }
    func testGrid3Dark() { snap(3, 113, dark: true) }
    func testGrid4Light() { snap(4, 83, dark: false) }
    func testGrid4Dark() { snap(4, 83, dark: true) }
    func testGrid5Light() { snap(5, 65, dark: false) }
    func testGrid5Dark() { snap(5, 65, dark: true) }
}
