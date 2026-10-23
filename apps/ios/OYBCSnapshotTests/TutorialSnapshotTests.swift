import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the Getting Started tutorial: the pinned Boards-tab
/// card, the nine-square board in each state, the start / Pro / leave sheets,
/// the lesson-complete card, the free-row card, the Bingo toast, the stage
/// parts (tutorial bar, compact coach mark, the scrim + ring over a facsimile),
/// lesson 1's facsimiles step by step, and the tutorial Greenlog. Light + dark.
@MainActor
final class TutorialSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    private func snap<V: View>(_ view: V, width: CGFloat = 393, height: CGFloat, dark: Bool = false, name: String = #function, line: UInt = #line) {
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: width, height: height), traits: .init(userInterfaceStyle: dark ? .dark : .light)),
            record: recordMode,
            file: #filePath, testName: name, line: line
        )
    }

    // MARK: - Progress fixtures

    private var fresh: TutorialProgress { .empty }

    /// Create a task done, Create a board left at step 4 of 9.
    private var inProgress: TutorialProgress {
        var p = TutorialProgress.empty
        p.set(.createTask, .done)
        p.set(.createBoard, .inProgress(step: 3))
        return p
    }

    private var middleRow: TutorialProgress {
        var p = TutorialProgress.empty
        for id in TutorialLessonID.middleRow { p.set(id, .done) }
        return p
    }

    private var allDone: TutorialProgress {
        var p = TutorialProgress.empty
        for id in TutorialLessonID.allCases { p.set(id, .done) }
        return p
    }

    // MARK: - Boards-tab card (handoff 01)

    private func cardView(done: Int, middleRowDone: Bool = false) -> some View {
        ZStack {
            Color.risoPaper
            TutorialCard(done: done, total: 9, middleRowDone: middleRowDone, onOpen: {}, onDismiss: {})
                .padding(20)
        }
    }

    func testCardStartHereLight() { snap(cardView(done: 0), height: 120) }
    func testCardStartHereDark() { snap(cardView(done: 0), height: 120, dark: true) }
    func testCardKeepGoingLight() { snap(cardView(done: 1), height: 120) }
    func testCardKeepGoingDark() { snap(cardView(done: 1), height: 120, dark: true) }
    func testCardBingoLight() { snap(cardView(done: 3, middleRowDone: true), height: 120) }
    func testCardBingoDark() { snap(cardView(done: 3, middleRowDone: true), height: 120, dark: true) }

    // MARK: - Tutorial board (handoff 02)

    private func boardContent(_ progress: TutorialProgress, pop: TutorialLessonID? = nil) -> some View {
        TutorialBoardContent(progress: progress, popLesson: pop)
    }

    func testBoardEmptyLight() { snap(boardContent(fresh), height: 640) }
    func testBoardEmptyDark() { snap(boardContent(fresh), height: 640, dark: true) }
    func testBoardInProgressLight() { snap(boardContent(inProgress), height: 640) }
    func testBoardInProgressDark() { snap(boardContent(inProgress), height: 640, dark: true) }
    func testBoardMiddleRowDoneLight() { snap(boardContent(middleRow), height: 900) }
    func testBoardMiddleRowDoneDark() { snap(boardContent(middleRow), height: 900, dark: true) }
    func testBoardAllDoneLight() { snap(boardContent(allDone), height: 640) }
    func testBoardAllDoneDark() { snap(boardContent(allDone), height: 640, dark: true) }

    // MARK: - Sheets: start, Pro, leave

    func testStartSheetLesson1Light() { snap(TutorialStartSheet(info: TutorialCatalog.info(for: .createTask)), height: 360) }
    func testStartSheetLesson2Dark() { snap(TutorialStartSheet(info: TutorialCatalog.info(for: .createBoard)), height: 360, dark: true) }
    func testStartSheetLesson3Light() { snap(TutorialStartSheet(info: TutorialCatalog.info(for: .completeBoard)), height: 360) }

    func testProSheetLight() { snap(TutorialProSheet(title: "Multi-step tasks"), height: 420) }
    func testProSheetDark() { snap(TutorialProSheet(title: "Multi-step tasks"), height: 420, dark: true) }

    func testLeaveSheetStep3Light() { snap(TutorialLeaveSheet(step: 2), height: 360) }

    // MARK: - Lesson complete, free-row card, toast (handoff 06, 07)

    private func completeCard(_ subtitle: String, secondary: TutorialExit?) -> some View {
        ZStack {
            TutorialScrimShape.color
            TutorialLessonCompleteCard(subtitle: subtitle, secondary: secondary)
        }
        .background(Color.risoPaper)
    }

    func testLessonCompleteWithSecondaryLight() {
        snap(completeCard("Stretch 5 min and Read 20 pages are in your library.", secondary: .tasks), height: 420)
    }

    func testLessonCompleteNoSecondaryDark() {
        snap(completeCard("A Bingo and a Greenlog on the sample board. Nothing was saved.", secondary: nil), height: 420, dark: true)
    }

    func testBingoToastLight() {
        snap(TutorialBingoToast().padding(20).background(Color.risoPaper), height: 100)
    }

    // MARK: - Tutorial bar

    private func bar(step: Int, total: Int, label: String) -> some View {
        VStack(spacing: 0) {
            TutorialBar(label: label, step: step, stepCount: total)
            Color.risoPaper
        }
    }

    func testBarStep1Of7Light() { snap(bar(step: 0, total: 7, label: "Lesson 1 · Create a task"), height: 80) }
    func testBarStep8Of12Dark() { snap(bar(step: 7, total: 12, label: "Lesson 3 · Complete a board"), height: 80, dark: true) }

    // MARK: - Coach mark (compact)

    private func markView(_ mark: TutorialCoachMark) -> some View {
        mark.padding(20).background(Color.risoPaper)
    }

    func testCoachMarkCompactLight() {
        snap(markView(TutorialCoachMark(text: "Tap + to add a task.", notch: .up, notchOffset: 318)), height: 110)
    }

    func testCoachMarkCompactDark() {
        snap(markView(TutorialCoachMark(text: "Tap + to add a task.", notch: .up, notchOffset: 318)), height: 110, dark: true)
    }

    func testCoachMarkNextNotchDownLight() {
        snap(markView(TutorialCoachMark(text: "Tapped by mistake? Undo lives here for a moment.", showsNext: true, notch: .down, notchOffset: 200)), height: 110)
    }

    func testCoachMarkResumedNoNotchLight() {
        snap(markView(TutorialCoachMark(text: "Tap to make a Counting task.", resumed: true, notch: .none)), height: 110)
    }

    func testCoachMarkLongTextDark() {
        snap(markView(TutorialCoachMark(text: "One short. Type a task of your own, then tap Add.", notch: .up)), height: 130, dark: true)
    }

    // MARK: - Lesson 1 facsimiles, under the stage's spotlight

    /// Lesson 1 at `step` with the state the steps before it imply (plus
    /// `tweak`), under the real scrim + ring + coach mark.
    private func lesson1(step: Int, resumed: Bool = false, tweak: (inout TutorialCreateTaskState) -> Void = { _ in }) -> some View {
        var state = TutorialCreateTaskState.implied(step: step, typed: [
            TutorialField.quickAdd.rawValue: "Stretch 5 min", TutorialField.verb.rawValue: "Read",
            TutorialField.goal.rawValue: "20", TutorialField.unit.rawValue: "pages",
        ])
        tweak(&state)
        let coach = TutorialCoordinator.preview(
            session: TutorialSession(lesson: .createTask, step: step, resumed: resumed, state: .createTask(state))
        )
        return VStack(spacing: 0) {
            TutorialBar(label: "Lesson 1 · Create a task", step: step, stepCount: 7)
            TutorialCreateTaskLesson(state: state, step: step, perform: { _ in })
                .tutorialSpotlight(coach: coach)
                .clipped()
        }
        .background(Color.risoPaper)
    }

    func testLesson1Step1TasksPlusLight() { snap(lesson1(step: 0), height: 760) }
    func testLesson1Step1TasksPlusDark() { snap(lesson1(step: 0), height: 760, dark: true) }
    func testLesson1Step2QuickAddTypedLight() { snap(lesson1(step: 1) { $0.quickText = "Stretch 5 min" }, height: 760) }
    func testLesson1Step3SpecialResumedLight() { snap(lesson1(step: 2, resumed: true), height: 760) }
    func testLesson1Step4VerbLight() { snap(lesson1(step: 3), height: 760) }
    func testLesson1Step5GoalDark() { snap(lesson1(step: 4), height: 760, dark: true) }
    func testLesson1Step6UnitTitleLight() { snap(lesson1(step: 5) { $0.unit = "pages" }, height: 760) }
    func testLesson1Step7AddToLibraryLight() { snap(lesson1(step: 6), height: 760) }

    /// The Tasks facsimile after both writes (what the complete card sits over).
    func testLesson1TasksListAfterWritesLight() {
        var state = TutorialCreateTaskState.implied(step: 6, typed: [TutorialField.quickAdd.rawValue: "Stretch 5 min"])
        state.verb = "Read"; state.goal = "20"; state.unit = "pages"
        state.countingTitle = "Read 20 pages"
        state.sheetOpen = false
        snap(TutorialTasksFacsimile(state: state, step: 6, perform: { _ in }), height: 760)
    }

    // MARK: - Tutorial Greenlog

    func testTutorialGreenlogLight() {
        let m = MomentPresentation.tutorialGreenlog
        snap(
            RisoMomentOverlay(
                kind: .greenlog, replay: m.replay, cells: m.cells, boardName: "Getting started", linesCompleted: 8,
                beatOverride: momentFinalBeat(m.replay, kind: .greenlog), tutorialButtons: true
            ),
            height: 760
        )
    }
}
