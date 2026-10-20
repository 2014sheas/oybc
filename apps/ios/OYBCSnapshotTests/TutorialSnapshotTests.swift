import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the Getting Started tutorial (handoff 01-07): the pinned
/// Boards-tab card, the nine-square board in each state, the Pro stub sheet, the
/// lesson-complete card, the free-row card, the Bingo toast, the walkthrough
/// layers (coach mark, scrim + spotlight over a real control) and the tutorial
/// Greenlog. Light + dark.
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

    /// Create a task done, Create a board left at step 3 of 7.
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

    // MARK: - Pro stub, lesson complete, toast, leave (handoff 03, 05, 06)

    func testProSheetLight() { snap(TutorialProSheet(title: "Multi-step tasks"), height: 420) }
    func testProSheetDark() { snap(TutorialProSheet(title: "Multi-step tasks"), height: 420, dark: true) }

    private func completeCard(_ subtitle: String) -> some View {
        ZStack {
            TutorialScrimShape.color
            TutorialLessonCompleteCard(subtitle: subtitle)
        }
        .background(Color.risoPaper)
    }

    func testLessonCompleteLight() { snap(completeCard("Create a task · both tasks are in your library"), height: 420) }
    func testLessonCompleteDark() { snap(completeCard("Complete a board · a Bingo and a Greenlog"), height: 420, dark: true) }

    func testBingoToastLight() {
        snap(TutorialBingoToast().padding(20).background(Color.risoPaper), height: 100)
    }

    func testLeaveSheetLight() { snap(TutorialLeaveSheet(), height: 360) }

    // MARK: - Coach mark (handoff 03)

    private func markView(_ mark: TutorialCoachMark) -> some View {
        mark.padding(20).background(Color.risoPaper)
    }

    func testCoachMarkActionLight() {
        snap(markView(TutorialCoachMark(
            lessonTitle: "Create a task", text: "Type a task, then tap Add.", step: 1, stepCount: 5, notch: .up
        )), height: 170)
    }

    func testCoachMarkActionDark() {
        snap(markView(TutorialCoachMark(
            lessonTitle: "Create a task", text: "Type a task, then tap Add.", step: 1, stepCount: 5, notch: .up
        )), height: 170, dark: true)
    }

    func testCoachMarkReadOnlyNextResumedNotchDownLight() {
        snap(markView(TutorialCoachMark(
            lessonTitle: "Complete a board", text: "Tapped by mistake? Undo lives here for a moment.",
            step: 3, stepCount: 10, resumed: true, showsNext: true, notch: .down, notchOffset: 200
        )), height: 170)
    }

    func testCoachMarkDoneLineLight() {
        snap(markView(TutorialCoachMark(
            lessonTitle: "Create a board", text: "Fitness fills eight squares.",
            step: 4, stepCount: 12, showsNext: true, done: true, notch: .none
        )), height: 170)
    }

    func testCoachMarkLongTitleAndTextDark() {
        snap(markView(TutorialCoachMark(
            lessonTitle: "Complete a board and finish the whole tutorial lesson",
            text: "Action, then goal, then unit. The title fills itself in.", step: 3, stepCount: 5, notch: .up
        )), height: 190, dark: true)
    }

    // MARK: - Scrim + spotlight over a real control (handoff 03)

    /// The real coach layer over a mock screen: the real gold "+" button is lit
    /// by a hole in the scrim, ringed in gold, with the mark below.
    private func walkthroughOverScreen(step: Int, resumed: Bool = false) -> some View {
        let coach = TutorialCoordinator.preview(
            session: TutorialSession(lesson: .createTask, step: step, resumed: resumed)
        )
        return ZStack(alignment: .topLeading) {
            RisoPaperBackground()
            VStack(alignment: .leading, spacing: 6) {
                HStack(alignment: .top) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text("Your library").risoKicker()
                        Text("Tasks").risoH1()
                    }
                    Spacer()
                    RisoIconButton(systemImage: "plus") {}
                        .tutorialAnchor(.tasksPlus)
                }
                Text("Run 5k").font(.risoBody(15, .semibold)).padding(14)
                    .frame(maxWidth: .infinity, alignment: .leading).risoCard()
            }
            .padding(20)
        }
        .tutorialCoachLayer(isRoot: true)
        .environment(\.tutorialCoach, coach)
    }

    func testWalkthroughOverScreenLight() { snap(walkthroughOverScreen(step: 0), height: 420) }
    func testWalkthroughOverScreenResumedDark() { snap(walkthroughOverScreen(step: 0, resumed: true), height: 420, dark: true) }

    // MARK: - Tutorial Greenlog (handoff 2.6)

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
