import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

final class RisoSpecialPanelCountingSnapshotTests: XCTestCase {
    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    private func panel(_ seed: RisoSpecialTaskPanel.CountingSeed) -> some View {
        RisoSpecialTaskPanel(
            userId: "u1", defaultStartDate: nil, defaultEndDate: nil,
            onTaskCreated: { _, _, _ in }, onCompoundCreated: { _ in }, onPendingCreated: nil,
            onLibraryReloadRequested: {}, countingSeed: seed
        )
        .padding(16)
        .background(Color.risoPaper)
    }

    func testContinuousLight() { snap(.init(action: "Run", goal: "26.2", unit: "miles", kind: .continuous), dark: false) }
    func testContinuousDark() { snap(.init(action: "Run", goal: "26.2", unit: "miles", kind: .continuous), dark: true) }
    func testDurationLight() { snap(.init(action: "Practice", goal: "10h 30m", unit: "", kind: .duration), dark: false) }
    func testDiscreteLight() { snap(.init(action: "Read", goal: "300", unit: "pages", kind: .discrete), dark: false) }

    private func snap(_ seed: RisoSpecialTaskPanel.CountingSeed, dark: Bool, file: StaticString = #file, testName: String = #function, line: UInt = #line) {
        assertSnapshot(of: panel(seed), as: .image(layout: .fixed(width: 393, height: 460), traits: .init(userInterfaceStyle: dark ? .dark : .light)),
                       record: recordMode, file: file, testName: testName, line: line)
    }
}
