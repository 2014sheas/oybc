import XCTest
@testable import OYBC

/// Unit tests for `TasksTabViewModel.matchesSearch` — the Tasks-tab search
/// predicate.
///
/// Parity target: `apps/web/src/pages/tasks/__tests__/useTasksFilters.test.ts`.
/// Since the 2026-09-22 ruling a shared-counter family root's row renders the
/// pair-derived label ("Read pages"), not its stored title ("Read 35 pages"),
/// so search has to match BOTH: what the user sees, and what is stored.
final class TasksTabSearchTests: XCTestCase {

    // MARK: - Fixtures

    private func counting(
        title: String = "Read 35 pages",
        type: TaskType = .counting,
        action: String? = "Read",
        unit: String? = "pages",
        description: String? = nil
    ) -> Task {
        Task(
            id: "00000000-0000-0000-0000-000000000001",
            userId: "u1",
            title: title,
            description: description,
            type: type,
            action: action,
            unit: unit,
            maxCount: 35,
            totalCompletions: 0,
            totalInstances: 0,
            createdAt: "2026-09-01T12:00:00.000Z",
            updatedAt: "2026-09-01T12:00:00.000Z",
            version: 1,
            isDeleted: false
        )
    }

    // MARK: - Tests

    func test_matchesTheGenericCounterLabelTheFamilyRowDisplays() {
        // "Read pages" appears nowhere in the stored title "Read 35 pages" —
        // "pages" does, so use a query only the derived name satisfies.
        XCTAssertTrue(TasksTabViewModel.matchesSearch(counting(), trimmedLower: "read pages"))
    }

    func test_stillMatchesTheStoredTitleCountsAndAll() {
        XCTAssertTrue(TasksTabViewModel.matchesSearch(counting(), trimmedLower: "read 35"))
    }

    func test_matchesTheDescription() {
        XCTAssertTrue(
            TasksTabViewModel.matchesSearch(
                counting(description: "before bed"), trimmedLower: "before bed"
            )
        )
    }

    func test_doesNotMatchAnUnrelatedQuery() {
        XCTAssertFalse(TasksTabViewModel.matchesSearch(counting(), trimmedLower: "run miles"))
    }

    func test_doesNotConsultTheDerivedNameForANonCountingTask() {
        let normal = counting(title: "Stretch", type: .normal)
        XCTAssertFalse(TasksTabViewModel.matchesSearch(normal, trimmedLower: "read pages"))
    }

    func test_anEmptyQueryMatchesEverything() {
        XCTAssertTrue(TasksTabViewModel.matchesSearch(counting(), trimmedLower: ""))
    }
}
