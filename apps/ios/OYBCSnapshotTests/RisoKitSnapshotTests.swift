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

    // MARK: - RisoSegmented — pill style (P2 Task 3)
    //
    // Additive `style: .pill` on the existing `RisoSegmented` (default
    // `.card`, unchanged — covered by `testKitLight`/`testKitDark` above,
    // which render the gallery's existing card-style segmented sections).
    // Guards the new capsule-container / ink-active-fill rendering path.

    private func pillSegmented() -> some View {
        PillSegmentedPreview()
            .padding(16)
            .background(Color.risoPaper)
            .frame(width: 353, height: 70)
    }

    func testPillSegmentedLight() {
        assertSnapshot(
            of: pillSegmented(),
            as: .image(layout: .fixed(width: 353, height: 70)),
            record: recordMode
        )
    }

    func testPillSegmentedDark() {
        assertSnapshot(
            of: pillSegmented(),
            as: .image(layout: .fixed(width: 353, height: 70), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }
}

/// Thin `@State` wrapper so `RisoSegmented`'s pill style renders with a
/// valid `Binding` in a snapshot context (mirrors `RisoKitGallery`'s
/// `@State private var seg` for the card-style example above it).
private struct PillSegmentedPreview: View {
    @State private var value: String = "pools"

    var body: some View {
        RisoSegmented(
            options: [("library", "Library"), ("pools", "Pools · 2")],
            selection: $value,
            style: .pill
        )
    }
}
