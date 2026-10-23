import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the lesson 2 ("Create a board") facsimiles: the Create
/// hub, the wizard's Setup / Tasks / Preview steps and the "Add from a pool or
/// board" sheet, each at the state a walkthrough step implies
/// (`TutorialCreateBoardState.implied(step:typed:)`). The scrim, ring and coach
/// mark belong to the stage and are covered by `TutorialSnapshotTests`; these
/// render the facsimiles bare. Step numbers below are 0-based, as in the state's
/// `Step` constants.
@MainActor
final class TutorialCreateBoardSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    private func snap<V: View>(_ view: V, height: CGFloat = 760, dark: Bool = false, name: String = #function, line: UInt = #line) {
        assertSnapshot(
            of: view,
            as: .image(layout: .fixed(width: 393, height: height), traits: .init(userInterfaceStyle: dark ? .dark : .light)),
            record: recordMode,
            file: #filePath, testName: name, line: line
        )
    }

    /// The lesson at a state, with the clock pinned.
    private func lesson(_ state: TutorialCreateBoardState, step: Int) -> some View {
        TutorialCreateBoardLesson(state: state, step: step, perform: { _ in }, now: SnapshotFixtures.fixedNow)
    }

    /// The state a walkthrough step implies.
    private func implied(_ step: Int, typed: [String: String] = [:]) -> TutorialCreateBoardState {
        .implied(step: step, typed: typed)
    }

    // MARK: - Hub (step 1)

    func testHubLight() { snap(lesson(implied(0), step: 0)) }
    func testHubDark() { snap(lesson(implied(0), step: 0), dark: true) }

    // MARK: - Setup (steps 2-3)

    func testSetupTimeframeLight() { snap(lesson(implied(1), step: 1)) }

    func testSetupSizePickedLight() {
        var state = implied(2)
        state.sizePicked = true
        snap(lesson(state, step: 2))
    }

    func testSetupSizePickedDark() {
        var state = implied(2)
        state.sizePicked = true
        snap(lesson(state, step: 2), dark: true)
    }

    // MARK: - Tasks (steps 4-8)

    func testTasksEmptyLight() { snap(lesson(implied(3), step: 3)) }

    func testSourceSheetPoolCheckedLight() {
        var state = implied(4)
        state.poolChecked = true
        snap(lesson(state, step: 4))
    }

    func testSourceSheetPoolCheckedDark() {
        var state = implied(4)
        state.poolChecked = true
        snap(lesson(state, step: 4), dark: true)
    }

    func testTasksPoolAddedLight() { snap(lesson(implied(5), step: 5)) }

    func testTasksSourceExpandedLight() { snap(lesson(implied(6), step: 6), height: 1000) }
    func testTasksSourceExpandedDark() { snap(lesson(implied(6), step: 6), height: 1000, dark: true) }

    func testTasksExcludedTypedLight() {
        var state = implied(7)
        state.quickText = "Drink water"
        snap(lesson(state, step: 7))
    }

    func testTasksHandAddedLight() {
        var state = implied(7)
        state.handAddedTitle = "Drink water"
        snap(lesson(state, step: 7))
    }

    func testTasksHandAddedDark() {
        var state = implied(7)
        state.handAddedTitle = "Drink water"
        snap(lesson(state, step: 7), dark: true)
    }

    // MARK: - Preview (step 9)

    func testPreviewLight() {
        snap(lesson(implied(8, typed: [TutorialField.wizardQuickAdd.rawValue: "Drink water"]), step: 8))
    }

    func testPreviewDark() {
        snap(lesson(implied(8, typed: [TutorialField.wizardQuickAdd.rawValue: "Drink water"]), step: 8), dark: true)
    }
}
