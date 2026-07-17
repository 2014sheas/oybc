import XCTest
@testable import OYBC

/// Unit tests for `findLinkableCounter` in `LinkableCounter.swift`.
///
/// Swift port of
/// `packages/shared/tests/algorithms/linkableCounter.test.ts`.
/// Both suites cover the same 8 cases so drift between the TypeScript
/// source of truth and the Swift port is caught immediately.
///
/// Cases:
///  1. Blank action or unit → nil.
///  2. No match → nil.
///  3. Case+space-insensitive match (action+unit), all fields.
///  4. Unit alone does NOT match — different action is a different counter.
///  5. Links to source (not a derived task) + member count.
///  6. Prefers most-established counter (most linkers beats higher count).
///  7. Excludes the task being edited (excludeTaskId).
///  8. Ignores deleted and non-counting tasks.
final class LinkableCounterTests: XCTestCase {

    // MARK: - Fixture builder

    private let ts = "2026-07-01T12:00:00.000Z"

    private func task(
        _ id: String,
        action: String? = nil,
        unit: String? = nil,
        currentCount: Int? = nil,
        sharedCounterId: String? = nil,
        isDeleted: Bool = false,
        type: TaskType = .counting,
        isCounter: Bool = false
    ) -> Task {
        Task(
            id: id,
            userId: "u1",
            title: "Task \(id)",
            type: type,
            action: action,
            unit: unit,
            totalCompletions: 0,
            totalInstances: 0,
            currentCount: currentCount,
            createdAt: ts,
            updatedAt: ts,
            version: 1,
            isDeleted: isDeleted,
            sharedCounterId: sharedCounterId,
            isCounter: isCounter
        )
    }

    // MARK: - 1. Blank action or unit → nil

    func testReturnsNilWhenActionOrUnitIsBlank() {
        let tasks = [task("a", action: "Push-ups", unit: "reps")]
        XCTAssertNil(findLinkableCounter(action: "", unit: "reps", tasks: tasks))
        XCTAssertNil(findLinkableCounter(action: "Push-ups", unit: "", tasks: tasks))
        XCTAssertNil(findLinkableCounter(action: "  ", unit: "reps", tasks: tasks))
        XCTAssertNil(findLinkableCounter(action: "Push-ups", unit: "  ", tasks: tasks))
    }

    // MARK: - 2. No match → nil

    func testReturnsNilWhenNothingMatches() {
        let tasks = [task("a", action: "Push-ups", unit: "reps")]
        XCTAssertNil(findLinkableCounter(action: "Sit-ups", unit: "reps", tasks: tasks))
    }

    // MARK: - 3. Case+space-insensitive match, all fields correct

    func testMatchesCaseAndSpaceInsensitive() {
        let tasks = [task("src", action: "Push-ups", unit: "reps", currentCount: 512)]
        let result = findLinkableCounter(action: "  push-UPS ", unit: "REPS", tasks: tasks)
        XCTAssertNotNil(result)
        XCTAssertEqual(result!.counterId, "src")
        XCTAssertEqual(result!.name, "Push-ups")
        XCTAssertEqual(result!.lifetime, 512)
        XCTAssertEqual(result!.memberCount, 1)
    }

    // MARK: - 4. Unit alone does NOT match — different action is a different counter

    func testDoesNotMatchOnUnitAlone() {
        let tasks = [task("pu", action: "Push-ups", unit: "reps")]
        XCTAssertNil(findLinkableCounter(action: "Sit-ups", unit: "reps", tasks: tasks))
    }

    // MARK: - 5. Links to source (not a derived task) and counts members

    func testLinksToSourceNotDerived() {
        let src = task("src", action: "Push-ups", unit: "reps", currentCount: 100)
        let d1  = task("d1",  action: "Push-ups", unit: "reps", sharedCounterId: "src")
        let d2  = task("d2",  action: "Push-ups", unit: "reps", sharedCounterId: "src")
        let result = findLinkableCounter(action: "Push-ups", unit: "reps", tasks: [src, d1, d2])
        XCTAssertEqual(result?.counterId, "src")   // never a derived task
        XCTAssertEqual(result?.memberCount, 3)     // source + 2 linkers
    }

    // MARK: - 6. Prefers most-established counter when several match

    func testPrefersMostEstablishedCounter() {
        // standalone (0 linkers) vs an established source (2 linkers)
        let solo = task("solo", action: "Run", unit: "km", currentCount: 999)
        let src  = task("src",  action: "Run", unit: "km", currentCount: 10)
        let d1   = task("d1",   action: "Run", unit: "km", sharedCounterId: "src")
        let d2   = task("d2",   action: "Run", unit: "km", sharedCounterId: "src")
        let result = findLinkableCounter(action: "Run", unit: "km", tasks: [solo, src, d1, d2])
        // src has 3 members vs solo's 1 — wins even though solo has higher count
        XCTAssertEqual(result?.counterId, "src")
    }

    // MARK: - 7. Excludes the task being edited

    func testExcludesSelf() {
        let self_ = task("self", action: "Push-ups", unit: "reps")
        XCTAssertNil(
            findLinkableCounter(
                action: "Push-ups", unit: "reps",
                excludeTaskId: "self",
                tasks: [self_]
            )
        )
    }

    // MARK: - 8. Ignores deleted and non-counting tasks

    func testIgnoresDeletedAndNonCountingTasks() {
        let deleted = task("del",  action: "Push-ups", unit: "reps", isDeleted: true)
        let normal  = task("norm", action: "Push-ups", unit: "reps", type: .normal)
        XCTAssertNil(findLinkableCounter(action: "Push-ups", unit: "reps", tasks: [deleted, normal]))
    }

    // MARK: - classifyCounterCreateMatch (P5 hub-create dedupe)
    //
    // Swift port of the TS `describe('classifyCounterCreateMatch (P5 hub-create dedupe)')`
    // block in `packages/shared/tests/algorithms/linkableCounter.test.ts`.

    func testClassifiesLinkedSourceAsEstablished() {
        // Source "Push-ups" + one linker sharing the counter → memberCount 2, kind established.
        let source = task("source", action: "Push-ups", unit: "reps", currentCount: 40)
        let linker = task("linker", action: "Push-ups", unit: "reps", sharedCounterId: "source")
        let result = classifyCounterCreateMatch(action: "Push-ups", unit: "reps", tasks: [source, linker])

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.kind, .established)
        XCTAssertEqual(result?.task.id, "source")
        XCTAssertEqual(result?.lifetime, 40)
        XCTAssertEqual(result?.memberCount, 2)
    }

    func testClassifiesFlaggedZeroLinkCounterAsEstablished() {
        // isCounter: true, no linkers → memberCount 1 but still established because of the flag.
        let flagged = task("flagged", action: "Sit-ups", unit: "reps", currentCount: 10, isCounter: true)
        let result = classifyCounterCreateMatch(action: "Sit-ups", unit: "reps", tasks: [flagged])

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.kind, .established)
        XCTAssertEqual(result?.task.id, "flagged")
        XCTAssertEqual(result?.lifetime, 10)
        XCTAssertEqual(result?.memberCount, 1)
    }

    func testClassifiesPlainStandaloneCountingTaskAsStandalone() {
        // No isCounter flag, no linkers → standalone; matched task row returned as the promote target.
        let standalone = task("standalone", action: "Squats", unit: "reps", currentCount: 5)
        let result = classifyCounterCreateMatch(action: "Squats", unit: "reps", tasks: [standalone])

        XCTAssertNotNil(result)
        XCTAssertEqual(result?.kind, .standalone)
        XCTAssertEqual(result?.task.id, "standalone")
        XCTAssertEqual(result?.lifetime, 5)
        XCTAssertEqual(result?.memberCount, 1)
    }

    func testClassifyReturnsNilWhenNothingMatches() {
        let other = task("other", action: "Push-ups", unit: "reps")
        let result = classifyCounterCreateMatch(action: "Lunges", unit: "reps", tasks: [other])
        XCTAssertNil(result)
    }
}
