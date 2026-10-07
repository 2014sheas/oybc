import XCTest
import GRDB
@testable import OYBC

@MainActor
final class CompoundSubKindTests: XCTestCase {
    func testNewDurationSubCarriesKindIntoTheChildTask() throws {
        let db = try AppDatabase.makeTestInstance(); try LinkedWindowKit.seedUser(db)
        let form = CreateFormViewModel(database: db)
        let done = expectation(description: "created")
        form.handleCreateCompoundAndAddToPool(
            userId: LinkedWindowKit.userId,
            title: "Music week",
            rule: .allOf,
            subs: [.newCounting(action: "Practice", goal: 90, unit: "", sharedCounterId: nil, baseline: nil, countKind: .duration)],
            onTaskCreated: { _, _, _ in done.fulfill() },
            onLibraryReloadRequested: {}
        )
        wait(for: [done], timeout: 5)
        let child = try XCTUnwrap(try db.read { try Task.filter(Column("action") == "Practice").fetchOne($0) })
        XCTAssertEqual(child.countKind, .duration)
        XCTAssertEqual(child.maxCount, 90)
        XCTAssertEqual(child.unit, "")
        XCTAssertEqual(child.title, "Practice 1h 30m")
    }

    func testChildPatchSeedsKindAndTheAppendGateParsesPerKind() {
        var t = LinkedWindowKit.task("c", maxCount: 26.2); t.countKind = .continuous
        let patch = ChildPatch(from: t)
        XCTAssertEqual(patch.countKind, .continuous)
        XCTAssertEqual(patch.goal, "26.2")
        XCTAssertTrue(RisoCompoundEditFieldsView.canAppendCounting(text: "Run", goal: "3.1", unit: "mi", kind: .continuous))
        XCTAssertFalse(RisoCompoundEditFieldsView.canAppendCounting(text: "Run", goal: "3.1", unit: "mi", kind: .discrete))
        XCTAssertTrue(RisoCompoundEditFieldsView.canAppendCounting(text: "Practice", goal: "90", unit: "", kind: .duration))
    }

    func testAppendTypedDurationTitlesWithoutAUnit() {
        var draft = TaskEditPatch(title: "Music week")
        RisoCompoundEditFieldsView.appendTyped("Practice", isCounting: true, goal: "1h 30m", unit: "ignored", kind: .duration, to: &draft)
        XCTAssertEqual(draft.children.first?.title, "Practice 1h 30m")
        XCTAssertEqual(draft.children.first?.unit, "")
        XCTAssertEqual(draft.children.first?.countKind, .duration)
    }

    func testValidateParsesEachCountingChildAtItsKind() {
        var patch = TaskEditPatch(title: "Week")
        RisoCompoundEditFieldsView.appendTyped("Practice", isCounting: true, goal: "1h 30m", unit: "", kind: .duration, to: &patch)
        XCTAssertNil(patch.validate(type: .compound))
        patch.children[0].countKind = .continuous
        patch.children[0].goal = "3.125"
        patch.children[0].unit = "mi"
        XCTAssertNotNil(patch.validate(type: .compound))
    }
}
