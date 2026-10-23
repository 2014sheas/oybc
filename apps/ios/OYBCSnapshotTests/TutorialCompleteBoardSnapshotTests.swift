import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the lesson 3 facsimiles ("Complete a board"): the Sample
/// week play board, its Edit panel, the replace sheet, the Stretch toast, the
/// Read square sheet (12/20, then 22/20 with the Undo strip), the hold menu, the
/// finale with the ringed middle row and the shipped Bingo / Greenlog moments.
/// Each test renders the state `TutorialCompleteBoardState.implied(step:)` rebuilds
/// at that step. The stage's bar, scrim and coach mark are not part of these.
@MainActor
final class TutorialCompleteBoardSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    private func snap<V: View>(_ view: V, height: CGFloat = 760, dark: Bool = false, name: String = #function, line: UInt = #line) {
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: height), traits: .init(userInterfaceStyle: dark ? .dark : .light)),
            record: recordMode,
            file: #filePath, testName: name, line: line
        )
    }

    /// The lesson at `step`, with `adjust` applied to the rebuilt state.
    private func lesson(step: Int, adjust: (inout TutorialCompleteBoardState) -> Void = { _ in }) -> some View {
        var state = TutorialCompleteBoardState.implied(step: step)
        adjust(&state)
        return TutorialCompleteBoardLesson(state: state, step: step, perform: { _ in })
    }

    // MARK: - Play board (step 1)

    func testBoardStartLight() { snap(lesson(step: TutorialCompleteBoardState.Step.edit)) }
    func testBoardStartDark() { snap(lesson(step: TutorialCompleteBoardState.Step.edit), dark: true) }

    // MARK: - Edit panel (steps 2 and 4)

    func testEditPanelLight() { snap(lesson(step: TutorialCompleteBoardState.Step.tapJournal)) }
    func testEditPanelDark() { snap(lesson(step: TutorialCompleteBoardState.Step.tapJournal), dark: true) }

    func testEditPanelOneChangeLight() { snap(lesson(step: TutorialCompleteBoardState.Step.save)) }
    func testEditPanelOneChangeDark() { snap(lesson(step: TutorialCompleteBoardState.Step.save), dark: true) }

    // MARK: - Replace sheet (step 3)

    func testReplaceSheetLight() { snap(lesson(step: TutorialCompleteBoardState.Step.pickReplacement)) }
    func testReplaceSheetDark() { snap(lesson(step: TutorialCompleteBoardState.Step.pickReplacement), dark: true) }

    // MARK: - Stretch toast (step 6)

    func testStretchToastLight() { snap(lesson(step: TutorialCompleteBoardState.Step.toast)) }
    func testStretchToastDark() { snap(lesson(step: TutorialCompleteBoardState.Step.toast), dark: true) }

    // MARK: - Square sheet (steps 8 and 9)

    func testSquareSheetChipsLight() { snap(lesson(step: TutorialCompleteBoardState.Step.chips)) }
    func testSquareSheetChipsDark() { snap(lesson(step: TutorialCompleteBoardState.Step.chips), dark: true) }

    func testSquareSheetDoneUndoStripLight() { snap(lesson(step: TutorialCompleteBoardState.Step.undoStrip)) }
    func testSquareSheetDoneUndoStripDark() { snap(lesson(step: TutorialCompleteBoardState.Step.undoStrip), dark: true) }

    /// After the first +5: 17/20 with the Undo strip and the +3 rest chip.
    func testSquareSheetAfterFirstChipLight() {
        snap(lesson(step: TutorialCompleteBoardState.Step.chips) { state in
            state.readCount += TutorialSampleWeek.chip
            state.undoText = TutorialCompleteBoardState.undoLine
        })
    }

    // MARK: - Hold menu (step 11)

    func testHoldMenuLight() { snap(lesson(step: TutorialCompleteBoardState.Step.markDone)) }
    func testHoldMenuDark() { snap(lesson(step: TutorialCompleteBoardState.Step.markDone), dark: true) }

    // MARK: - Finale (step 12)

    func testFinaleLight() { snap(lesson(step: TutorialCompleteBoardState.Step.finale)) }
    func testFinaleDark() { snap(lesson(step: TutorialCompleteBoardState.Step.finale), dark: true) }

    // MARK: - Moments

    /// A moment pinned at its final beat (the replay otherwise animates).
    private func moment(_ kind: TutorialCompleteBoardState.Moment, adjust: (inout TutorialCompleteBoardState) -> Void = { _ in }) -> some View {
        var state = TutorialCompleteBoardState.implied(step: TutorialCompleteBoardState.Step.finale)
        adjust(&state)
        state.moment = kind
        let replay = TutorialCompleteBoardMoment.replay(for: state)
        let beat = momentFinalBeat(replay, kind: kind == .bingo ? .bingo : .greenlog)
        return TutorialCompleteBoardLesson(
            state: state, step: TutorialCompleteBoardState.Step.finale, perform: { _ in }, momentBeatOverride: beat
        )
    }

    /// The shipped Bingo moment over the finished middle row (6/9, line 1 of 8).
    func testBingoMomentLight() { snap(moment(.bingo), height: 852) }

    /// The shipped Greenlog moment once all nine are done.
    func testGreenlogMomentLight() {
        snap(moment(.greenlog) { $0.done = Set(TutorialSampleWeek.grid.indices) }, height: 852)
    }
}
