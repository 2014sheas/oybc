import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the lesson 2 ("Create a board") facsimiles: the Create
/// hub, the wizard's Setup / Tasks / Preview steps and the "Add from a pool or
/// board" sheet, each at the state a walkthrough step implies
/// (`TutorialCreateBoardState.implied(step:typed:)`). The scrim, ring and coach
/// mark belong to the stage and are covered by `TutorialSnapshotTests`; these
/// render the facsimiles bare. Steps are the state's `Step` constants (0-based);
/// the section headers count from 1 like the handoff.
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

    /// The lesson at a state (the sample week is a fixture, so no clock).
    private func lesson(_ state: TutorialCreateBoardState, step: Int) -> some View {
        TutorialCreateBoardLesson(state: state, step: step, perform: { _ in })
    }

    /// The state a walkthrough step implies.
    private func implied(_ step: Int, typed: [String: String] = [:]) -> TutorialCreateBoardState {
        .implied(step: step, typed: typed)
    }

    private typealias L2 = TutorialCreateBoardState.Step

    // MARK: - Hub (step 1)

    func testHubLight() { snap(lesson(implied(L2.hub), step: L2.hub)) }
    func testHubDark() { snap(lesson(implied(L2.hub), step: L2.hub), dark: true) }

    // MARK: - Setup (steps 3-6)

    /// Weekly offered, the chip still reads "Pick a timeframe".
    func testSetupTimeframeLight() { snap(lesson(implied(L2.timeframe), step: L2.timeframe)) }

    /// Weekly picked: the chip names the sample week.
    func testSetupWindowLight() { snap(lesson(implied(L2.window), step: L2.window)) }

    /// 3×3 picked, Next live, the "8 tasks" caption in ink.
    func testSetupSizePickedLight() { snap(lesson(implied(L2.setupNext), step: L2.setupNext)) }
    func testSetupSizePickedDark() { snap(lesson(implied(L2.setupNext), step: L2.setupNext), dark: true) }

    // MARK: - Tasks (steps 8-13)

    func testTasksEmptyLight() { snap(lesson(implied(L2.addFromPool), step: L2.addFromPool)) }

    func testSourceSheetPoolCheckedLight() {
        var state = implied(L2.pickPool)
        state.poolChecked = true
        snap(lesson(state, step: L2.pickPool))
    }

    func testSourceSheetPoolCheckedDark() {
        var state = implied(L2.pickPool)
        state.poolChecked = true
        snap(lesson(state, step: L2.pickPool), dark: true)
    }

    func testTasksPoolAddedLight() { snap(lesson(implied(L2.sourceRow), step: L2.sourceRow)) }

    func testTasksSourceExpandedLight() { snap(lesson(implied(L2.exclude), step: L2.exclude), height: 1000) }
    func testTasksSourceExpandedDark() { snap(lesson(implied(L2.exclude), step: L2.exclude), height: 1000, dark: true) }

    func testTasksExcludedTypedLight() {
        var state = implied(L2.handAdd)
        state.quickText = "Drink water"
        snap(lesson(state, step: L2.handAdd))
    }

    func testTasksHandAddedLight() {
        var state = implied(L2.handAdd)
        state.handAddedTitle = "Drink water"
        snap(lesson(state, step: L2.handAdd))
    }

    func testTasksHandAddedDark() {
        var state = implied(L2.handAdd)
        state.handAddedTitle = "Drink water"
        snap(lesson(state, step: L2.handAdd), dark: true)
    }

    // MARK: - Preview (step 14)

    func testPreviewLight() {
        snap(lesson(implied(L2.activate, typed: [TutorialField.wizardQuickAdd.rawValue: "Drink water"]), step: L2.activate))
    }

    func testPreviewDark() {
        snap(lesson(implied(L2.activate, typed: [TutorialField.wizardQuickAdd.rawValue: "Drink water"]), step: L2.activate), dark: true)
    }
}
