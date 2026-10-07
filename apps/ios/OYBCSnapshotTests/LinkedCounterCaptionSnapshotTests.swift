import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot tests for the task-detail counter-root row
/// (`LinkedCounterCaptionLabel`, the pixels of `LinkedCounterCaptionView`).
///
/// The row's source comes from the shared-counter family fixture: the
/// derived member links to the root, so the row names the root's title and
/// its lifetime total — no "Linked to" caption (#548 rows 91/92). A member
/// whose root is gone renders nothing: that frame must be blank paper.
///
/// Variants (light + dark each): linked, source not found (renders nothing).
final class LinkedCounterCaptionSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing
    private let size = SwiftUISnapshotLayout.fixed(width: 393, height: 84)
    private let emptySize = SwiftUISnapshotLayout.fixed(width: 393, height: 60)

    /// The row as `RisoTaskDetailContentView` would show it for the
    /// family's member, on the paper ground the detail surface uses.
    private func captionView(sourceFound: Bool) -> some View {
        let family = SnapshotFixtures.counterFamily()
        precondition(family.member.sharedCounterId == family.root.id)
        return LinkedCounterCaptionLabel(source: sourceFound
            ? LinkedCounterSource(title: family.root.title, lifetime: 512, unit: "reps", kind: .discrete) : nil)
            .padding(Riso.gutter)
            .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .leading)
            .background(Color.risoPaper)
    }

    func testLinkedLight() {
        assertSnapshot(of: captionView(sourceFound: true), as: .image(layout: size), record: recordMode)
    }

    func testLinkedDark() {
        assertSnapshot(of: captionView(sourceFound: true), as: .image(layout: size, traits: .init(userInterfaceStyle: .dark)), record: recordMode)
    }

    func testSourceNotFoundRendersNothingLight() {
        assertSnapshot(of: captionView(sourceFound: false), as: .image(layout: emptySize), record: recordMode)
    }

    func testSourceNotFoundRendersNothingDark() {
        assertSnapshot(of: captionView(sourceFound: false), as: .image(layout: emptySize, traits: .init(userInterfaceStyle: .dark)), record: recordMode)
    }
}
