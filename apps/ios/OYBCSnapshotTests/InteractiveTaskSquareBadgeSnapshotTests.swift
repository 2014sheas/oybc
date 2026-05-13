import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Phase 6.3 — Snapshot coverage for the achievement-task badge
/// variants rendered by `InteractiveTaskSquareView`. The plain (no
/// badge) and per-task-type variants are already covered indirectly
/// by `BoardWizardStepsSnapshotTests/testPreviewStepReady`; this file
/// pins the badge-only-state surfaces so a change to the 🎯 pill
/// styling or label format is caught visibly.
///
/// Layout-wise the badge sits in the top-left slot that the "C"
/// compound badge previously owned; the compound branch is
/// suppressed when both apply (see `InteractiveTaskSquareView.swift`).
/// The compound+badge case below exercises that priority rule.
final class InteractiveTaskSquareBadgeSnapshotTests: XCTestCase {

    /// Auto-record missing baselines; the env var SNAPSHOT_TESTING_RECORD=never
    /// (set in CI by ios.yml) overrides this to enforce strict-match.
    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    func testBadge_SpecificBoardCompleted() {
        let view = renderCell(
            title: "Q1 launch goals",
            taskType: .normal,
            isCompleted: false,
            badge: AchievementSquareBadgeData(
                mode: .specificBoard,
                referencedBoardName: "Daily Wellness",
                referencedBoardCompleted: true
            )
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 120, height: 120)),
            record: recordMode
        )
    }

    func testBadge_RecurringTemplate() {
        let view = renderCell(
            title: "Monthly fitness",
            taskType: .normal,
            isCompleted: false,
            badge: AchievementSquareBadgeData(
                mode: .recurringTemplate,
                templateName: "Leg Day",
                templateInWindowMet: 2,
                templateRequiredCount: 4
            )
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 120, height: 120)),
            record: recordMode
        )
    }

    /// Compound task with an achievement badge. Verifies the "C" badge
    /// is suppressed (achievement-task priority rule in
    /// InteractiveTaskSquareView.swift). Without that rule the top-left
    /// slot would render both badges stacked. Post-refactor: aggregate
    /// mode is gone, so this case uses a specific-board reference.
    func testBadge_CompoundTask_SuppressesCBadge() {
        let view = renderCell(
            title: "Weekly habits",
            taskType: .compound,
            isCompleted: false,
            badge: AchievementSquareBadgeData(
                mode: .specificBoard,
                referencedBoardName: "Quarterly OKRs",
                referencedBoardCompleted: false
            ),
            compoundChildCount: 4,
            compoundDoneCount: 1,
            compoundOperator: .and
        )
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 120, height: 120)),
            record: recordMode
        )
    }

    // MARK: - Builder

    private func renderCell(
        title: String,
        taskType: TaskType,
        isCompleted: Bool,
        badge: AchievementSquareBadgeData?,
        compoundChildCount: Int = 0,
        compoundDoneCount: Int = 0,
        compoundOperator: OperatorType? = nil
    ) -> some View {
        // Padding around the 90x90 cell so the badge isn't clipped at
        // the snapshot frame edge — same pattern as BoardWizard cell
        // snapshots that frame the cell with surrounding chrome.
        return InteractiveTaskSquareView(
            title: title,
            taskType: taskType,
            isCompleted: isCompleted,
            compoundOperator: compoundOperator,
            compoundChildCount: compoundChildCount,
            compoundDoneCount: compoundDoneCount,
            achievementBadge: badge
        )
        .padding(15)
        .background(Color(.systemBackground))
    }
}
