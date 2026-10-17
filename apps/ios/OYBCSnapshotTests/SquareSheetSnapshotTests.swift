import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the square sheet (docs/TASK_DETAIL_REDESIGN.md PR 2),
/// rendered through its pure-props leaf `SquareSheetView` — the DB-backed
/// presenter is not snapshot-covered (see CLAUDE.md snapshot sharp edges). The
/// host adds the bottom inset a real sheet gets from the home indicator.
final class SquareSheetSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - Fixtures

    private func counting(
        _ current: CountValue, goal: CountValue = 20, kind: CountKind = .discrete, unit: String = "pages"
    ) -> SquareSheetContent.ChildCount {
        SquareSheetContent.ChildCount(
            current: current, goal: goal, unit: unit, kind: kind,
            chips: CounterLogAmount.tapChips(kind: kind, goal: goal, windowedCount: current)
        )
    }

    private func countingContent(
        _ count: SquareSheetContent.ChildCount, title: String = "Read 20 pages", board: String = "Week 42",
        closed: SquareSheetContent.Closed? = nil, busy: Bool = false
    ) -> SquareSheetContent {
        SquareSheetContent(
            boardTaskId: "bt1", taskId: "t1", title: title, kind: .counting, boardName: board,
            closed: closed, isBusy: busy, body: .counting(count)
        )
    }

    private func compoundContent(
        done: [Bool] = [true, true, false], countingCurrent: CountValue = 12, closed: SquareSheetContent.Closed? = nil
    ) -> SquareSheetContent {
        let kids = [
            SquareSheetContent.Child(id: "a", title: "Drink water", kind: .normal, isDone: done[0]),
            SquareSheetContent.Child(id: "b", title: "Stretch 5 min", kind: .normal, isDone: done[1]),
            SquareSheetContent.Child(
                id: "c", title: "Read 20 pages", kind: .counting, isDone: countingCurrent >= 20,
                counting: counting(countingCurrent)
            ),
        ]
        let isComplete = kids.allSatisfy(\.isDone)
        return SquareSheetContent(
            boardTaskId: "bt2", taskId: "t2", title: "Daily wellness", kind: .compound, boardName: "Today", closed: closed,
            body: .compound(SquareSheetContent.Compound(children: kids, isComplete: isComplete))
        )
    }

    private func strip(_ scope: String = "t1", _ text: String = "Logged +5 pages · Week 42", boardTaskId: String = "bt1") -> SquareLogStrip {
        SquareLogStrip(boardTaskId: boardTaskId, scopeTaskId: scope, text: text, undo: .counterLog(sourceTaskId: "t1"))
    }

    private let closedRoutable = SquareSheetContent.Closed(lockText: "Closed Oct 11", canLateLog: true)

    private func host(_ content: SquareSheetContent, strip: SquareLogStrip? = nil, height: CGFloat) -> some View {
        SquareSheetView(content: content, strip: strip)
            .frame(width: 393, height: height)
            .background(Color.risoPaper)
    }

    private func check(_ name: String = #function, content: SquareSheetContent, strip: SquareLogStrip? = nil, height: CGFloat = 470) {
        assertSnapshot(of: host(content, strip: strip, height: height), as: .image(layout: .fixed(width: 393, height: height)), record: recordMode, testName: name + "Light")
        assertSnapshot(
            of: host(content, strip: strip, height: height),
            as: .image(layout: .fixed(width: 393, height: height), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode, testName: name + "Dark"
        )
    }

    // MARK: - Counting

    func testCountingMidWithUndoStrip() {
        check(content: countingContent(counting(12)), strip: strip())
    }

    func testCountingAtZeroHasNoStatusPill() {
        check(content: countingContent(counting(0)), height: 440)
    }

    func testCountingDoneOmitsTheRestLineAndChip() {
        check(content: countingContent(counting(20)), height: 440)
    }

    func testCountingDurationShrinksTheHeroCount() {
        check(content: countingContent(counting(270, goal: 630, kind: .duration, unit: "guitar"), title: "Practice guitar"), height: 440)
    }

    func testCountingContinuous() {
        check(content: countingContent(counting(12.4, goal: 26.2, kind: .continuous, unit: "mi"), title: "Run 26.2 mi"), height: 440)
    }

    func testCountingBusyDisablesChipsWithoutHidingThem() {
        check(content: countingContent(counting(12), busy: true), strip: strip(), height: 470)
    }

    func testCountingClosedIsReadOnlyWithLateLog() {
        check(content: countingContent(counting(20), board: "Week 41", closed: closedRoutable), height: 380)
    }

    func testCountingClosedWithoutLateLog() {
        check(
            content: countingContent(counting(8), board: "Week 41", closed: SquareSheetContent.Closed(lockText: "Closed Oct 11", canLateLog: false)),
            height: 380
        )
    }

    // MARK: - Compound

    func testCompoundCollapsed() {
        check(content: compoundContent(), height: 520)
    }

    func testCompoundCountingChildOpenWithInlineUndo() {
        let content = compoundContent()
        let view = SquareSheetView(content: content, strip: strip("c", "Logged +5 pages · Today", boardTaskId: "bt2"), initialOpenChildId: "c")
            .frame(width: 393, height: 700)
            .background(Color.risoPaper)
        assertSnapshot(of: view, as: .image(layout: .fixed(width: 393, height: 700)), record: recordMode, testName: "testCompoundCountingChildOpenLight")
        assertSnapshot(
            of: view, as: .image(layout: .fixed(width: 393, height: 700), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode, testName: "testCompoundCountingChildOpenDark"
        )
    }

    func testCompoundAllDone() {
        check(content: compoundContent(done: [true, true, true], countingCurrent: 20), height: 520)
    }

    func testCompoundClosed() {
        check(content: compoundContent(closed: closedRoutable), height: 580)
    }

    // MARK: - Achievement

    func testAchievementWatchingBoard() {
        let achievement = SquareSheetContent.Achievement(
            watchedName: "October", timeframeBadge: "Core · Monthly", daysLeft: "14 days left",
            progress: "0 / 1 bingo", isMet: false, openBoardId: "b9"
        )
        check(content: SquareSheetContent(
            boardTaskId: "bt3", taskId: "t3", title: "Bingo on October", kind: .achievement, boardName: "Today",
            body: .achievement(achievement)
        ), height: 400)
    }

    func testAchievementTemplateWatcherHasNoOpenButton() {
        let achievement = SquareSheetContent.Achievement(
            watchedName: "Weekly reset", timeframeBadge: nil, daysLeft: nil,
            progress: "2 / 4", isMet: false, openBoardId: nil
        )
        check(content: SquareSheetContent(
            boardTaskId: "bt3", taskId: "t3", title: "4 weekly bingos", kind: .achievement, boardName: "Today",
            body: .achievement(achievement)
        ), height: 340)
    }

    // MARK: - Normal (View Details)

    func testNormalNotDone() {
        check(content: SquareSheetContent(
            boardTaskId: "bt4", taskId: "t4", title: "Finish Dune", kind: .normal, boardName: "Week 42",
            body: .normal(isDone: false, sealBlocked: false)
        ), height: 300)
    }

    func testNormalDoneSealBlockedIsDisabled() {
        check(content: SquareSheetContent(
            boardTaskId: "bt4", taskId: "t4", title: "Finish Dune", kind: .normal, boardName: "Week 42",
            body: .normal(isDone: true, sealBlocked: true)
        ), height: 300)
    }

    func testNormalClosed() {
        check(content: SquareSheetContent(
            boardTaskId: "bt4", taskId: "t4", title: "Finish Dune", kind: .normal, boardName: "Week 41", closed: closedRoutable,
            body: .normal(isDone: true, sealBlocked: false)
        ), height: 300)
    }

    // MARK: - Normal-tap Undo toast

    private func toastHost(detail: String) -> some View {
        ZStack(alignment: .bottom) {
            Color.risoPaper
            CounterLogToastView(amount: 0, unit: "", verb: .logged, message: "Finish Dune · done", detail: detail, onUndo: {}, onDone: {})
                .padding(.horizontal, Riso.gutter)
                .padding(.bottom, 24)
        }
        .frame(width: 393, height: 120)
    }

    func testNormalToastWithCreditedCounter() {
        assertSnapshot(of: toastHost(detail: "Week 42 · +1 Books"), as: .image(layout: .fixed(width: 393, height: 120)), record: recordMode)
    }

    func testNormalToastDark() {
        assertSnapshot(
            of: toastHost(detail: "Week 42"),
            as: .image(layout: .fixed(width: 393, height: 120), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }
}
