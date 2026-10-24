import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the Getting Started tutorial: the pinned Boards-tab
/// card, the nine-square board in each state, the start / Pro / leave sheets,
/// the lesson-complete card, the free-row card, the Bingo toast, the stage
/// parts (tutorial bar, compact coach mark with its note, the tell card, the
/// scrim + ring over a facsimile), lesson 1's facsimiles step by step, the
/// lesson 2 and 3 stage states the v3 handoff added (lit read-only groups, the
/// coach mark over a shipped moment, a tell over the ringed board), and the
/// tutorial Greenlog. Light + dark.
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

    /// Create a task done, Create a board left at step 4 of 14.
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

    func testBarStep1Of10Light() { snap(bar(step: 0, total: 10, label: "Lesson 1 · Create a task"), height: 80) }
    func testBarStep14Of16Dark() { snap(bar(step: 13, total: 16, label: "Lesson 3 · Complete a board"), height: 80, dark: true) }

    // MARK: - Coach mark (compact + tell)

    private func markView(_ mark: TutorialCoachMark) -> some View {
        mark.padding(20).background(Color.risoPaper)
    }

    func testCoachMarkCompactLight() {
        snap(markView(TutorialCoachMark(text: "Tap + to add a task.", note: "Search and the filters find tasks you already have.", notch: .up, notchOffset: 318)), height: 130)
    }

    func testCoachMarkCompactDark() {
        snap(markView(TutorialCoachMark(text: "Tap + to add a task.", note: "Search and the filters find tasks you already have.", notch: .up, notchOffset: 318)), height: 130, dark: true)
    }

    func testCoachMarkNextNotchDownLight() {
        snap(markView(TutorialCoachMark(text: "Done. Undo if you did not mean it.", note: "The toast stays a few seconds, then the square counts as done.", showsNext: true, notch: .down, notchOffset: 200)), height: 130)
    }

    /// The first mark after a resume: the step's short form, no note.
    func testCoachMarkResumedNoNotchLight() {
        snap(markView(TutorialCoachMark(text: "Tap Special type.", resumed: true, notch: .none)), height: 110)
    }

    func testCoachMarkLongNoteDark() {
        snap(markView(TutorialCoachMark(text: "Tap Next.", note: "Nine squares with a Free centre needs 8 tasks. Choose picks the centre task yourself; None makes it an ordinary square, so 9.", notch: .down, notchOffset: 22)), height: 150, dark: true)
    }

    func testCoachMarkTellLight() {
        snap(markView(TutorialCoachMark(text: "A verb, a goal and a unit make the title: Read 20 pages. You can rename it later.", title: "Three parts make a counter", showsNext: true, notch: .none)).padding(.horizontal, 8), height: 180)
    }

    func testCoachMarkTellDark() {
        snap(markView(TutorialCoachMark(text: "Squares done, days left and Bingos sit at the top. Colour is the task type: red is Simple, blue is Counting.", title: "Reading a board", showsNext: true, notch: .none)).padding(.horizontal, 8), height: 200, dark: true)
    }

    // MARK: - Lesson 1 facsimiles, under the stage's spotlight

    private typealias L1 = TutorialCreateTaskState.Step
    private typealias L2 = TutorialCreateBoardState.Step
    private typealias L3 = TutorialCompleteBoardState.Step

    /// Lesson 1 at `step` with the state the steps before it imply (plus
    /// `tweak`), under the real scrim + ring + coach mark (or a tell).
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
            TutorialBar(label: "Lesson 1 · Create a task", step: step, stepCount: TutorialCatalog.createTaskSteps.count)
            TutorialCreateTaskLesson(state: state, step: step, perform: { _ in })
                .tutorialSpotlight(coach: coach)
                .clipped()
        }
        .background(Color.risoPaper)
    }

    func testLesson1Step1TellLibraryLight() { snap(lesson1(step: L1.tellLibrary), height: 760) }
    func testLesson1Step2TasksPlusLight() { snap(lesson1(step: L1.plus), height: 760) }
    func testLesson1Step2TasksPlusDark() { snap(lesson1(step: L1.plus), height: 760, dark: true) }
    func testLesson1Step3TellKindsDark() { snap(lesson1(step: L1.tellKinds), height: 760, dark: true) }
    func testLesson1Step4QuickAddTypedLight() { snap(lesson1(step: L1.quickAdd) { $0.quickText = "Stretch 5 min" }, height: 760) }
    func testLesson1Step5SpecialResumedLight() { snap(lesson1(step: L1.special, resumed: true), height: 760) }
    func testLesson1Step6TellCounterLight() { snap(lesson1(step: L1.tellCounter), height: 760) }
    func testLesson1Step7VerbLight() { snap(lesson1(step: L1.verb), height: 760) }
    func testLesson1Step8GoalDark() { snap(lesson1(step: L1.goal), height: 760, dark: true) }
    func testLesson1Step9UnitTitleLight() { snap(lesson1(step: L1.unit) { $0.unit = "pages" }, height: 760) }
    func testLesson1Step10AddToLibraryLight() { snap(lesson1(step: L1.submit), height: 760) }

    /// The Tasks facsimile after both writes (what the complete card sits over).
    func testLesson1TasksListAfterWritesLight() {
        var state = TutorialCreateTaskState.implied(step: L1.submit, typed: [TutorialField.quickAdd.rawValue: "Stretch 5 min"])
        state.verb = "Read"; state.goal = "20"; state.unit = "pages"
        state.countingTitle = "Read 20 pages"
        state.sheetOpen = false
        snap(TutorialTasksFacsimile(state: state, step: L1.submit, perform: { _ in }), height: 760)
    }

    // MARK: - Lesson 2 stage states the v3 handoff added

    private func lesson2(step: Int, tweak: (inout TutorialCreateBoardState) -> Void = { _ in }) -> some View {
        var state = TutorialCreateBoardState.implied(step: step, typed: [TutorialField.wizardQuickAdd.rawValue: "Drink water"])
        tweak(&state)
        let coach = TutorialCoordinator.preview(
            session: TutorialSession(lesson: .createBoard, step: step, resumed: false, state: .createBoard(state))
        )
        return VStack(spacing: 0) {
            TutorialBar(label: "Lesson 2 · Create a board", step: step, stepCount: TutorialCatalog.createBoardSteps.count)
            TutorialCreateBoardLesson(state: state, step: step, perform: { _ in })
                .tutorialSpotlight(coach: coach)
                .clipped()
        }
        .background(Color.risoPaper)
    }

    /// Step 2: the tell over Setup with nothing picked ("Pick a timeframe").
    func testLesson2Step2TellSetupLight() { snap(lesson2(step: L2.tellSetup), height: 760) }
    /// Step 4: the window chip lit to read, Next in the mark.
    func testLesson2Step4WindowLitLight() { snap(lesson2(step: L2.window), height: 760) }
    /// Step 6: Next wired with the "8 tasks" caption and the centre row lit beside it.
    func testLesson2Step6NextGroupLight() { snap(lesson2(step: L2.setupNext), height: 760) }
    func testLesson2Step6NextGroupDark() { snap(lesson2(step: L2.setupNext), height: 760, dark: true) }
    /// Step 10: the tell over the Tasks step with Fitness pulled (8/8).
    func testLesson2Step10TellTuneLight() { snap(lesson2(step: L2.tellTune), height: 760) }
    /// Step 13b: the hand-added task restored 8/8 and the ring moved to Next.
    func testLesson2Step13bNextLight() { snap(lesson2(step: L2.handAdd), height: 760) }

    // MARK: - Lesson 3 stage states the v3 handoff added

    private func lesson3(step: Int, beat: Bool = false, tweak: (inout TutorialCompleteBoardState) -> Void = { _ in }) -> some View {
        var state = TutorialCompleteBoardState.implied(step: step)
        tweak(&state)
        let coach = TutorialCoordinator.preview(
            session: TutorialSession(lesson: .completeBoard, step: step, resumed: false, state: .completeBoard(state))
        )
        let beatOverride: Int? = beat
            ? momentFinalBeat(TutorialCompleteBoardMoment.replay(for: state), kind: state.moment == .greenlog ? .greenlog : .bingo)
            : nil
        return VStack(spacing: 0) {
            TutorialBar(label: "Lesson 3 · Complete a board", step: step, stepCount: TutorialCatalog.completeBoardSteps.count)
            TutorialCompleteBoardLesson(state: state, step: step, perform: { _ in }, momentBeatOverride: beatOverride)
                .tutorialSpotlight(coach: coach)
                .clipped()
        }
        .background(Color.risoPaper)
    }

    /// Step 1: the tell over the half-played board.
    func testLesson3Step1TellReadingLight() { snap(lesson3(step: L3.tellReading), height: 760) }
    /// Step 14: the shipped Bingo moment with the coach mark alone above its buttons.
    func testLesson3Step14BingoMomentCoachLight() { snap(lesson3(step: L3.bingoMoment, beat: true), height: 852) }
    /// Step 15: the tell over the board with the middle row ringed gold.
    func testLesson3Step15TellLinesDark() { snap(lesson3(step: L3.tellLines), height: 760, dark: true) }
    /// Step 16: three left, no notch.
    func testLesson3Step16FinaleLight() { snap(lesson3(step: L3.finale), height: 760) }
    /// Step 16b: Meditate done, the middle column rings too, "Two left."
    func testLesson3Step16bTwoLeftLight() {
        snap(lesson3(step: L3.finale) { state in _ = state.apply(.squareTapped(TutorialSampleWeek.Slot.journal), step: L3.finale) }, height: 760)
    }
    /// Step 16c: the Greenlog moment with the coach mark above its buttons.
    func testLesson3Step16cGreenlogCoachLight() {
        snap(lesson3(step: L3.finale, beat: true) { state in
            for slot in state.remaining { _ = state.apply(.squareTapped(slot), step: L3.finale) }
        }, height: 852)
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
