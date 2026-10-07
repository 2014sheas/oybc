import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot tests for `KindSwitchConfirmView` — the Continuous → Discrete
/// confirm (handoff "Switch confirm", iOS frame), light + dark.
final class KindSwitchConfirmSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    private func view() -> some View {
        let p = KindSwitchPreview(from: .continuous, to: .discrete, titleBefore: "Run 26.2 miles", titleAfter: "Run 26 miles",
                                  loggedBefore: 12.75, loggedAfter: 13, linkedCount: 2)
        return KindSwitchConfirmView(preview: p, onCancel: {}, onConfirm: {})
    }

    func testConfirmLight() {
        assertSnapshot(of: view(), as: .image(layout: .fixed(width: 393, height: 320)), record: recordMode)
    }

    func testConfirmDark() {
        assertSnapshot(of: view(), as: .image(layout: .fixed(width: 393, height: 320), traits: .init(userInterfaceStyle: .dark)), record: recordMode)
    }
}
