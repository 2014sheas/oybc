import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the Riso design-system foundation (Phase 0).
/// Renders the full primitive gallery in both "day press" (light) and
/// "night press" (dark) so token/appearance regressions are caught before
/// any screen consumes the kit. iOS-version pinning is at the scheme level
/// (see CLAUDE.md → Snapshot Testing).
final class RisoKitSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    func testKitLight() {
        assertSnapshot(
            of: RisoKitGallery(),
            as: .image(layout: .fixed(width: 393, height: 1340)),
            record: recordMode
        )
    }

    func testKitDark() {
        assertSnapshot(
            of: RisoKitGallery(),
            as: .image(
                layout: .fixed(width: 393, height: 1340),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }
}
