import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for `RisoRangeSlider` — the two-handle control that
/// sets how many tasks a pulled pool/board contributes.
///
/// Added after an owner report (2026-09-17) that the knobs' hard shadows
/// rendered SQUARE: `risoHardShadow(_:)` draws a `RoundedRectangle` at
/// `Riso.cardRadius`, so passing only an offset left a card-radius rect
/// behind a 22pt circle. The control had no snapshot coverage at all,
/// which is why it shipped unseen. These baselines pin the knob silhouette
/// in both schemes.
final class RisoRangeSliderSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    /// Slider states worth pinning: a mid-range window (both knobs inboard,
    /// away from the track ends where clipping could hide a bad shadow), a
    /// "use all" open-ended max, and a small-N slider whose label stops are
    /// dense.
    private func gallery() -> some View {
        VStack(alignment: .leading, spacing: 28) {
            RisoRangeSlider(available: 20, minValue: 6, maxValue: 13, onChange: { _, _ in })
            RisoRangeSlider(available: 20, minValue: 4, maxValue: nil, onChange: { _, _ in })
            RisoRangeSlider(available: 6, minValue: 2, maxValue: 5, onChange: { _, _ in })
        }
        .padding(20)
        .background(Color.risoPaper)
    }

    func testRangeSliderLight() {
        assertSnapshot(
            of: gallery().environment(\.colorScheme, .light),
            as: .image(layout: .fixed(width: 393, height: 320)),
            record: recordMode
        )
    }

    func testRangeSliderDark() {
        assertSnapshot(
            of: gallery().environment(\.colorScheme, .dark),
            as: .image(layout: .fixed(width: 393, height: 320)),
            record: recordMode
        )
    }
}
