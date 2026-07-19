import XCTest
@testable import OYBC

/// Unit tests for `resolveDeriveLinkTarget` in `DeriveCounterLink.swift`.
///
/// Parity target: `apps/web/src/components/wizard/deriveCounterLink.test.ts`.
/// Mirrors the TS case list 1:1.
final class DeriveCounterLinkTests: XCTestCase {

    private let now = "2026-07-18T10:00:00.000Z"

    private func counterTask(
        id: String = "src1",
        sharedCounterId: String? = nil,
        currentCount: Int? = 120
    ) -> OYBC.Task {
        OYBC.Task(
            id: id,
            userId: "u1",
            title: "Do 200 push-ups",
            type: .counting,
            action: "Do",
            unit: "push-ups",
            maxCount: 200,
            totalCompletions: 0,
            totalInstances: 0,
            currentCount: currentCount,
            createdAt: now,
            updatedAt: now,
            version: 1,
            isDeleted: false,
            sharedCounterId: sharedCounterId
        )
    }

    func test_linksStraightToSource_whenSourceIsPlainNonDerivedCounter() {
        let source = counterTask(id: "src1", currentCount: 120)
        let result = resolveDeriveLinkTarget(source: source)
        XCTAssertEqual(result.sharedCounterId, "src1")
        XCTAssertEqual(result.baseline, 120)
    }

    func test_ignoresStaleIrrelevantRootTask_whenSourceIsNotItselfDerived() {
        let source = counterTask(id: "src1", currentCount: 120)
        // A caller might pass a lookup result even when it isn't needed;
        // the source's own currentCount must still win (never the passed
        // rootTask).
        let irrelevantRoot = counterTask(id: "other", currentCount: 9999)
        let result = resolveDeriveLinkTarget(source: source, rootTask: irrelevantRoot)
        XCTAssertEqual(result.sharedCounterId, "src1")
        XCTAssertEqual(result.baseline, 120)
    }

    func test_linksToRootCounter_whenSourceIsItselfLinkedDerivedTask() {
        // `source` is a derived task pointing at 'root1' — its own
        // currentCount (30) is its LOCAL window, not the lifetime total.
        let source = counterTask(id: "derived1", sharedCounterId: "root1", currentCount: 30)
        let rootTask = counterTask(id: "root1", sharedCounterId: nil, currentCount: 500)
        let result = resolveDeriveLinkTarget(source: source, rootTask: rootTask)
        // Links to the ROOT id, and baselines off the ROOT's lifetime count
        // — never the derived source's own local currentCount (30).
        XCTAssertEqual(result.sharedCounterId, "root1")
        XCTAssertEqual(result.baseline, 500)
    }

    func test_fallsBackToSourceItself_whenRootTaskCouldNotBeResolved() {
        let source = counterTask(id: "derived1", sharedCounterId: "root1", currentCount: 30)
        let result = resolveDeriveLinkTarget(source: source, rootTask: nil)
        XCTAssertEqual(result.sharedCounterId, "root1")
        XCTAssertEqual(result.baseline, 30)
    }

    func test_treatsMissingCurrentCount_asZero() {
        let source = counterTask(id: "src1", currentCount: nil)
        let result = resolveDeriveLinkTarget(source: source)
        XCTAssertEqual(result.sharedCounterId, "src1")
        XCTAssertEqual(result.baseline, 0)
    }
}
