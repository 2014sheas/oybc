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

    private func makeContinuousDurationGroups() -> [SharedCounterGroup] {
        func member(_ id: String, _ board: String, _ window: String, _ tf: Timeframe, _ goal: CountValue, _ logged: CountValue) -> SharedCounterMemberTask {
            SharedCounterMemberTask(
                taskId: id, taskTitle: board, isSource: false, boardId: id, boardName: board,
                timeframe: tf, window: window, goal: goal, logged: logged,
                met: logged >= goal, over: max(0, logged - goal), isActive: true
            )
        }
        let miles = SharedCounterGroup(
            counterId: "miles", name: "Miles", action: "Run", unit: "mi",
            lifetime: 148.6, defaultLogAmount: 3.1,
            tasks: [member("m1", "Spring marathon", "Apr", .monthly, 26.2, 12.4),
                    member("m2", "Daily grind", "Wk 14", .weekly, 26.2, 28.4)],
            taskCount: 2, boardCount: 2, activeTaskCount: 2, countKind: .continuous
        )
        let practice = SharedCounterGroup(
            counterId: "practice", name: "Practice", action: "Practice", unit: "guitar",
            lifetime: 6735, defaultLogAmount: 30,
            tasks: [member("p1", "Music week", "Wk 14", .weekly, 630, 270)],
            taskCount: 1, boardCount: 1, activeTaskCount: 1, countKind: .duration
        )
        return [miles, practice]
    }

    func testHubContinuousDurationLight() {
        let host = NavigationStack { CountersHubContent(groups: makeContinuousDurationGroups()) }
        assertSnapshot(of: host, as: .image(layout: .fixed(width: 393, height: 640)), record: recordMode)
    }

    func testHubContinuousDurationDark() {
        let host = NavigationStack { CountersHubContent(groups: makeContinuousDurationGroups()) }
        assertSnapshot(
            of: host,
            as: .image(layout: .fixed(width: 393, height: 640), traits: .init(userInterfaceStyle: .dark)),
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

    // MARK: - Counter sheet (create + edit; docs/SHARED_COUNTER_SETTINGS.md §1)

    @ViewBuilder
    private func sheetHost(
        _ form: CounterSheetForm,
        touched: Set<CounterSheetField> = [],
        match: CounterCreateMatch? = nil,
        startFromInvalid: Bool = false,
        isEditing: Bool = false,
        kindLock: KindPickerLock = .none
    ) -> some View {
        NavigationStack {
            ScrollView {
                NewCounterSheetContentView(
                    form: .constant(form),
                    touched: .constant(touched),
                    startFromInvalid: startFromInvalid,
                    match: match,
                    isEditing: isEditing,
                    kindLock: kindLock
                )
                .padding(16)
            }
            .background(Color.risoPaper.ignoresSafeArea())
        }
    }

    private func assertSheet(_ form: @autoclosure () -> some View, height: CGFloat, dark: Bool, name: String = #function) {
        assertSnapshot(
            of: form(),
            as: .image(layout: .fixed(width: 393, height: height), traits: .init(userInterfaceStyle: dark ? .dark : .light)),
            record: recordMode, testName: name
        )
    }

    /// The Edit-mode fixture: stored name + singular SOLID, plural and the
    /// Daily / Monthly / Yearly defaults derived from Weekly 2 and DIMMED.
    private var editForm: CounterSheetForm {
        CounterSheetForm(
            verb: "Read", noun: "books", name: "Books", singular: "Read #N book",
            kind: .discrete, goalTexts: [.weekly: "2"]
        )
    }

    private var durationForm: CounterSheetForm {
        CounterSheetForm(
            verb: "Practice", noun: "piano", name: "Piano", kind: .duration,
            goalTexts: [.weekly: "300"]
        )
    }

    func testNewCounterSheetDefaultLight() {
        assertSheet(sheetHost(CounterSheetForm()), height: 900, dark: false)
    }

    func testNewCounterSheetDefaultDark() {
        assertSheet(sheetHost(CounterSheetForm()), height: 900, dark: true)
    }

    /// Both required fields emptied after editing: red keylines + inline errors.
    func testNewCounterSheetValidationLight() {
        assertSheet(sheetHost(CounterSheetForm(), touched: [.noun, .verb]), height: 960, dark: false)
    }

    func testNewCounterSheetValidationDark() {
        assertSheet(sheetHost(CounterSheetForm(), touched: [.noun, .verb]), height: 960, dark: true)
    }

    /// Noun + verb typed: the dimmed name + templates appear, Defaults stay empty.
    func testNewCounterSheetContinuousLight() {
        let form = CounterSheetForm(verb: "Run", noun: "miles", startText: "148.6", kind: .continuous)
        assertSheet(sheetHost(form), height: 900, dark: false)
    }

    func testNewCounterSheetContinuousDark() {
        let form = CounterSheetForm(verb: "Run", noun: "miles", startText: "148.6", kind: .continuous)
        assertSheet(sheetHost(form), height: 900, dark: true)
    }

    /// Counter Detail "Edit counter…" — the sheet in EDIT mode: Duration
    /// locked out (an existing Discrete counter), no "Start from".
    func testEditCounterSheetLight() {
        assertSheet(
            sheetHost(editForm, isEditing: true, kindLock: kindPickerLock(mode: .edit, kind: .discrete)),
            height: 820, dark: false
        )
    }

    func testEditCounterSheetDark() {
        assertSheet(
            sheetHost(editForm, isEditing: true, kindLock: kindPickerLock(mode: .edit, kind: .discrete)),
            height: 820, dark: true
        )
    }

    /// Duration: h:m Defaults entries (derived ones dimmed), no unit suffix.
    func testEditCounterSheetDurationLight() {
        assertSheet(
            sheetHost(durationForm, isEditing: true, kindLock: kindPickerLock(mode: .edit, kind: .duration)),
            height: 880, dark: false
        )
    }

    func testEditCounterSheetDurationDark() {
        assertSheet(
            sheetHost(durationForm, isEditing: true, kindLock: kindPickerLock(mode: .edit, kind: .duration)),
            height: 880, dark: true
        )
    }

    /// I4 — an unparseable "Start from" (3 decimals on Continuous) draws the
    /// field's invalid state (red keyline).
    func testNewCounterSheetStartFromInvalidLight() {
        let form = CounterSheetForm(verb: "Run", noun: "miles", startText: "3.125", kind: .continuous)
        assertSheet(sheetHost(form, startFromInvalid: true), height: 900, dark: false)
    }

    func testNewCounterSheetStartFromInvalidDark() {
        let form = CounterSheetForm(verb: "Run", noun: "miles", startText: "3.125", kind: .continuous)
        assertSheet(sheetHost(form, startFromInvalid: true), height: 900, dark: true)
    }

    // MARK: - New counter sheet — established match (Create disabled, "Open {CounterName}")

    private var establishedMatch: CounterCreateMatch {
        let now = "2026-02-01T00:00:00.000"
        let sourceTask = Task(
            id: "src", userId: "u1", title: "Push-ups", type: .counting,
            action: "Do", unit: "push-ups",
            totalCompletions: 0, totalInstances: 0,
            currentCount: 512,
            createdAt: now, updatedAt: now,
            version: 1, isDeleted: false, isCounter: true
        )
        return CounterCreateMatch(kind: .established, task: sourceTask, lifetime: 512, memberCount: 2)
    }

    func testNewCounterSheetEstablishedMatchLight() {
        let form = CounterSheetForm(verb: "Do", noun: "push-ups")
        assertSheet(sheetHost(form, match: establishedMatch), height: 1020, dark: false)
    }

    func testNewCounterSheetEstablishedMatchDark() {
        let form = CounterSheetForm(verb: "Do", noun: "push-ups")
        assertSheet(sheetHost(form, match: establishedMatch), height: 1020, dark: true)
    }

    // MARK: - Detail — "Show expired tasks" toggle (the hub's control, RC9)

    func testDetailShowExpiredToggleLight() {
        let group = makeGroupWithMembers()
        let host = NavigationStack {
            CounterDetailContent(group: group, dailyTotals: makeDailyTotals(), showExpired: .constant(true))
        }
        assertSnapshot(of: host, as: .image(layout: .fixed(width: 393, height: 1400)), record: recordMode)
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

    // MARK: - Detail — Continuous / Duration (counter kinds, handoff `logCards[]` / `detailCards[]`)

    func testDetailContinuousLight() {
        let host = NavigationStack { CounterDetailContent(group: makeContinuousDurationGroups()[0], dailyTotals: makeDailyTotals()) }
        assertSnapshot(of: host, as: .image(layout: .fixed(width: 393, height: 1000)), record: recordMode)
    }

    func testDetailContinuousDark() {
        let host = NavigationStack { CounterDetailContent(group: makeContinuousDurationGroups()[0], dailyTotals: makeDailyTotals()) }
        assertSnapshot(
            of: host,
            as: .image(layout: .fixed(width: 393, height: 1000), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }

    func testDetailDurationLight() {
        let host = NavigationStack { CounterDetailContent(group: makeContinuousDurationGroups()[1], dailyTotals: makeDailyTotals()) }
        assertSnapshot(of: host, as: .image(layout: .fixed(width: 393, height: 900)), record: recordMode)
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

    private func toastHost(amount: CountValue, unit: String, verb: CounterLogToastView.Verb) -> some View {
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
