import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the Counters Hub + Counter Detail (Shared Counters
/// P5 "+ New counter" flow, and the R2 Counters UX refresh — Hub/Detail
/// redesign, amount-chip logging, the reusable log/Undo toast). Fixture
/// literals mirror the `#Preview`s in `CountersHubView.swift` /
/// `NewCounterSheetView.swift` / `CounterDetailView.swift` /
/// `CounterLogToastView.swift` — one source of truth for both the Xcode
/// canvas and this CLI-driven suite.
final class CountersHubSnapshotTests: XCTestCase {

    private let recordMode: SnapshotTestingConfiguration.Record? = .missing

    // MARK: - Fixtures

    private func makeGroupWithMembers() -> SharedCounterGroup {
        let src = SharedCounterMemberTask(
            taskId: "src", taskTitle: "Push-ups", isSource: true,
            boardId: "bm", boardName: "February Fitness",
            timeframe: .monthly, window: "February 2026",
            goal: 1000, logged: 512, met: false, over: 0, isActive: true
        )
        let der = SharedCounterMemberTask(
            taskId: "der", taskTitle: "Push-ups", isSource: false,
            boardId: "bw", boardName: "Week 5 Wellness",
            timeframe: .weekly, window: "Week of Feb 3 – 9, 2026",
            goal: 30, logged: 45, met: true, over: 15, isActive: true
        )
        return SharedCounterGroup(
            counterId: "src", name: "Push-ups", action: "Do", unit: "reps",
            lifetime: 512, defaultLogAmount: 10,
            tasks: [src, der], taskCount: 2, boardCount: 2, activeTaskCount: 2
        )
    }

    private func makeSingleMemberGroup() -> SharedCounterGroup {
        let src = SharedCounterMemberTask(
            taskId: "src", taskTitle: "Morning runs", isSource: true,
            boardId: "b1", boardName: "April Running",
            timeframe: .monthly, window: "April 2026",
            goal: 20, logged: 7, met: false, over: 0, isActive: true
        )
        return SharedCounterGroup(
            counterId: "src", name: "Morning runs", action: "Go for", unit: "runs",
            lifetime: 7, defaultLogAmount: 5,
            tasks: [src], taskCount: 1, boardCount: 1, activeTaskCount: 1
        )
    }

    /// Sample 7-day daily totals for sparkline-bearing Detail snapshots —
    /// deterministic, doesn't depend on the real device clock.
    private func makeDailyTotals() -> CounterDailyTotalsResult {
        CounterDailyTotalsResult(
            days: [
                CounterDailyTotal(dateISO: "2026-01-26", total: 12),
                CounterDailyTotal(dateISO: "2026-01-27", total: 0),
                CounterDailyTotal(dateISO: "2026-01-28", total: 30),
                CounterDailyTotal(dateISO: "2026-01-29", total: 8),
                CounterDailyTotal(dateISO: "2026-01-30", total: 15),
                CounterDailyTotal(dateISO: "2026-01-31", total: 20),
                CounterDailyTotal(dateISO: "2026-02-01", total: 10),
            ],
            todayTotal: 10
        )
    }

    // MARK: - Hub — populated

    func testHubPopulatedLight() {
        let group = makeGroupWithMembers()
        let host = NavigationStack { CountersHubContent(groups: [group]) }
        assertSnapshot(of: host, as: .image(layout: .fixed(width: 393, height: 560)), record: recordMode)
    }

    func testHubPopulatedDark() {
        let group = makeGroupWithMembers()
        let host = NavigationStack { CountersHubContent(groups: [group]) }
        assertSnapshot(
            of: host,
            as: .image(layout: .fixed(width: 393, height: 560), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }

    // MARK: - Hub — empty (W3 empty-state copy + CTA; "New counter" header button hidden)

    func testHubEmptyLight() {
        let host = NavigationStack { CountersHubContent(groups: []) }
        assertSnapshot(of: host, as: .image(layout: .fixed(width: 393, height: 480)), record: recordMode)
    }

    func testHubEmptyDark() {
        let host = NavigationStack { CountersHubContent(groups: []) }
        assertSnapshot(
            of: host,
            as: .image(layout: .fixed(width: 393, height: 480), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }

    // MARK: - New counter sheet — default (empty fields)

    @ViewBuilder
    private func sheetHost(
        verb: String,
        unit: String,
        previewName: String,
        match: CounterCreateMatch?
    ) -> some View {
        NavigationStack {
            ScrollView {
                NewCounterSheetContentView(
                    verb: .constant(verb),
                    unit: .constant(unit),
                    startingCountText: .constant(""),
                    previewName: previewName,
                    previewCount: 0,
                    trimmedUnit: unit,
                    match: match
                )
                .padding(16)
            }
            .background(Color.risoPaper.ignoresSafeArea())
        }
    }

    func testNewCounterSheetDefaultLight() {
        let host = sheetHost(verb: "", unit: "", previewName: "", match: nil)
        assertSnapshot(of: host, as: .image(layout: .fixed(width: 393, height: 460)), record: recordMode)
    }

    func testNewCounterSheetDefaultDark() {
        let host = sheetHost(verb: "", unit: "", previewName: "", match: nil)
        assertSnapshot(
            of: host,
            as: .image(layout: .fixed(width: 393, height: 460), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }

    // MARK: - New counter sheet — established match (Create disabled, "Open {CounterName}")

    func testNewCounterSheetEstablishedMatchLight() {
        let now = "2026-02-01T00:00:00.000"
        let sourceTask = Task(
            id: "src", userId: "u1", title: "Push-ups", type: .counting,
            action: "Do", unit: "push-ups",
            totalCompletions: 0, totalInstances: 0,
            currentCount: 512,
            createdAt: now, updatedAt: now,
            version: 1, isDeleted: false, isCounter: true
        )
        let match = CounterCreateMatch(kind: .established, task: sourceTask, lifetime: 512, memberCount: 2)
        let host = sheetHost(verb: "", unit: "push-ups", previewName: "Push-ups", match: match)
        assertSnapshot(of: host, as: .image(layout: .fixed(width: 393, height: 660)), record: recordMode)
    }

    func testNewCounterSheetEstablishedMatchDark() {
        let now = "2026-02-01T00:00:00.000"
        let sourceTask = Task(
            id: "src", userId: "u1", title: "Push-ups", type: .counting,
            action: "Do", unit: "push-ups",
            totalCompletions: 0, totalInstances: 0,
            currentCount: 512,
            createdAt: now, updatedAt: now,
            version: 1, isDeleted: false, isCounter: true
        )
        let match = CounterCreateMatch(kind: .established, task: sourceTask, lifetime: 512, memberCount: 2)
        let host = sheetHost(verb: "", unit: "push-ups", previewName: "Push-ups", match: match)
        assertSnapshot(
            of: host,
            as: .image(layout: .fixed(width: 393, height: 660), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }

    // MARK: - Detail — single member (R2: grew — hero sparkline, stat strip, amount-chip log card, history)

    func testDetailSingleMemberLight() {
        let group = makeSingleMemberGroup()
        let host = NavigationStack { CounterDetailContent(group: group, dailyTotals: makeDailyTotals()) }
        assertSnapshot(of: host, as: .image(layout: .fixed(width: 393, height: 1180)), record: recordMode)
    }

    func testDetailSingleMemberDark() {
        let group = makeSingleMemberGroup()
        let host = NavigationStack { CounterDetailContent(group: group, dailyTotals: makeDailyTotals()) }
        assertSnapshot(
            of: host,
            as: .image(layout: .fixed(width: 393, height: 1180), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }

    // MARK: - Detail — amount-chip log card states (R2)

    /// Custom "#" chip active with a value that doesn't collide with any
    /// fixed chip (1 / default=10 / 25) — proves the custom chip renders the
    /// live `selectedAmount` instead of its static "#" label once selected.
    func testDetailCustomChipActiveLight() {
        let group = makeGroupWithMembers()
        let host = NavigationStack {
            CounterDetailContent(
                group: group, dailyTotals: makeDailyTotals(),
                initialSelectedAmount: 42, initialCustomActive: true
            )
        }
        assertSnapshot(of: host, as: .image(layout: .fixed(width: 393, height: 620)), record: recordMode)
    }

    func testDetailCustomChipActiveDark() {
        let group = makeGroupWithMembers()
        let host = NavigationStack {
            CounterDetailContent(
                group: group, dailyTotals: makeDailyTotals(),
                initialSelectedAmount: 42, initialCustomActive: true
            )
        }
        assertSnapshot(
            of: host,
            as: .image(layout: .fixed(width: 393, height: 620), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }

    func testDetailLoggingStateLight() {
        let group = makeGroupWithMembers()
        let host = NavigationStack {
            CounterDetailContent(group: group, dailyTotals: makeDailyTotals(), isLogging: true)
        }
        assertSnapshot(of: host, as: .image(layout: .fixed(width: 393, height: 620)), record: recordMode)
    }

    // MARK: - Log toast (R2 — reusable "Logged +N · Undo" / "Removed N · Undo")

    private func toastHost(amount: Int, unit: String, verb: CounterLogToastView.Verb) -> some View {
        ZStack {
            RisoPaperBackground()
            VStack {
                Spacer()
                CounterLogToastView(amount: amount, unit: unit, verb: verb, onUndo: {}, onDone: {})
                    .padding(.horizontal, Riso.gutter)
                    .padding(.bottom, 24)
            }
        }
    }

    func testLogToastLoggedLight() {
        let host = toastHost(amount: 10, unit: "push-ups", verb: .logged)
        assertSnapshot(of: host, as: .image(layout: .fixed(width: 393, height: 120)), record: recordMode)
    }

    func testLogToastLoggedDark() {
        let host = toastHost(amount: 10, unit: "push-ups", verb: .logged)
        assertSnapshot(
            of: host,
            as: .image(layout: .fixed(width: 393, height: 120), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }

    func testLogToastRemovedLight() {
        let host = toastHost(amount: 5, unit: "reps", verb: .removed)
        assertSnapshot(of: host, as: .image(layout: .fixed(width: 393, height: 120)), record: recordMode)
    }
}
