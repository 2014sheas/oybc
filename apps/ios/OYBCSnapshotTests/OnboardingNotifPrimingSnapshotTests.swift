import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the notification-priming step of onboarding.
///
/// Targets `NotifPrimingStepView` directly — the pure-props leaf extracted from
/// `OnboardingView` — so no Firebase / AuthService / AppDatabase is needed. The
/// container `OnboardingView` wires the closures; the leaf only renders.
///
/// `record: .missing` auto-records baselines on first run.
/// CI overrides with `SNAPSHOT_TESTING_RECORD=never`.
@MainActor
final class OnboardingNotifPrimingSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - Light mode

    func testNotifPrimingLight() {
        assertSnapshot(
            of: primingView(),
            as: .image(layout: .fixed(width: 393, height: 852)),
            record: recordMode
        )
    }

    // MARK: - Dark mode

    func testNotifPrimingDark() {
        assertSnapshot(
            of: primingView(),
            as: .image(
                layout: .fixed(width: 393, height: 852),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Helpers

    /// Wraps `NotifPrimingStepView` in a `RisoPaperBackground` container so
    /// the full-screen surface renders exactly as it does in `OnboardingView`.
    /// Closures are no-ops — snapshots are purely visual.
    private func primingView() -> some View {
        ZStack {
            RisoPaperBackground()
            NotifPrimingStepView(onTurnOn: {}, onNotNow: {})
        }
    }
}
