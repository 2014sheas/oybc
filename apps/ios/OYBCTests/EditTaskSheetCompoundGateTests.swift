import XCTest
@testable import OYBC

/// The Task Detail edit sheet's compound gate (twin of web
/// `pages/tasks/compoundEditGate.ts`): the structure is submitted only when
/// it was edited, so an already-invalid stored compound can still be renamed
/// through the basic route.
final class EditTaskSheetCompoundGateTests: XCTestCase {

    private func makeTask(
        id: String,
        type: TaskType,
        title: String,
        operatorType: OperatorType? = nil,
        threshold: Int? = nil
    ) -> OYBC.Task {
        OYBC.Task(
            id: id, userId: "u1", title: title, description: nil, type: type,
            action: nil, unit: nil, maxCount: nil,
            operatorType: operatorType, threshold: threshold,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: false, completedAt: nil, currentCount: nil,
            createdAt: "2026-01-01T00:00:00Z", updatedAt: "2026-01-01T00:00:00Z",
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil
        )
    }

    private func seeded(childCount: Int = 2, operatorType: OperatorType = .and) -> TaskEditPatch {
        let parent = makeTask(id: "p", type: .compound, title: "Routine", operatorType: operatorType)
        let kids = (0..<childCount).map { makeTask(id: "c\($0)", type: .normal, title: "Step \($0)") }
        return EditTaskSheet.seedCompoundDraft(task: parent, children: kids)
    }

    func test_seed_carriesRuleAndChildrenInGivenOrder() {
        let d = seeded(childCount: 3, operatorType: .or)
        XCTAssertEqual(d.operatorType, .or)
        XCTAssertEqual(d.children.map(\.childTaskId), ["c0", "c1", "c2"])
        XCTAssertEqual(d.children.map(\.title), ["Step 0", "Step 1", "Step 2"])
    }

    func test_notLoaded_isUnchangedAndSubmitsNothing() {
        XCTAssertFalse(EditTaskSheet.compoundStructureChanged(baseline: nil, draft: nil))
        XCTAssertFalse(EditTaskSheet.compoundStructureChanged(baseline: seeded(), draft: nil))
        XCTAssertNil(EditTaskSheet.compoundSubmission(baseline: nil, draft: nil, title: "X"))
    }

    func test_titleOnlyEdit_takesBasicRoute() {
        let base = seeded()
        var draft = base
        draft.title = "Something else"
        XCTAssertFalse(EditTaskSheet.compoundStructureChanged(baseline: base, draft: draft))
        XCTAssertNil(EditTaskSheet.compoundSubmission(baseline: base, draft: draft, title: "Renamed"))
    }

    func test_invalidStoredStructure_titleOnlyEdit_submitsNoCompound() {
        // One sub-task left — the stored structure already fails validation.
        let base = seeded(childCount: 1)
        XCTAssertNotNil(base.validate(type: .compound))
        // The draft carries the title edit (like the web twin) — the gate must
        // be title-insensitive, so a title-only change still submits nothing.
        var draft = base
        draft.title = "Renamed"
        XCTAssertNil(EditTaskSheet.compoundSubmission(baseline: base, draft: draft, title: "Renamed"))
    }

    func test_operatorFlip_submitsStructureTitledFromSheet() {
        let base = seeded()
        var draft = base
        draft.operatorType = .or
        let out = EditTaskSheet.compoundSubmission(baseline: base, draft: draft, title: "  New name  ")
        XCTAssertEqual(out?.operatorType, .or)
        XCTAssertEqual(out?.title, "New name")
        XCTAssertEqual(out?.children.count, 2)
    }

    func test_childRenameAndAdd_countAsStructureEdits() {
        let base = seeded()
        var renamed = base
        renamed.children[0].title = "Stretch"
        XCTAssertTrue(EditTaskSheet.compoundStructureChanged(baseline: base, draft: renamed))

        var added = base
        added.children.append(ChildPatch(id: "new", childTaskId: nil, title: "", isCounting: false))
        XCTAssertTrue(EditTaskSheet.compoundStructureChanged(baseline: base, draft: added))
    }
}
