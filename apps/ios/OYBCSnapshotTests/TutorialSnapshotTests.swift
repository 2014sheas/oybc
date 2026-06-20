import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the Getting Started tutorial (handoff §0a): the pinned
/// home card, the tutorial board (0/8 + partial + complete), the lesson sheet
/// (undone + learned), and the mascot-free completion overlay. Light + dark.
@MainActor
final class TutorialSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    /// A fresh store seeded with the first `done` lessons complete, on an
    /// isolated in-memory UserDefaults suite (no cross-test bleed).
    private func seededStore(done: Int, suite: String) -> TutorialProgressStore {
        let defaults = UserDefaults(suiteName: "tut-snap-\(suite)")!
        defaults.removePersistentDomain(forName: "tut-snap-\(suite)")
        let store = TutorialProgressStore(defaults: defaults)
        for lesson in tutorialLessons.prefix(done) { store.markLearned(lesson.id) }
        return store
    }

    // MARK: - Tutorial card

    private func cardView(done: Int) -> some View {
        ZStack {
            Color.risoPaper
            TutorialCard(done: done, total: 8, onOpen: {}, onDismiss: {})
                .padding(20)
        }
    }

    func testCardInProgressLight() {
        assertSnapshot(of: cardView(done: 3), as: .image(layout: .fixed(width: 393, height: 170)), record: recordMode)
    }
    func testCardInProgressDark() {
        assertSnapshot(of: cardView(done: 3), as: .image(layout: .fixed(width: 393, height: 170), traits: .init(userInterfaceStyle: .dark)), record: recordMode)
    }
    func testCardCompleteLight() {
        assertSnapshot(of: cardView(done: 8), as: .image(layout: .fixed(width: 393, height: 170)), record: recordMode)
    }

    // MARK: - Tutorial board

    private func boardView(store: TutorialProgressStore) -> some View {
        TutorialBoardView(onTry: { _ in }, onBack: {}, onComplete: {})
            .environmentObject(store)
    }

    func testBoardEmptyLight() {
        assertSnapshot(of: boardView(store: seededStore(done: 0, suite: "b0")),
                       as: .image(layout: .fixed(width: 393, height: 560)), record: recordMode)
    }
    func testBoardPartialLight() {
        assertSnapshot(of: boardView(store: seededStore(done: 3, suite: "b3")),
                       as: .image(layout: .fixed(width: 393, height: 560)), record: recordMode)
    }
    func testBoardCompleteDark() {
        assertSnapshot(of: boardView(store: seededStore(done: 8, suite: "b8")),
                       as: .image(layout: .fixed(width: 393, height: 560), traits: .init(userInterfaceStyle: .dark)), record: recordMode)
    }

    // MARK: - Lesson sheet

    private func lesson(_ id: String) -> TutorialLesson {
        tutorialLessons.first(where: { $0.id == id })!
    }

    func testLessonSheetUndoneLight() {
        // "recurring" (Automate) — matches the prototype screenshot 19.
        assertSnapshot(of: TutorialLessonSheet(lesson: lesson("recurring"), isLearned: false, onTry: { _ in }, onMark: { _ in }),
                       as: .image(layout: .fixed(width: 393, height: 560)), record: recordMode)
    }
    func testLessonSheetLearnedDark() {
        assertSnapshot(of: TutorialLessonSheet(lesson: lesson("create"), isLearned: true, onTry: { _ in }, onMark: { _ in }),
                       as: .image(layout: .fixed(width: 393, height: 560), traits: .init(userInterfaceStyle: .dark)), record: recordMode)
    }

    // MARK: - Completion overlay

    func testCompletionOverlayLight() {
        assertSnapshot(of: TutorialGreenlogOverlay(), as: .image(layout: .fixed(width: 393, height: 760)), record: recordMode)
    }
    func testCompletionOverlayDark() {
        assertSnapshot(of: TutorialGreenlogOverlay(), as: .image(layout: .fixed(width: 393, height: 760), traits: .init(userInterfaceStyle: .dark)), record: recordMode)
    }
}
