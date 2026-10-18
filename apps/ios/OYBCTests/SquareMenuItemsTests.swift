import XCTest
@testable import OYBC

/// Pins the unified hold-menu vocabulary (docs/TASK_DETAIL_REDESIGN.md §PR 3).
/// Web twin: `squareMenuItems.test.ts` — keep the strings identical.
final class SquareMenuItemsTests: XCTestCase {

    /// Flattens entries to "label[|meta]" strings with "─" for dividers.
    private func rows(_ input: SquareMenuInput) -> [String] {
        SquareMenu.entries(for: input).map { entry in
            switch entry {
            case .divider: return "─"
            case let .item(i): return i.meta.map { "\(i.label)|\($0)" } ?? i.label
            }
        }
    }

    private func counting(
        _ kind: CountKind = .discrete, unit: String = "pages", current: CountValue = 12, goal: CountValue = 20, remembered: CountValue? = nil
    ) -> SquareMenuInput.Counting {
        .init(kind: kind, unit: unit, current: current, goal: goal, rememberedDefault: remembered)
    }

    private func input(
        _ body: SquareMenuInput.Body, title: String = "Read 20 pages", kind: RisoTaskKind = .counting,
        closed: Bool = false, routable: Bool = true, busy: Bool = false
    ) -> SquareMenuInput {
        SquareMenuInput(title: title, kind: kind, body: body, isClosed: closed, lateLogRoutable: routable, isBusy: busy)
    }

    // MARK: Normal

    func testNormal() {
        XCTAssertEqual(rows(input(.normal(isDone: false, sealBlocked: false), kind: .normal)), ["Mark done", "─", "Details", "Open in library"])
        XCTAssertEqual(rows(input(.normal(isDone: true, sealBlocked: false), kind: .normal)), ["Mark not done", "─", "Details", "Open in library"])
    }

    func testNormalSealBlockedUncompleteIsDisabled() {
        let entries = SquareMenu.entries(for: input(.normal(isDone: true, sealBlocked: true), kind: .normal))
        guard case let .item(first) = entries[0] else { return XCTFail() }
        XCTAssertFalse(first.isEnabled)
        XCTAssertTrue(first.isPrimary)
    }

    // MARK: Counting

    func testCountingDiscreteNoDefaultQuickIsOneAndNextIsTheNextPreset() {
        XCTAssertEqual(rows(input(.counting(counting()))), [
            "Log +1 pages", "Log +10 pages", "Log other amount…", "─", "Remove pages…", "─", "Details", "Open in library",
        ])
    }

    func testCountingRememberedDefaultLeadsAndNextPresetIsAboveIt() {
        XCTAssertEqual(rows(input(.counting(counting(remembered: 5)))).prefix(3), ["Log +5 pages", "Log +10 pages", "Log other amount…"])
        XCTAssertEqual(SquareMenu.nextPreset(above: 10, kind: .discrete), 25)
        XCTAssertNil(SquareMenu.nextPreset(above: 25, kind: .discrete), "no preset above the top one")
        // A default at the top preset omits the second item.
        XCTAssertEqual(rows(input(.counting(counting(remembered: 25)))).prefix(2), ["Log +25 pages", "Log other amount…"])
    }

    func testCountingContinuousAndDurationUseTheirFixedPresets() {
        XCTAssertEqual(rows(input(.counting(counting(.continuous, unit: "mi")))).prefix(3), ["Log +0.5 mi", "Log +1 mi", "Log other amount…"])
        XCTAssertEqual(rows(input(.counting(counting(.duration, unit: "guitar")))).prefix(3), ["Log +15m", "Log +30m", "Log other amount…"])
        XCTAssertTrue(rows(input(.counting(counting(.duration, unit: "guitar")))).contains("Remove…"), "duration has no unit noun")
        XCTAssertTrue(rows(input(.counting(counting(.continuous, unit: "mi")))).contains("Remove mi…"))
    }

    func testCountingRemoveDisabledAtZeroAndWritesDisabledWhenBusy() {
        let zero = SquareMenu.entries(for: input(.counting(counting(current: 0))))
        let remove = zero.compactMap { e -> SquareMenuItem? in if case let .item(i) = e, i.action == .remove { return i }; return nil }.first
        XCTAssertEqual(remove?.isEnabled, false)

        let busy = SquareMenu.entries(for: input(.counting(counting()), busy: true))
        for case let .item(i) in busy where i.isWrite { XCTAssertFalse(i.isEnabled, i.label) }
        for case let .item(i) in busy where !i.isWrite && i.action != .remove { XCTAssertTrue(i.isEnabled, i.label) }
    }

    func testMetaLines() {
        XCTAssertEqual(SquareMenu.meta(input(.counting(counting()))), "12 / 20")
        XCTAssertEqual(SquareMenu.meta(input(.counting(counting(current: 20)))), "20 / 20", "plain count — no Done suffix")
        XCTAssertEqual(SquareMenu.meta(input(.counting(counting(.duration, current: 270, goal: 630)))), "4h 30m / 10h 30m")
        XCTAssertEqual(SquareMenu.meta(input(.normal(isDone: false, sealBlocked: false), kind: .normal)), "Not done")
        XCTAssertEqual(SquareMenu.meta(input(.achievement(isMet: false, watchedName: "October", openBoardId: "b"), kind: .achievement)), "Watching")
        XCTAssertEqual(SquareMenu.headerText(input(.counting(counting()))), "Read 20 pages · 12 / 20")
    }

    // MARK: Compound

    private func compound(next: TaskDetailKernel.SubtaskAction?, title: String? = "Drink water", child: SquareMenuInput.Counting? = nil, done: Int = 1, total: Int = 3) -> SquareMenuInput {
        input(.compound(.init(next: next, nextChildTitle: title, nextChild: child, doneCount: done, total: total)), title: "Daily wellness", kind: .compound)
    }

    func testCompoundToggleChild() {
        XCTAssertEqual(rows(compound(next: .toggle(childId: "a"))), ["Complete next sub-task|Drink water", "All sub-tasks…|1 / 3", "─", "Open in library"])
    }

    func testCompoundOnlyCountingChildrenRemainBecomesALogItem() {
        XCTAssertEqual(
            rows(compound(next: .log(childId: "c"), title: "Read 20 pages", child: counting(remembered: 5))),
            ["Log +5 pages · Read 20 pages", "All sub-tasks…|1 / 3", "─", "Open in library"]
        )
    }

    func testCompoundAllDoneHasNoLeadItem() {
        XCTAssertEqual(rows(compound(next: nil, title: nil, done: 3)), ["All sub-tasks…|3 / 3", "─", "Open in library"])
    }

    // MARK: Achievement

    func testAchievement() {
        XCTAssertEqual(
            rows(input(.achievement(isMet: false, watchedName: "October", openBoardId: "b9"), title: "Bingo", kind: .achievement)),
            ["Open October", "─", "Details", "Open in library"]
        )
        XCTAssertEqual(
            rows(input(.achievement(isMet: false, watchedName: "Weekly reset", openBoardId: nil), title: "Bingo", kind: .achievement)),
            ["Details", "Open in library"], "a template watcher has no board to open"
        )
    }

    // MARK: Closed board

    func testClosedBoardCollapsesWritesToOneLateLog() {
        XCTAssertEqual(rows(input(.normal(isDone: true, sealBlocked: false), kind: .normal, closed: true)), ["Late log…", "─", "Details", "Open in library"])
        XCTAssertEqual(rows(input(.counting(counting()), closed: true)), ["Late log…", "─", "Details", "Open in library"])
        XCTAssertEqual(rows(compound(next: .toggle(childId: "a")).closedCopy()), ["Late log…", "─", "All sub-tasks…|1 / 3", "─", "Open in library"])
        XCTAssertEqual(
            rows(input(.achievement(isMet: false, watchedName: "October", openBoardId: "b9"), kind: .achievement, closed: true)),
            ["Open October", "─", "Details", "Open in library"], "opening a board is not a write"
        )
    }

    func testClosedCompoundWithoutLateLogHasNoLeadingDivider() {
        let closed = SquareMenuInput(
            title: "Daily wellness", kind: .compound,
            body: .compound(.init(next: .toggle(childId: "a"), nextChildTitle: "x", nextChild: nil, doneCount: 1, total: 3)),
            isClosed: true, lateLogRoutable: false
        )
        XCTAssertEqual(rows(closed), ["All sub-tasks…|1 / 3", "─", "Open in library"])
    }

    /// The menu builds from the precomputed set — never the database.
    func testSealBlockedReadsTheCachedSet() {
        XCTAssertTrue(SquareMenu.sealBlocked(isDone: true, isClosed: false, taskId: "a", cached: ["a"]))
        XCTAssertFalse(SquareMenu.sealBlocked(isDone: true, isClosed: false, taskId: "b", cached: ["a"]))
        XCTAssertFalse(SquareMenu.sealBlocked(isDone: false, isClosed: false, taskId: "a", cached: ["a"]), "not done → nothing to un-complete")
        XCTAssertFalse(SquareMenu.sealBlocked(isDone: true, isClosed: true, taskId: "a", cached: ["a"]), "closed boards collapse writes anyway")
    }

    func testClosedBoardWithoutRoutableLateLogDropsTheItem() {
        XCTAssertEqual(rows(input(.counting(counting()), closed: true, routable: false)), ["Details", "Open in library"])
    }

    func testLateLogIsPrimaryWithALock() {
        let entries = SquareMenu.entries(for: input(.counting(counting()), closed: true))
        guard case let .item(first) = entries[0] else { return XCTFail() }
        XCTAssertEqual(first.action, .lateLog)
        XCTAssertEqual(first.icon, "lock")
        XCTAssertTrue(first.isPrimary)
    }
}

private extension SquareMenuInput {
    func closedCopy() -> SquareMenuInput {
        SquareMenuInput(title: title, kind: kind, body: body, isClosed: true, lateLogRoutable: true, isBusy: isBusy)
    }
}
