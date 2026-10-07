import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// `RisoCountingStepperSheet` per counter kind (docs/COUNTER_KINDS.md §5,
/// handoff B1 `LogSheet` iOS frames). The sheet draws no progress bar, so the
/// overshoot case shows the real value only (Ruling U5).
final class CountingStepperSheetSnapshotTests: XCTestCase {
    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    private func sheet(_ kind: CountKind, title: String, unit: String, cur: CountValue, max: CountValue, shared: Bool, defaultAmount: CountValue?) -> some View {
        RisoCountingStepperSheet(taskTitle: title, currentCount: cur, maxCount: max, unitText: unit, countKind: kind,
                                 isLinkedCounter: false, isSharedCounter: shared, defaultLogAmount: defaultAmount, onOpenTask: {})
            .background(Color.risoPaper)
    }

    private func snap(_ v: some View, h: CGFloat, dark: Bool = false, testName: String = #function, line: UInt = #line) {
        assertSnapshot(of: v, as: .image(layout: .fixed(width: 393, height: h), traits: .init(userInterfaceStyle: dark ? .dark : .light)),
                       record: recordMode, testName: testName, line: line)
    }

    func testDiscreteSharedLight() { snap(sheet(.discrete, title: "Do 200 push-ups", unit: "push-ups", cur: 132, max: 200, shared: true, defaultAmount: 10), h: 400) }
    func testContinuousCustomLight() { snap(sheet(.continuous, title: "Run 26.2 mi", unit: "mi", cur: 12.4, max: 26.2, shared: false, defaultAmount: 3.1), h: 420) }
    func testContinuousCustomDark() { snap(sheet(.continuous, title: "Run 26.2 mi", unit: "mi", cur: 12.4, max: 26.2, shared: false, defaultAmount: 3.1), h: 420, dark: true) }
    func testDurationQuarterLight() { snap(sheet(.duration, title: "Practice 10h 30m", unit: "", cur: 270, max: 630, shared: false, defaultAmount: nil), h: 560) }
    func testDurationQuarterDark() { snap(sheet(.duration, title: "Practice 10h 30m", unit: "", cur: 270, max: 630, shared: false, defaultAmount: nil), h: 560, dark: true) }
    func testOvershootLight() { snap(sheet(.continuous, title: "Run 26.2 mi", unit: "mi", cur: 28.4, max: 26.2, shared: false, defaultAmount: 3.1), h: 420) }
}
