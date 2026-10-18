import SwiftUI
import StoreKit

// MARK: - RequestReviewReader

/// Hands its content the environment's `requestReview` action, so a view
/// extension (which cannot declare `@Environment`) can request an App Store
/// review from a closure.
struct RequestReviewReader<Content: View>: View {
    @Environment(\.requestReview) private var requestReview
    /// Builds the wrapped content from the review action.
    let content: (RequestReviewAction) -> Content

    var body: some View { content(requestReview) }
}

// MARK: - BoardPlayView + review prompt

/// The App Store review prompt after early Bingos (Track L5, iOS-only — web
/// has no store prompt). The rules live in `ReviewPromptPolicy`; this is the
/// wiring at the moment overlay's open and its "Back to board".
extension BoardPlayView {

    /// The delay before the prompt, so it lands on the board once the
    /// overlay's 0.25 s fade-out has finished.
    private static let reviewPromptDelayNanoseconds: UInt64 = 400_000_000

    /// Counts a moment that just opened toward the review prompt (only an
    /// earned Bingo counts — `ReviewPromptPolicy.momentOpened`).
    ///
    /// - Parameter presentation: The moment that opened.
    func noteMomentOpenedForReview(_ presentation: MomentPresentation) {
        ReviewPromptPolicy.live.momentOpened(presentation.kind, isReplay: presentation.isReplay)
    }

    /// Requests a review after `presentation` closed via "Back to board",
    /// when the policy says one is due (it then records the prompt for this
    /// app version).
    ///
    /// - Parameters:
    ///   - presentation: The moment that was dismissed.
    ///   - requestReview: The environment's review action (`RequestReviewReader`).
    func requestReviewIfDue(afterDismissing presentation: MomentPresentation, using requestReview: RequestReviewAction) {
        guard ReviewPromptPolicy.live.consumePrompt(
            afterDismissing: presentation.kind, isReplay: presentation.isReplay,
            appVersion: ReviewPromptPolicy.currentAppVersion
        ) else { return }
        _Concurrency.Task { @MainActor in
            try? await _Concurrency.Task.sleep(nanoseconds: Self.reviewPromptDelayNanoseconds)
            requestReview()
        }
    }
}
