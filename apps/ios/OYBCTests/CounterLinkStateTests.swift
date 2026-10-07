import XCTest
import GRDB
@testable import OYBC

/// C1 / C2 (PR 3 final fix) — the create forms' auto-link state
/// (`CounterLinkState`, used by `RisoSpecialTaskPanel` and
/// `RisoCompoundFieldsView`): a kind change never re-links a create the user
/// opted out of, and the "Don't link" hint shows whenever a (verb, noun)
/// match exists, whatever the goal parses to. Web twins:
/// `e2e/counter-kinds-authoring.spec.ts` "Don't link survives a kind change".
@MainActor
final class CounterLinkStateTests: XCTestCase {
    private typealias K = LinkedWindowKit

    /// A Discrete root "Run miles" (K.task's action/unit) the pair auto-links to.
    private let pool = [K.task("root", maxCount: 5, currentCount: 2)]

    private func matched(_ kind: CountKind = .discrete) -> CounterLinkState {
        var state = CounterLinkState()
        state.pairChanged(action: "Run", unit: "miles", kind: kind, tasks: pool)
        return state
    }

    /// C2 — "3.1" does not parse at the Discrete root's kind, yet the hint
    /// (carrying the toggle) is offered.
    func testHintShowsWhileTheGoalOnlyParsesAtTheOtherKind() {
        let state = matched()
        XCTAssertNil(parseCountInput("3.1", kind: state.effectiveKind(picker: .discrete)))
        XCTAssertEqual(state.hint?.counterId, "root")
        XCTAssertEqual(state.linked?.counterId, "root")
    }

    /// C1 — unlink, then pick Continuous: still unlinked, the picker's kind
    /// rules, the hint still offers "Link", and 3.1 is valid.
    func testKindChangeKeepsTheOptOut() {
        var state = matched()
        state.linkDisabled = true
        state.kindChanged(action: "Run", unit: "miles", kind: .continuous, tasks: pool)
        XCTAssertTrue(state.linkDisabled)
        XCTAssertNil(state.linked)
        XCTAssertEqual(state.hint?.counterId, "root")
        XCTAssertEqual(state.effectiveKind(picker: .continuous), .continuous)
        XCTAssertEqual(parseCountInput("3.1", kind: state.effectiveKind(picker: .continuous)), 3.1)
    }

    /// Duration can't link, so it drops the suggestion — but going back to
    /// Continuous keeps the earlier opt-out.
    func testDurationDropsTheMatchAndKeepsTheOptOut() {
        var state = matched()
        state.linkDisabled = true
        state.kindChanged(action: "Run", unit: "miles", kind: .duration, tasks: pool)
        XCTAssertNil(state.hint)
        state.kindChanged(action: "Run", unit: "miles", kind: .continuous, tasks: pool)
        XCTAssertEqual(state.hint?.counterId, "root")
        XCTAssertNil(state.linked)
    }

    /// An edited (verb, noun) pair re-offers linking (pre-existing, kept).
    func testPairChangeReoffersLinking() {
        var state = matched()
        state.linkDisabled = true
        state.pairChanged(action: "Run", unit: "miles", kind: .continuous, tasks: pool)
        XCTAssertFalse(state.linkDisabled)
        XCTAssertEqual(state.linked?.counterId, "root")
    }

    /// A1 — the special-task panel's submit after unlink → Continuous saves
    /// an UNLINKED Continuous task (the panel copies `link.linked` into the
    /// form exactly like this).
    func testA1SubmitAfterUnlinkAndKindSwitchSavesUnlinkedContinuous() throws {
        let db = try AppDatabase.makeTestInstance(); try K.seedUser(db)
        try db.saveTask(pool[0])
        var state = matched()
        state.linkDisabled = true
        state.kindChanged(action: "Run", unit: "miles", kind: .continuous, tasks: pool)

        let form = CreateFormViewModel(database: db)
        form.taskType = .counting
        form.countingAction = "Run"
        form.countingUnit = "miles"
        form.countingMaxCount = "3.1"
        form.countingKind = .continuous
        form.countingLinkedRootKind = state.linked?.countKind
        form.countingSharedCounterId = state.linked?.counterId
        form.countingBaseline = state.linked?.lifetime
        let done = expectation(description: "created")
        var id: String?
        form.handleCreateAndAddToPool(userId: K.userId, onTaskCreated: { tid, _, _ in id = tid; done.fulfill() },
                                      onLibraryReloadRequested: {})
        wait(for: [done], timeout: 5)
        let row = try XCTUnwrap(db.fetchTask(id: XCTUnwrap(id)))
        XCTAssertEqual(row.countKind, .continuous)
        XCTAssertEqual(row.maxCount, 3.1)
        XCTAssertNil(row.sharedCounterId)
    }

    /// A2 — the compound builder's new counting sub after unlink →
    /// Continuous is created as an UNLINKED Continuous child.
    func testA2SubAfterUnlinkAndKindSwitchSavesUnlinkedContinuous() throws {
        let db = try AppDatabase.makeTestInstance(); try K.seedUser(db)
        try db.saveTask(pool[0])
        var state = matched()
        state.linkDisabled = true
        state.kindChanged(action: "Run", unit: "miles", kind: .continuous, tasks: pool)
        let kind = state.effectiveKind(picker: .continuous)
        let goal = try XCTUnwrap(parseCountInput("3.1", kind: kind))

        let form = CreateFormViewModel(database: db)
        let done = expectation(description: "created")
        form.handleCreateCompoundAndAddToPool(
            userId: K.userId,
            title: "Weekend",
            rule: .allOf,
            subs: [.newCounting(action: "Run", goal: goal, unit: "miles",
                                sharedCounterId: state.linked?.counterId, baseline: state.linked?.lifetime,
                                countKind: kind)],
            onTaskCreated: { _, _, _ in done.fulfill() },
            onLibraryReloadRequested: {}
        )
        wait(for: [done], timeout: 5)
        let child = try XCTUnwrap(try db.read { try Task.filter(Column("title") == "Run 3.1 miles").fetchOne($0) })
        XCTAssertEqual(child.countKind, .continuous)
        XCTAssertEqual(child.maxCount, 3.1)
        XCTAssertNil(child.sharedCounterId)
    }
}

