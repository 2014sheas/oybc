import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot tests for `RisoExistingTaskPickerSheet` — the compound editor's
/// "+ Existing task…" sheet (Compound Task Editing, Task 7): Riso search bar
/// + one row per eligible task (type letter badge + title).
///
/// Rendered at iPhone 16 width (393pt); iOS-version pinning is enforced at the
/// scheme level (see CLAUDE.md → Snapshot Testing).
final class RisoExistingTaskPickerSheetSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    /// A mixed eligible list — normal, counting and a nested compound.
    private func candidates() -> [Task] {
        [
            SnapshotFixtures.makeTask(id: "p-1", title: "Journal", type: .normal),
            SnapshotFixtures.makeTask(id: "p-2", title: "Run 5 km", type: .counting, action: "Run", unit: "km", maxCount: 5),
            SnapshotFixtures.makeTask(id: "p-3", title: "Stretch routine", type: .compound, operatorType: .and),
            SnapshotFixtures.makeTask(id: "p-4", title: "Water the plants", type: .normal),
        ]
    }

    private func sheet(dark: Bool) -> some View {
        RisoExistingTaskPickerSheet(tasks: candidates(), onPick: { _ in }, onCancel: {})
            .environment(\.colorScheme, dark ? .dark : .light)
    }

    func testPickerLight() {
        assertSnapshot(
            of: sheet(dark: false),
            as: .image(layout: .fixed(width: 393, height: 520)),
            record: recordMode
        )
    }

    func testPickerDark() {
        assertSnapshot(
            of: sheet(dark: true),
            as: .image(layout: .fixed(width: 393, height: 520), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }
}
