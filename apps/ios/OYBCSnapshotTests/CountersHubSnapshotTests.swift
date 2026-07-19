import XCTest
import SwiftUI
import SnapshotTesting
@testable import OYBC

/// Snapshot coverage for the Counters Hub "+ New counter" flow (Shared
/// Counters P5, PR-2): the hub with groups, the empty state with its CTA,
/// the "New counter" sheet content (default + established-match states), and
/// the Counter Detail page with a single member. Fixture literals mirror the
/// `#Preview`s in `CountersHubView.swift` / `NewCounterSheetView.swift` /
/// `CounterDetailView.swift` — one source of truth for both the Xcode
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
            lifetime: 512, tasks: [src, der], taskCount: 2, boardCount: 2, activeTaskCount: 2
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
            lifetime: 7, tasks: [src], taskCount: 1, boardCount: 1, activeTaskCount: 1
        )
    }

    // MARK: - Hub — populated

    func testHubPopulatedLight() {
        let group = makeGroupWithMembers()
        let host = NavigationStack { CountersHubContent(groups: [group]) }
        assertSnapshot(of: host, as: .image(layout: .fixed(width: 393, height: 520)), record: recordMode)
    }

    func testHubPopulatedDark() {
        let group = makeGroupWithMembers()
        let host = NavigationStack { CountersHubContent(groups: [group]) }
        assertSnapshot(
            of: host,
            as: .image(layout: .fixed(width: 393, height: 520), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }

    // MARK: - Hub — empty (W3 empty-state copy + CTA)

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

    // MARK: - Detail — single member

    func testDetailSingleMemberLight() {
        let group = makeSingleMemberGroup()
        let host = NavigationStack { CounterDetailContent(group: group) }
        assertSnapshot(of: host, as: .image(layout: .fixed(width: 393, height: 900)), record: recordMode)
    }

    func testDetailSingleMemberDark() {
        let group = makeSingleMemberGroup()
        let host = NavigationStack { CounterDetailContent(group: group) }
        assertSnapshot(
            of: host,
            as: .image(layout: .fixed(width: 393, height: 900), traits: .init(userInterfaceStyle: .dark)),
            record: recordMode
        )
    }
}
