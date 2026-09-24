import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot tests for the task-detail "Linked to <source>" caption
/// (`LinkedCounterCaptionLabel`, the pixels of `LinkedCounterCaptionView`).
/// Locks its move from system colours/fonts onto the Riso tokens
/// (`risoBody` + `risoMuted`/`risoInk`).
///
/// The caption's source comes from the shared-counter family fixture: the
/// derived member links to the root, so the caption names the root's title.
/// The not-found line is what a member whose root is gone shows.
///
/// Variants (light + dark each): linked, source not found.
final class LinkedCounterCaptionSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing
    private let size = SwiftUISnapshotLayout.fixed(width: 393, height: 56)

    /// The caption as `RisoTaskDetailContentView` would show it for the
    /// family's member, on the paper ground the detail surface uses.
    private func captionView(sourceFound: Bool) -> some View {
        let family = SnapshotFixtures.counterFamily()
        precondition(family.member.sharedCounterId == family.root.id)
        return LinkedCounterCaptionLabel(sourceTitle: sourceFound ? family.root.title : nil)
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

    func testSourceNotFoundLight() {
        assertSnapshot(of: captionView(sourceFound: false), as: .image(layout: size), record: recordMode)
    }

    func testSourceNotFoundDark() {
        assertSnapshot(of: captionView(sourceFound: false), as: .image(layout: size, traits: .init(userInterfaceStyle: .dark)), record: recordMode)
    }
}
