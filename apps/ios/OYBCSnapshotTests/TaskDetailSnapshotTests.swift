import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the Task Detail shell (docs/TASK_DETAIL_REDESIGN.md PR 4): each type's
/// hero on the route and in the sheet, each segment, the no-anchor state and the return pill.
/// Rendered through the pure leaves (`TaskDetailHeroView`, `TaskDetailSectionsView`) with fixed
/// models, so the render has no clock and no database.
final class TaskDetailSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - Fixtures

    private func counting(_ current: CountValue, goal: CountValue = 20, kind: CountKind = .discrete, unit: String = "pages") -> SquareSheetContent.ChildCount {
        SquareSheetContent.ChildCount(
            current: current, goal: goal, unit: unit, kind: kind,
            chips: CounterLogAmount.tapChips(kind: kind, goal: goal, windowedCount: current)
        )
    }

    private let rows: [TaskDetailModel.BoardRow] = [
        .init(id: "b1", name: "Week 42", badge: "Core · weekly", caption: "This week · ends Sun · 2 days left", value: "12", valueSub: "/20", fraction: 0.6),
        .init(id: "b2", name: "October", badge: "Core · monthly", caption: "This month · ends Oct 31 · 14 days left", value: "61", valueSub: "/80", fraction: 0.76),
    ]
    private let past: [TaskDetailModel.BoardRow] = [
        .init(id: "p1", name: "Week 41", caption: "Oct 5–11 · expired", value: "20", valueSub: "/20", isDone: true, fraction: 1),
        .init(id: "p2", name: "Reading sprint", caption: "Oct 1–14 · closed", value: "40", valueSub: "/40", isDone: true, fraction: 1),
        .init(id: "p3", name: "Oct 15", caption: "Oct 15 · expired", value: "1", valueSub: "/3", fraction: 0.33),
        .init(id: "p4", name: "Autumn reset", caption: "Custom · not started", isDraft: true),
    ]
    private let activity: [TaskDetailModel.ActivityLine] = [
        .init(id: "1", kind: .logged, text: "Logged +5 pages · Week 42", when: "Oct 15"),
        .init(id: "2", kind: .logged, text: "Logged +7 pages · Week 42", when: "Oct 13"),
        .init(id: "3", kind: .completed, text: "Completed · Week 41", when: "Oct 11"),
        .init(id: "4", kind: .placed, text: "Placed on Week 42", when: "Oct 12"),
        .init(id: "5", kind: .missed, text: "Missed · Oct 15", when: "Oct 15"),
        .init(id: "6", kind: .created, text: "Created", when: "Sep 2, 2025"),
    ]

    private func base(
        id: String, title: String, kind: RisoTaskKind, kicker: String, hero: TaskDetailModel.Hero, description: String? = nil
    ) -> TaskDetailModel {
        TaskDetailModel(
            taskId: id, title: title, description: description, kind: kind, kicker: kicker, anchorName: "Week 42",
            anchorTimeframe: .weekly, hero: hero,
            activeBoards: rows, pastBoards: past, activity: activity,
            footer: "Completed 3× all-time · updated 2d ago"
        )
    }

    private var countingModel: TaskDetailModel {
        var m = base(
            id: "c", title: "Read 20 pages", kind: .counting, kicker: "Counting · linked counter", hero: .counting(counting(12)),
            description: "Any book counts. Audiobooks count at 1 page per minute."
        )
        m.counter = .init(counterId: "root", label: "Shared counter", name: "Read pages", total: "1,240", unit: "pages")
        m.parents = [.init(id: "p", title: "Evening wind-down", kind: .compound)]
        m.templates = [.init(id: "t", name: "Weekly core")]
        return m
    }

    private var durationModel: TaskDetailModel {
        base(id: "d", title: "Practice 10h 30m", kind: .counting, kicker: "Counting · duration", hero: .counting(counting(270, goal: 630, kind: .duration, unit: "guitar")))
    }

    private var normalModel: TaskDetailModel {
        var m = base(id: "n", title: "Finish Dune", kind: .normal, kicker: "Normal · counts toward Books", hero: .normal(isDone: false, sealBlocked: false), description: "The paperback on the nightstand.")
        m.activeBoards = [.init(id: "b1", name: "Week 42", badge: "Core · weekly", caption: "This week · ends Sun · 2 days left")]
        m.counter = .init(counterId: "root", label: "Counts toward", name: "Books", total: "12", unit: "books")
        return m
    }

    private var compoundModel: TaskDetailModel {
        let kids = [
            SquareSheetContent.Child(id: "a", title: "Drink water", kind: .normal, isDone: true),
            SquareSheetContent.Child(id: "b", title: "Stretch 5 min", kind: .normal, isDone: true),
            SquareSheetContent.Child(id: "c", title: "Read 20 pages", kind: .counting, isDone: false, counting: counting(12)),
        ]
        var m = base(
            id: "k", title: "Daily wellness", kind: .compound, kicker: "Compound · all of 3",
            hero: .compound(SquareSheetContent.Compound(children: kids, isComplete: false), ruleLabel: "All of 3")
        )
        m.subtaskRule = "All of 3"
        m.subtasks = kids.map { .init(id: $0.id, title: $0.title, kind: $0.kind, isDone: $0.isDone) }
        return m
    }

    private var achievementModel: TaskDetailModel {
        let card = SquareSheetContent.Achievement(
            watchedName: "October", timeframeBadge: "Core · MONTHLY", daysLeft: "14 days left",
            progress: "0 / 1 bingo", isMet: false, openBoardId: "w1"
        )
        var m = base(
            id: "a", title: "Bingo on October", kind: .achievement, kicker: "Achievement · first bingo",
            hero: .achievement(.init(
                card: card, closestLine: .init(cells: [0, 1, 2, 3, 4], done: 3), lineCells: [true, true, true, false, false]
            ))
        )
        m.watches = .init(id: "w1", title: "October", kind: .achievement)
        m.watchesMeta = "First bingo"
        m.watchedBoardId = "w1"
        return m
    }

    private var noAnchorModel: TaskDetailModel {
        var m = base(id: "c", title: "Read 20 pages", kind: .counting, kicker: "Counting", hero: TaskDetailModel.Hero.none)
        m.anchorName = nil
        m.activeBoards = []
        m.pastBoards = [past[0]]
        return m
    }

    private let stripLog = SquareLogStrip(boardTaskId: "bt", scopeTaskId: "c", text: "Logged +5 pages · Week 42", undo: .counterLog(sourceTaskId: "root"))

    // MARK: - Harness

    private func traits(_ dark: Bool) -> UITraitCollection { .init(userInterfaceStyle: dark ? .dark : .light) }

    private func check(_ view: some View, width: CGFloat = 393, height: CGFloat, name: String = #function) {
        for dark in [false, true] {
            assertSnapshot(
                of: view.frame(width: width, height: height, alignment: .top).background(Color.risoPaper),
                as: .image(layout: .fixed(width: width, height: height), traits: traits(dark)),
                record: recordMode, testName: name + (dark ? "Dark" : "Light")
            )
        }
    }

    private func hero(
        _ model: TaskDetailModel, strip: SquareLogStrip? = nil, busy: Bool = false, presentation: TaskDetailPresentation = .route,
        openChild: String? = nil
    ) -> some View {
        TaskDetailHeroView(model: model, strip: strip, isBusy: busy, presentation: presentation, initialOpenChildId: openChild)
    }

    // MARK: - Heroes (route)

    func testHeroCountingRoute() { check(hero(countingModel, strip: stripLog), height: 760) }
    func testHeroCountingDuration() { check(hero(durationModel), height: 620) }
    func testHeroCountingBusyDisablesChips() { check(hero(countingModel, strip: stripLog, busy: true), height: 760) }
    func testHeroNormalRoute() { check(hero(normalModel), height: 420) }
    func testHeroCompoundRoute() { check(hero(compoundModel), height: 560) }
    func testHeroCompoundCountingChildOpen() {
        let strip = SquareLogStrip(boardTaskId: "bt", scopeTaskId: "c", text: "Logged +5 pages · Week 42", undo: .counterLog(sourceTaskId: "r"))
        check(hero(compoundModel, strip: strip, openChild: "c"), height: 760)
    }
    func testHeroAchievementRoute() { check(hero(achievementModel), height: 520) }
    func testHeroNoAnchorShowsNoControl() { check(hero(noAnchorModel), height: 260) }

    // MARK: - Heroes (sheet)

    func testHeroCountingSheet() { check(hero(countingModel, presentation: .sheet(returnTo: nil)), height: 700) }
    func testHeroCompoundSheetWithReturnPill() {
        let back = TaskDetailPresentation.ReturnTarget(taskId: "k", title: "Daily wellness", kind: .compound)
        check(hero(countingModel, presentation: .sheet(returnTo: back)), height: 700)
    }
    func testHeroNormalSheet() { check(hero(normalModel, presentation: .sheet(returnTo: nil)), height: 420) }

    func testReturnPillTruncatesLongNames() {
        let pills = VStack(alignment: .leading, spacing: 12) {
            RisoReturnPill(title: "Daily wellness", kind: .compound, border: .risoInk, action: {})
            RisoReturnPill(title: "A very long previous task name that must truncate", kind: .counting, border: .risoInk, action: {})
            RisoReturnPill(title: "Finish Dune", kind: .normal, border: .risoInk, action: {})
        }
        .padding(20)
        check(pills, height: 150)
    }

    // MARK: - Segments

    private func sections(_ model: TaskDetailModel, tab: TaskDetailTab) -> some View {
        TabHost(model: model, tab: tab)
    }

    func testSegmentAll() { check(sections(countingModel, tab: .all), height: 900) }
    func testSegmentAllCompound() { check(sections(compoundModel, tab: .all), height: 900) }
    func testSegmentBoards() { check(sections(countingModel, tab: .boards), height: 760) }
    func testSegmentLinksCounting() { check(sections(countingModel, tab: .links), height: 560) }
    func testSegmentLinksCompound() { check(sections(compoundModel, tab: .links), height: 520) }
    func testSegmentLinksAchievement() { check(sections(achievementModel, tab: .links), height: 300) }
    func testSegmentActivity() { check(sections(countingModel, tab: .activity), height: 620) }
    func testSegmentBoardsNoAnchor() { check(sections(noAnchorModel, tab: .boards), height: 400) }

    // MARK: - Full screen (hero over sections)

    func testScreenNormalRoute() {
        check(TabScreen(model: normalModel, tab: .all, presentation: .route), height: 1000)
    }
}

private struct TabHost: View {
    let model: TaskDetailModel
    @State var tab: TaskDetailTab

    init(model: TaskDetailModel, tab: TaskDetailTab) {
        self.model = model
        _tab = State(initialValue: tab)
    }

    var body: some View { TaskDetailSectionsView(model: model, tab: $tab) }
}

private struct TabScreen: View {
    let model: TaskDetailModel
    @State var tab: TaskDetailTab
    let presentation: TaskDetailPresentation

    init(model: TaskDetailModel, tab: TaskDetailTab, presentation: TaskDetailPresentation) {
        self.model = model
        _tab = State(initialValue: tab)
        self.presentation = presentation
    }

    var body: some View { TaskDetailScreen(model: model, presentation: presentation, tab: $tab) }
}
