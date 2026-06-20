import Foundation
import Combine

/// Tracks the user's progress through the "Getting Started" tutorial board
/// (handoff §0a) — which of the 8 lesson squares are done, and whether the
/// pinned home card has been dismissed.
///
/// Device-local only, backed by `UserDefaults` — same convention as
/// `UserDefaults.hasSeenOnboarding` (the tutorial is first-run guidance, not
/// synced state). Injected app-wide via `.environmentObject` from
/// `AuthGateView`, like `NotificationService`, so the home card, the tutorial
/// board, and the Profile entry all observe one source of truth.
final class TutorialProgressStore: ObservableObject {

    /// Total lesson squares (the 3×3 board minus the FREE center).
    static let totalLessons = 8

    private enum Keys {
        static let completed = "oybc-tutorial-completed-lessons"
        static let cardDismissed = "oybc-tutorial-card-dismissed"
    }

    private let defaults: UserDefaults

    /// Lesson ids the user has completed ("Try it" or "Mark as learned").
    @Published private(set) var completedLessonIDs: Set<String>
    /// Whether the user dismissed the pinned home card.
    @Published private(set) var isCardDismissed: Bool

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        self.completedLessonIDs = Set(defaults.stringArray(forKey: Keys.completed) ?? [])
        self.isCardDismissed = defaults.bool(forKey: Keys.cardDismissed)
    }

    // MARK: - Derived

    var completedCount: Int { completedLessonIDs.count }

    /// True once every lesson is done.
    var isComplete: Bool { completedCount >= Self.totalLessons }

    func isLearned(_ lessonID: String) -> Bool {
        completedLessonIDs.contains(lessonID)
    }

    // MARK: - Mutations

    /// Marks a lesson complete (idempotent) and persists.
    func markLearned(_ lessonID: String) {
        guard !completedLessonIDs.contains(lessonID) else { return }
        completedLessonIDs.insert(lessonID)
        defaults.set(Array(completedLessonIDs), forKey: Keys.completed)
    }

    /// Hides the pinned home card. The tutorial stays reachable from Profile.
    func dismissCard() {
        guard !isCardDismissed else { return }
        isCardDismissed = true
        defaults.set(true, forKey: Keys.cardDismissed)
    }

    /// Clears all progress + un-dismisses the card (DEBUG "reset" affordance).
    func reset() {
        completedLessonIDs = []
        isCardDismissed = false
        defaults.removeObject(forKey: Keys.completed)
        defaults.removeObject(forKey: Keys.cardDismissed)
    }
}
