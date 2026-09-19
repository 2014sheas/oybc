import XCTest
@testable import OYBC

/// Board Sources §Member rules (B3) — the pure presentation model behind a
/// wizard member row (`RisoMemberRuleRowView.swift`).
///
/// These pin the decisions a SwiftUI snapshot can only show indirectly:
/// which controls a pool member gets vs a board member, what a One-square
/// compound's note says, which part still offers a ✕, and whose dice level
/// a part reads. `BoardWizardTasksStepView`-free by construction — the
/// model takes plain values.
final class MemberRuleRowModelTests: XCTestCase {

    // MARK: - Fixtures

    private let daily = BoardSources.BoardWindow(timeframe: .daily)
    private let weekly = BoardSources.BoardWindow(timeframe: .weekly)

    private func task(
        _ id: String,
        type: TaskType = .normal,
        title: String? = nil,
        maxCount: Int? = nil,
        unit: String? = nil
    ) -> Task {
        Task(
            id: id,
            userId: "u1",
            title: title ?? id,
            type: type,
            unit: unit,
            maxCount: maxCount,
            totalCompletions: 0,
            totalInstances: 0,
            createdAt: "t",
            updatedAt: "t",
            version: 1,
            isDeleted: false
        )
    }

    private func child(_ compound: String, _ childId: String, _ index: Int) -> CompoundChild {
        CompoundChild(
            id: "link-\(childId)",
            compoundTaskId: compound,
            childTaskId: childId,
            childIndex: index,
            createdAt: "t",
            updatedAt: "t",
            version: 1,
            isDeleted: false
        )
    }

    private func model(
        task: Task?,
        taskById: [String: Task] = [:],
        state: MemberRuleRowState = .included,
        rule: BoardSourceMemberRule = BoardSourceMemberRule(),
        parts: [CompoundChild] = [],
        fromBoard: Bool = true,
        sourceWindow: BoardSources.BoardWindow? = nil,
        wizardWindow: BoardSources.BoardWindow? = nil,
        mode: BoardSources.PlanMode = .oneOff
    ) -> MemberRuleRowModel {
        MemberRuleRowModel(
            task: task,
            taskById: taskById,
            state: state,
            rule: rule,
            parts: parts,
            fromBoard: fromBoard,
            sourceWindow: sourceWindow,
            wizardWindow: wizardWindow ?? daily,
            mode: mode
        )
    }

    // MARK: - Counting members

    /// A BOARD-sourced counting member gets the stepper + caption + dice;
    /// the caption quotes the goal and the unit, never the target.
    func testBoardCountingMemberGetsStepperCaptionAndDice() {
        let m = model(task: task("c", type: .counting, maxCount: 100, unit: "pages"))
        XCTAssertTrue(m.showsStepper)
        XCTAssertTrue(m.showsDice)
        XCTAssertEqual(m.caption, "of 100 pages")
        XCTAssertEqual(m.goal, 100)
        XCTAssertEqual(m.target, 100)
        XCTAssertNil(m.rangeLabel, "dice off ⇒ no range line")
        XCTAssertFalse(m.isCompound)
        XCTAssertTrue(m.parts.isEmpty)
    }

    /// RC5 — a POOL member has no window to pro-rate against, so it gets
    /// the dice ALONE: no stepper and, with it, no caption.
    func testPoolCountingMemberGetsDiceButNoStepper() {
        let m = model(task: task("c", type: .counting, maxCount: 100, unit: "pages"), fromBoard: false)
        XCTAssertFalse(m.showsStepper)
        XCTAssertNil(m.caption)
        XCTAssertTrue(m.showsDice)
    }

    /// A unit-less counting member's caption omits the trailing space.
    func testCaptionOmitsMissingUnit() {
        let m = model(task: task("c", type: .counting, maxCount: 12))
        XCTAssertEqual(m.caption, "of 12")
    }

    /// An explicit stored target wins over the auto/goal fallback.
    func testExplicitTargetOverridesGoal() {
        let m = model(
            task: task("c", type: .counting, maxCount: 100),
            rule: BoardSourceMemberRule(target: 7)
        )
        XCTAssertEqual(m.target, 7)
        XCTAssertEqual(m.goal, 100, "the ceiling stays the goal")
    }

    /// Recurring + board source pro-rates a weekly goal onto a daily
    /// window (the `effectiveMemberTarget` gate), where a ONE-OFF board on
    /// the same inputs would not.
    func testRecurringBoardSourceProRatesWhereOneOffDoesNot() {
        let counting = task("c", type: .counting, maxCount: 14)
        let recurring = model(
            task: counting, sourceWindow: weekly, wizardWindow: daily, mode: .recurring
        )
        let oneOff = model(
            task: counting, sourceWindow: weekly, wizardWindow: daily, mode: .oneOff
        )
        XCTAssertEqual(recurring.target, 2, "14 over 7 days ⇒ 2 a day")
        XCTAssertEqual(oneOff.target, 14)
    }

    /// Dice on ⇒ a blue range line spread around the TARGET, not the
    /// goal. The literal is asserted (never the helper re-applied to the
    /// same arguments) and target ≠ goal, so swapping `t:`/`goal:` — or
    /// feeding the goal where the target belongs — fails here.
    func testDiceOnProducesRangeLineAroundTheTarget() {
        let m = model(
            task: task("c", type: .counting, maxCount: 100, unit: "pages"),
            rule: BoardSourceMemberRule(target: 40, vary: .little)
        )
        XCTAssertEqual(m.memberVary, .little)
        XCTAssertEqual(m.target, 40)
        // ±20 % of 40, clamped to 1…100.
        XCTAssertEqual(m.rangeLabel, "32\u{2013}48 pages")
    }

    /// A unit-less member's range line carries no trailing unit.
    func testRangeLineOmitsMissingUnit() {
        let m = model(
            task: task("c", type: .counting, maxCount: 100),
            rule: BoardSourceMemberRule(target: 40, vary: .lot)
        )
        // ±50 % of 40.
        XCTAssertEqual(m.rangeLabel, "20\u{2013}60")
    }

    // MARK: - Non-included members

    /// Web round-1 decision: an EXCLUDED member renders exactly what it
    /// did before B3 — no stepper, no dice, no range line, no part lines.
    func testExcludedMemberRendersNoRuleControls() {
        let m = model(
            task: task("c", type: .counting, maxCount: 100),
            state: .excluded,
            rule: BoardSourceMemberRule(target: 5, vary: .lot)
        )
        XCTAssertFalse(m.isOn)
        XCTAssertFalse(m.showsStepper)
        XCTAssertFalse(m.showsDice)
        XCTAssertNil(m.caption)
        XCTAssertNil(m.rangeLabel)
    }

    /// Same for a member filtered out as already done.
    func testFilteredDoneMemberRendersNoRuleControls() {
        let m = model(
            task: task("c", type: .counting, maxCount: 100),
            state: .filteredDone,
            rule: BoardSourceMemberRule(vary: .lot)
        )
        XCTAssertFalse(m.showsDice)
        XCTAssertNil(m.rangeLabel)
    }

    /// An excluded COMPOUND keeps no split line and no part lines either.
    func testExcludedCompoundHasNoSplitLineOrParts() {
        let m = model(
            task: task("C", type: .compound),
            taskById: ["p1": task("p1"), "p2": task("p2")],
            state: .excluded,
            rule: BoardSourceMemberRule(split: true),
            parts: [child("C", "p1", 0), child("C", "p2", 1)]
        )
        XCTAssertNil(m.squaresNote)
        XCTAssertFalse(m.showsSplitLineDice)
        XCTAssertTrue(m.parts.isEmpty)
    }

    // MARK: - Compound members

    /// One square: the note reads "1 square" (NOT the included-part count)
    /// and the dice sits on the toggle line, rolling for the whole square.
    func testOneSquareCompoundNoteAndDicePlacement() {
        let m = model(
            task: task("C", type: .compound),
            taskById: ["p1": task("p1", type: .counting, maxCount: 30), "p2": task("p2")],
            rule: BoardSourceMemberRule(vary: .lot),
            parts: [child("C", "p1", 0), child("C", "p2", 1)]
        )
        XCTAssertTrue(m.isCompound)
        XCTAssertFalse(m.isSplit)
        XCTAssertEqual(m.squaresNote, "1 square")
        XCTAssertTrue(m.showsSplitLineDice)
        XCTAssertFalse(m.showsDice, "a compound is not counting — no main-line dice")
        // RC10: a One-square part has no dice and no ✕ of its own, and
        // reads the PARENT's level for its range line.
        XCTAssertEqual(m.parts.map(\.showsDice), [false, false])
        XCTAssertEqual(m.parts.map(\.showsExclude), [false, false])
        XCTAssertEqual(m.parts[0].level, .lot)
    }

    /// Split up: the note counts INCLUDED parts, each counting part gets
    /// its own dice, and the excluded one is flagged.
    func testSplitCompoundNotePartDiceAndExclusion() {
        let m = model(
            task: task("C", type: .compound),
            taskById: [
                "p1": task("p1", type: .counting, maxCount: 30),
                "p2": task("p2", type: .counting, maxCount: 40),
                "p3": task("p3"),
            ],
            rule: BoardSourceMemberRule(
                split: true,
                parts: ["p3": BoardSourcePartRule(excluded: true)]
            ),
            parts: [child("C", "p1", 0), child("C", "p2", 1), child("C", "p3", 2)]
        )
        XCTAssertTrue(m.isSplit)
        XCTAssertEqual(m.squaresNote, "2 squares")
        XCTAssertFalse(m.showsSplitLineDice, "split ⇒ the dice moves onto the parts")
        XCTAssertEqual(m.parts.map(\.excluded), [false, false, true])
        XCTAssertEqual(m.parts.map(\.showsDice), [true, true, false], "non-counting p3 has none")
        XCTAssertEqual(m.parts.map(\.showsStepper), [true, true, false])
        XCTAssertEqual(m.parts.map(\.caption), ["of 30", "of 40", nil])
        XCTAssertEqual(m.parts.map(\.goal), [30, 40, 0])
    }

    /// Web round-1 decision: the LAST included part renders NO ✕ (hidden,
    /// not disabled) — the state layer would refuse the toggle anyway.
    func testLastIncludedPartLosesItsExcludeControl() {
        let m = model(
            task: task("C", type: .compound),
            taskById: ["p1": task("p1"), "p2": task("p2")],
            rule: BoardSourceMemberRule(
                split: true,
                parts: ["p2": BoardSourcePartRule(excluded: true)]
            ),
            parts: [child("C", "p1", 0), child("C", "p2", 1)]
        )
        XCTAssertEqual(m.squaresNote, "1 square")
        XCTAssertEqual(m.parts.map(\.showsExclude), [false, false])
    }

    /// Two of three excluded still leaves the survivor un-excludable, but
    /// with three included every part keeps its ✕.
    func testExcludeControlTracksIncludedCount() {
        let parts = [child("C", "p1", 0), child("C", "p2", 1), child("C", "p3", 2)]
        let byId = ["p1": task("p1"), "p2": task("p2"), "p3": task("p3")]
        let allIn = model(
            task: task("C", type: .compound),
            taskById: byId,
            rule: BoardSourceMemberRule(split: true),
            parts: parts
        )
        XCTAssertEqual(allIn.parts.map(\.showsExclude), [true, true, true])

        let twoOut = model(
            task: task("C", type: .compound),
            taskById: byId,
            rule: BoardSourceMemberRule(
                split: true,
                parts: [
                    "p1": BoardSourcePartRule(excluded: true),
                    "p2": BoardSourcePartRule(excluded: true),
                ]
            ),
            parts: parts
        )
        XCTAssertEqual(twoOut.parts.map(\.showsExclude), [false, false, false])
        XCTAssertEqual(twoOut.squaresNote, "1 square")
    }

    /// Parts render in `childIndex` order — the same order
    /// `applyMemberRules` expands a split member in — whatever order the
    /// link rows arrive in.
    func testPartsRenderInChildIndexOrder() {
        let m = model(
            task: task("C", type: .compound),
            taskById: ["a": task("a", title: "Alpha"), "b": task("b", title: "Bravo")],
            rule: BoardSourceMemberRule(split: true),
            parts: [child("C", "b", 1), child("C", "a", 0)]
        )
        XCTAssertEqual(m.parts.map(\.name), ["Alpha", "Bravo"])
    }

    /// A compound with NO children is a plain member: no toggle, no note.
    func testChildlessCompoundIsAPlainMember() {
        let m = model(task: task("C", type: .compound))
        XCTAssertFalse(m.isCompound)
        XCTAssertNil(m.squaresNote)
        XCTAssertFalse(m.showsSplitLineDice)
        XCTAssertTrue(m.parts.isEmpty)
    }

    /// A normal member carries nothing but its title + exclude control.
    func testNormalMemberHasNoRuleControls() {
        let m = model(task: task("n"))
        XCTAssertFalse(m.showsStepper)
        XCTAssertFalse(m.showsDice)
        XCTAssertNil(m.caption)
        XCTAssertNil(m.rangeLabel)
        XCTAssertFalse(m.isCompound)
    }

    /// Mid-hydration (no resolved task) must not crash or invent controls.
    func testMissingTaskRendersNothing() {
        let m = model(task: nil)
        XCTAssertEqual(m.goal, 0)
        XCTAssertFalse(m.showsStepper)
        XCTAssertFalse(m.showsDice)
        XCTAssertFalse(m.isCompound)
    }

    // MARK: - Dice cycle

    /// off → a little → a lot → off (handoff §Interactions).
    func testDiceCycleWrapsAtALot() {
        XCTAssertEqual(VaryLevel.off.next, .little)
        XCTAssertEqual(VaryLevel.little.next, .lot)
        XCTAssertEqual(VaryLevel.lot.next, .off)
    }
}
