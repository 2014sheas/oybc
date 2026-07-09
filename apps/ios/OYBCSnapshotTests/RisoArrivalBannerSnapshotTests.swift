import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot tests for `RisoArrivalBanner` (Shared Counters P3) — renders the
/// REAL gold arrival banner, both copy variants, in light + dark.
///
/// The banner is static (no animation state), so the render is deterministic.
/// The square pulse (`ArrivePulseModifier`) is a separate, time-driven modifier
/// and is intentionally NOT snapshotted here.
///
/// Variants (light + dark each):
///   1. Single — "*{task}* filled in here from your {counter} counter …"
///   2. Multiple — "**N squares** filled in from your counters …"
final class RisoArrivalBannerSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    private func container(_ banner: RisoArrivalBanner) -> some View {
        banner
            .padding(.horizontal, 16)
            .padding(.vertical, 40)
            .frame(width: 393)
            .background(Color.risoPaper)
    }

    private func singleView() -> some View {
        container(RisoArrivalBanner(
            squareCount: 1,
            taskName: "50 push-ups",
            counterName: "Push-ups",
            onOpen: {},
            onDismiss: {}
        ))
    }

    private func multipleView() -> some View {
        container(RisoArrivalBanner(
            squareCount: 3,
            taskName: nil,
            counterName: nil,
            onOpen: {},
            onDismiss: {}
        ))
    }

    // MARK: - Single

    func testSingleLight() {
        assertSnapshot(of: singleView(), as: .image(layout: .fixed(width: 393, height: 150)), record: recordMode)
    }

    func testSingleDark() {
        assertSnapshot(of: singleView(), as: .image(layout: .fixed(width: 393, height: 150), traits: .init(userInterfaceStyle: .dark)), record: recordMode)
    }

    // MARK: - Multiple

    func testMultipleLight() {
        assertSnapshot(of: multipleView(), as: .image(layout: .fixed(width: 393, height: 130)), record: recordMode)
    }

    func testMultipleDark() {
        assertSnapshot(of: multipleView(), as: .image(layout: .fixed(width: 393, height: 130), traits: .init(userInterfaceStyle: .dark)), record: recordMode)
    }
}
