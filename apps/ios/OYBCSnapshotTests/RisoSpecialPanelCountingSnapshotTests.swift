import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

final class RisoSpecialPanelCountingSnapshotTests: XCTestCase {
    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    private func panel(_ seed: RisoSpecialTaskPanel.CountingSeed, pool: [OYBC.Task]? = nil) -> some View {
        RisoSpecialTaskPanel(
            userId: "u1", defaultStartDate: nil, defaultEndDate: nil,
            suggestionPool: pool,
            onTaskCreated: { _, _, _ in }, onCompoundCreated: { _ in }, onPendingCreated: nil,
            onLibraryReloadRequested: {}, countingSeed: seed
        )
        .padding(16)
        .background(Color.risoPaper)
    }

    /// A Continuous root the typed (Run, miles) pair auto-links to.
    private var continuousRoot: OYBC.Task {
        var root = SnapshotFixtures.makeTask(
            id: "t-run-root", title: "Run 26.2 miles", type: .counting,
            action: "Run", unit: "miles", maxCount: 26.2
        )
        root.countKind = .continuous
        root.currentCount = 148.6
        return root
    }

    func testContinuousLight() { snap(.init(action: "Run", goal: "26.2", unit: "miles", kind: .continuous), dark: false) }
    func testContinuousDark() { snap(.init(action: "Run", goal: "26.2", unit: "miles", kind: .continuous), dark: true) }
    func testDurationLight() { snap(.init(action: "Practice", goal: "10h 30m", unit: "", kind: .duration), dark: false) }
    func testDiscreteLight() { snap(.init(action: "Read", goal: "300", unit: "pages", kind: .discrete), dark: false) }

    /// Auto-linked: the picker's last kind is Discrete, the root is Continuous —
    /// the Kind row is the root's tag, never a picker.
    func testLinkedTagLight() {
        snap(.init(action: "Run", goal: "6.2", unit: "miles", kind: .discrete), dark: false, pool: [continuousRoot], height: 560)
    }
    func testLinkedTagDark() {
        snap(.init(action: "Run", goal: "6.2", unit: "miles", kind: .discrete), dark: true, pool: [continuousRoot], height: 560)
    }

    private func snap(_ seed: RisoSpecialTaskPanel.CountingSeed, dark: Bool, pool: [OYBC.Task]? = nil, height: CGFloat = 460,
                      file: StaticString = #file, testName: String = #function, line: UInt = #line) {
        assertSnapshot(of: panel(seed, pool: pool), as: .image(layout: .fixed(width: 393, height: height), traits: .init(userInterfaceStyle: dark ? .dark : .light)),
                       record: recordMode, file: file, testName: testName, line: line)
    }
}
