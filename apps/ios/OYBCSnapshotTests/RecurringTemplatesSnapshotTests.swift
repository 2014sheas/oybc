import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for Phase 6.2's net-new visual surfaces:
///   - `RecurringTemplatesSectionView` — empty state + populated list
///     (active + paused) + populated list with attention badge
///
/// `RecurringTemplateFormView` is not snapshotted because it's
/// `@State`-driven (form fields, sheet presentation) which would require
/// deterministic State seeding — out of scope for the passive snapshot
/// surface. Visual regressions on the form should be caught by manual
/// QA per CLAUDE.md's relay-to-user convention.
///
/// Fixtures use `Timeframe.monthly` rather than `.daily` so the
/// suggested-name window labels (which travel up to the row meta line)
/// stay stable across days. Lesson from 6.1d's Jan-1 rendering issue.
final class RecurringTemplatesSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    /// Empty-state copy: section heading + dashed empty-state pill.
    func testSectionEmpty() {
        let view = RecurringTemplatesSectionView(
            userId: SnapshotFixtures.userId,
            templates: [],
            libraryTasks: [],
            attentionByTemplateId: [:],
            onTemplatesChanged: {}
        )
        .padding()
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 200)),
            record: recordMode
        )
    }

    /// Populated list with one active + one paused template. Tests the
    /// row-level styling difference (paused = 0.7 opacity).
    func testSectionPopulatedActiveAndPaused() {
        let templates = [
            SnapshotFixtures.makeRecurringTemplate(
                id: "tpl-1",
                name: "Daily Workout",
                timeframe: .monthly,
                boardSize: 5,
                isActive: true
            ),
            SnapshotFixtures.makeRecurringTemplate(
                id: "tpl-2",
                name: "Weekly Reading",
                timeframe: .monthly,
                boardSize: 5,
                poolStrategy: .randomSubset,
                isActive: false
            ),
        ]
        let view = RecurringTemplatesSectionView(
            userId: SnapshotFixtures.userId,
            templates: templates,
            libraryTasks: [],
            attentionByTemplateId: [:],
            onTemplatesChanged: {}
        )
        .padding()
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 320)),
            record: recordMode
        )
    }

    /// Row with an attention badge — surfaces when a seed task in the
    /// pool was deleted (or any other validation failure). Renders the
    /// orange exclamation row + copy.
    func testSectionPopulatedWithAttention() {
        let template = SnapshotFixtures.makeRecurringTemplate(
            id: "tpl-needs-attention",
            name: "Goals With Issue",
            timeframe: .monthly,
            isActive: true
        )
        let view = RecurringTemplatesSectionView(
            userId: SnapshotFixtures.userId,
            templates: [template],
            libraryTasks: [],
            attentionByTemplateId: [template.id: .hasDeletedTasks],
            onTemplatesChanged: {}
        )
        .padding()
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 240)),
            record: recordMode
        )
    }
}
