import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for OnboardingView — first-run intro slides + sign-in panel.
///
/// Snapshots three surfaces (intro slide 1, intro slide 3, sign-in panel) in
/// light and dark mode. `initialSlide` / `initialShowSignIn` seed the
/// deterministic state so no interactive navigation is needed.
///
/// `record: .missing` auto-records baselines on first run.
/// CI overrides with `SNAPSHOT_TESTING_RECORD=never`.
final class RisoOnboardingSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - Slide 1 (wordmark art, "Welcome to / OYBC")

    func testSlide1Light() {
        let view = onboardingView(initialSlide: 0)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 852)),
            record: recordMode
        )
    }

    func testSlide1Dark() {
        let view = onboardingView(initialSlide: 0)
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 852),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Slide 2 (lines art with gold ring overlay, "The idea")

    func testSlide2Light() {
        let view = onboardingView(initialSlide: 1)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 852)),
            record: recordMode
        )
    }

    func testSlide2Dark() {
        let view = onboardingView(initialSlide: 1)
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 852),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Slide 3 (full-board art, "The payoff / GREENLOG")

    func testSlide3Light() {
        let view = onboardingView(initialSlide: 2)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 852)),
            record: recordMode
        )
    }

    func testSlide3Dark() {
        let view = onboardingView(initialSlide: 2)
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 852),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Sign-in panel ("One last thing / Save your streak.")

    func testSignInPanelLight() {
        let view = onboardingView(showSignIn: true)
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: 852)),
            record: recordMode
        )
    }

    func testSignInPanelDark() {
        let view = onboardingView(showSignIn: true)
        assertSnapshot(
            of: view,
            as: .image(
                layout: .fixed(width: 393, height: 852),
                traits: .init(userInterfaceStyle: .dark)
            ),
            record: recordMode
        )
    }

    // MARK: - Helpers

    /// Wraps `OnboardingView` with a no-op `onDone` and an explicit
    /// `initialSlide` / `initialShowSignIn` so snapshots are deterministic.
    private func onboardingView(
        initialSlide: Int = 0,
        showSignIn: Bool = false
    ) -> some View {
        OnboardingView(
            initialSlide: initialSlide,
            initialShowSignIn: showSignIn,
            onDone: {}
        )
    }
}
