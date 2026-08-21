import XCTest
@testable import OYBC

/// Unit tests for `CompoundEvaluation.evaluate` — parity with
/// `packages/shared/tests/algorithms/compoundEvaluation.test.ts`.
///
/// The Swift implementation is a line-for-line mirror of the shared
/// TypeScript algorithm. Any divergence between the two would cause
/// cross-device completion-state drift (e.g. a compound marked complete
/// on iOS but not on web). This suite pins the invariants the mirror
/// relies on.
final class CompoundEvaluationTests: XCTestCase {

    // MARK: - Helpers

    /// Build a minimal Task with sensible defaults; caller overrides only what matters.
    private func task(
        _ id: String,
        type: TaskType = .normal,
        isCompleted: Bool = false,
        isDeleted: Bool = false,
        operatorType: OperatorType? = nil,
        threshold: Int? = nil
    ) -> Task {
        Task(
            id: id,
            userId: "u",
            title: id,
            type: type,
            operatorType: operatorType,
            threshold: threshold,
            totalCompletions: 0,
            totalInstances: 0,
            isCompleted: isCompleted,
            createdAt: "2026-04-23T00:00:00.000Z",
            updatedAt: "2026-04-23T00:00:00.000Z",
            version: 1,
            isDeleted: isDeleted
        )
    }

    /// Build a compound Task with the given operator.
    private func compoundTask(
        _ id: String,
        operator op: OperatorType,
        threshold: Int? = nil
    ) -> Task {
        task(id, type: .compound, operatorType: op, threshold: threshold)
    }

    /// Build a CompoundChild link.
    private func child(_ parent: String, _ childId: String, _ idx: Int, isDeleted: Bool = false) -> CompoundChild {
        CompoundChild(
            id: "\(parent)-\(childId)-\(idx)",
            compoundTaskId: parent,
            childTaskId: childId,
            childIndex: idx,
            createdAt: "2026-04-23T00:00:00.000Z",
            updatedAt: "2026-04-23T00:00:00.000Z",
            version: 1,
            isDeleted: isDeleted
        )
    }

    // MARK: - AND operator

    func testAndReturnsFalseWhenOneChildIncomplete() {
        let parent = compoundTask("parent", operator: .and)
        let a = task("a", isCompleted: true)
        let b = task("b", isCompleted: false)
        let result = CompoundEvaluation.evaluate(
            compound: parent,
            childrenByCompound: ["parent": [child("parent", "a", 0), child("parent", "b", 1)]],
            taskById: ["parent": parent, "a": a, "b": b]
        )
        XCTAssertFalse(result)
    }

    func testAndReturnsTrueWhenBothChildrenComplete() {
        let parent = compoundTask("parent", operator: .and)
        let a = task("a", isCompleted: true)
        let b = task("b", isCompleted: true)
        let result = CompoundEvaluation.evaluate(
            compound: parent,
            childrenByCompound: ["parent": [child("parent", "a", 0), child("parent", "b", 1)]],
            taskById: ["parent": parent, "a": a, "b": b]
        )
        XCTAssertTrue(result)
    }

    func testAndReturnsTrueForZeroChildren() {
        // Vacuous truth: AND over empty set is true.
        let parent = compoundTask("parent", operator: .and)
        let result = CompoundEvaluation.evaluate(
            compound: parent,
            childrenByCompound: ["parent": []],
            taskById: ["parent": parent]
        )
        XCTAssertTrue(result)
    }

    func testAndFiltersSoftDeletedChildLinks() {
        // 'b' link is soft-deleted on the CompoundChild row — treated as absent.
        // Only 'a' (complete) remains → AND of [true] = true.
        let parent = compoundTask("parent", operator: .and)
        let a = task("a", isCompleted: true)
        let b = task("b", isCompleted: false)
        let result = CompoundEvaluation.evaluate(
            compound: parent,
            childrenByCompound: ["parent": [child("parent", "a", 0), child("parent", "b", 1, isDeleted: true)]],
            taskById: ["parent": parent, "a": a, "b": b]
        )
        XCTAssertTrue(result)
    }

    // MARK: - OR operator

    func testOrReturnsTrueWhenAtLeastOneChildComplete() {
        let parent = compoundTask("parent", operator: .or)
        let a = task("a", isCompleted: false)
        let b = task("b", isCompleted: true)
        let c = task("c", isCompleted: false)
        let result = CompoundEvaluation.evaluate(
            compound: parent,
            childrenByCompound: ["parent": [child("parent", "a", 0), child("parent", "b", 1), child("parent", "c", 2)]],
            taskById: ["parent": parent, "a": a, "b": b, "c": c]
        )
        XCTAssertTrue(result)
    }

    func testOrReturnsFalseWhenAllChildrenIncomplete() {
        let parent = compoundTask("parent", operator: .or)
        let a = task("a", isCompleted: false)
        let b = task("b", isCompleted: false)
        let result = CompoundEvaluation.evaluate(
            compound: parent,
            childrenByCompound: ["parent": [child("parent", "a", 0), child("parent", "b", 1)]],
            taskById: ["parent": parent, "a": a, "b": b]
        )
        XCTAssertFalse(result)
    }

    func testOrReturnsFalseForZeroChildren() {
        let parent = compoundTask("parent", operator: .or)
        let result = CompoundEvaluation.evaluate(
            compound: parent,
            childrenByCompound: ["parent": []],
            taskById: ["parent": parent]
        )
        XCTAssertFalse(result)
    }

    // MARK: - M_OF_N operator

    func testMOfNReturnsTrueWhenThresholdMet() {
        // 2 of 3 complete, threshold=2 → true
        let parent = compoundTask("parent", operator: .mOfN, threshold: 2)
        let a = task("a", isCompleted: true)
        let b = task("b", isCompleted: true)
        let c = task("c", isCompleted: false)
        let result = CompoundEvaluation.evaluate(
            compound: parent,
            childrenByCompound: ["parent": [child("parent", "a", 0), child("parent", "b", 1), child("parent", "c", 2)]],
            taskById: ["parent": parent, "a": a, "b": b, "c": c]
        )
        XCTAssertTrue(result)
    }

    func testMOfNReturnsFalseWhenThresholdNotMet() {
        // 1 of 3 complete, threshold=2 → false
        let parent = compoundTask("parent", operator: .mOfN, threshold: 2)
        let a = task("a", isCompleted: true)
        let b = task("b", isCompleted: false)
        let c = task("c", isCompleted: false)
        let result = CompoundEvaluation.evaluate(
            compound: parent,
            childrenByCompound: ["parent": [child("parent", "a", 0), child("parent", "b", 1), child("parent", "c", 2)]],
            taskById: ["parent": parent, "a": a, "b": b, "c": c]
        )
        XCTAssertFalse(result)
    }

    func testMOfNWithMissingThresholdTreatsAsOneNotZero() {
        // Defensive: Zod should reject M_OF_N without threshold, but a malformed
        // legacy composite migrated without a root threshold could land here.
        // The algorithm floors at max(1, threshold ?? 1) so the worst case
        // behaves like OR (one child satisfies it) rather than always-complete.
        let parent = compoundTask("parent", operator: .mOfN) // no threshold
        let aIncomplete = task("a", isCompleted: false)
        let resultIncomplete = CompoundEvaluation.evaluate(
            compound: parent,
            childrenByCompound: ["parent": [child("parent", "a", 0)]],
            taskById: ["parent": parent, "a": aIncomplete]
        )
        XCTAssertFalse(resultIncomplete, "M_OF_N with no threshold + zero completed children must NOT be vacuously true")

        let aComplete = task("a", isCompleted: true)
        let resultComplete = CompoundEvaluation.evaluate(
            compound: parent,
            childrenByCompound: ["parent": [child("parent", "a", 0)]],
            taskById: ["parent": parent, "a": aComplete]
        )
        XCTAssertTrue(resultComplete, "M_OF_N with no threshold + one completed child satisfies degenerate-OR semantics")
    }

    // MARK: - Nested compounds

    func testRecursesIntoNestedCompound() {
        // parent AND of [primitive, childCompound]
        // childCompound is OR of [a, b]
        // primitive: complete; a: incomplete; b: complete → childCompound true → parent true
        let parent = compoundTask("parent", operator: .and)
        let primitive = task("primitive", isCompleted: true)
        let childCompound = compoundTask("childCompound", operator: .or)
        let a = task("a", isCompleted: false)
        let b = task("b", isCompleted: true)

        let result = CompoundEvaluation.evaluate(
            compound: parent,
            childrenByCompound: [
                "parent": [child("parent", "primitive", 0), child("parent", "childCompound", 1)],
                "childCompound": [child("childCompound", "a", 0), child("childCompound", "b", 1)],
            ],
            taskById: ["parent": parent, "primitive": primitive, "childCompound": childCompound, "a": a, "b": b]
        )
        XCTAssertTrue(result)
    }

    // MARK: - Edge cases

    func testMissingTaskIdInTaskByIdTreatedAsIncomplete() {
        // 'ghost' is referenced in a CompoundChild link but absent from taskById → false
        let parent = compoundTask("parent", operator: .and)
        let result = CompoundEvaluation.evaluate(
            compound: parent,
            childrenByCompound: ["parent": [child("parent", "ghost", 0)]],
            taskById: ["parent": parent]
        )
        XCTAssertFalse(result)
    }

    func testDeletedChildTaskTreatedAsIncomplete() {
        // Task row itself is soft-deleted (distinct from the link being deleted)
        let parent = compoundTask("parent", operator: .and)
        let deletedChild = task("d", isCompleted: true, isDeleted: true)
        let result = CompoundEvaluation.evaluate(
            compound: parent,
            childrenByCompound: ["parent": [child("parent", "d", 0)]],
            taskById: ["parent": parent, "d": deletedChild]
        )
        XCTAssertFalse(result)
    }

    func testNonCompoundInputReturnsIsCompletedDirectly() {
        // Uniform evaluator behavior: non-compound tasks return their own isCompleted.
        let complete = task("t", isCompleted: true)
        XCTAssertTrue(CompoundEvaluation.evaluate(compound: complete, childrenByCompound: [:], taskById: [:]))

        let incomplete = task("t2", isCompleted: false)
        XCTAssertFalse(CompoundEvaluation.evaluate(compound: incomplete, childrenByCompound: [:], taskById: [:]))
    }

    func testMissingOperatorOnCompoundReturnsFalse() {
        // operatorType is nil on a compound row — defensive false.
        // Swift/Zod validation should reject this upstream.
        var malformed = task("malformed", type: .compound)
        // operatorType is already nil from task() helper
        let result = CompoundEvaluation.evaluate(
            compound: malformed,
            childrenByCompound: ["malformed": []],
            taskById: ["malformed": malformed]
        )
        XCTAssertFalse(result)
    }

    func testCompoundIdMissingFromChildrenByCompoundTreatedAsEmptyChildren() {
        // 'parent' key absent from childrenByCompound → defaults to [] → AND vacuous truth
        let compound = compoundTask("parent", operator: .and)
        let result = CompoundEvaluation.evaluate(
            compound: compound,
            childrenByCompound: [:],
            taskById: ["parent": compound]
        )
        XCTAssertTrue(result)
    }

    // MARK: - clampCompoundThreshold (mirror of the shared vector)

    /// Must match `clampCompoundThreshold` in
    /// `packages/shared/tests/algorithms/compoundEvaluation.test.ts`
    /// row-for-row — the pin that keeps the two platforms from drifting on
    /// the threshold clamp's upper-bound floor again.
    func testClampCompoundThresholdVector() {
        let vectors: [(t: Int, count: Int, expected: Int)] = [
            (3, 5, 3),    // in range → unchanged
            (99, 5, 5),   // above count → clamped to count
            (0, 5, 1),    // below 1 → floored at 1
            (-4, 5, 1),   // negative → floored at 1
            (5, 5, 5),    // equal to count (== "All") allowed
            (2, 1, 1),    // single child → clamped to 1
            (2, 0, 1),    // no children yet → max(1,0)=1 (no empty range)
            (1, 0, 1),    // threshold 1 with 0 children → 1
        ]
        for v in vectors {
            XCTAssertEqual(
                CompoundEvaluation.clampCompoundThreshold(v.t, childCount: v.count),
                v.expected,
                "clamp(\(v.t), \(v.count)) should be \(v.expected)"
            )
        }
    }
}
