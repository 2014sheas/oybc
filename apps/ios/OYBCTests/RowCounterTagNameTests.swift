import XCTest
@testable import OYBC

/// Unit tasks PR 2: the row tag's counter name, the counter-name search match
/// and the library index the lists read. Web twin: `rowCounterTagName.test.ts`.
@MainActor
final class RowCounterTagNameTests: XCTestCase {

    private let t0 = "2026-01-01T00:00:00.000Z"

    private func task(
        _ id: String, _ title: String, type: TaskType = .normal, counterName: String? = nil,
        linkedTo: String? = nil, countsToward: String? = nil
    ) -> Task {
        var t = Task(
            id: id, userId: "u", title: title, type: type,
            action: type == .counting ? "Read" : nil, unit: type == .counting ? "books" : nil,
            maxCount: type == .counting ? 2 : nil, totalCompletions: 0, totalInstances: 0,
            currentCount: type == .counting ? 0 : nil, createdAt: t0, updatedAt: t0, version: 1, isDeleted: false,
            sharedCounterId: linkedTo, countsTowardCounterId: countsToward
        )
        t.counterName = counterName
        return t
    }

    private var root: Task { task("root", "Read 12 books", type: .counting, counterName: "Books") }

    // MARK: - rowCounterTagName

    func test_unitTaskAndLinkedCopyCarryTheSameName() {
        let unit = task("u", "Finish Dune", countsToward: "root")
        let copy = task("c", "Read 2 books", type: .counting, linkedTo: "root")
        let pool = [root, unit, copy]
        XCTAssertEqual(rowCounterTagName(task: unit, pool: pool), "Books")
        XCTAssertEqual(rowCounterTagName(task: copy, pool: pool), "Books")
    }

    func test_nameIsTheCounterDisplayNameNotTheRootTitle() {
        XCTAssertEqual(rowCounterTagName(task: task("u", "x", countsToward: "root"), pool: [root]),
                       CounterSettings.counterDisplayName(root))
        XCTAssertNotEqual(CounterSettings.counterDisplayName(root), root.title)
    }

    func test_nilForPlainRootAndMissingRoot() {
        XCTAssertNil(rowCounterTagName(task: task("p", "Walk the dog"), pool: [root]))
        XCTAssertNil(rowCounterTagName(task: root, pool: [root]))
        XCTAssertNil(rowCounterTagName(task: task("u", "x", countsToward: "gone"), pool: [root]))
        XCTAssertNil(rowCounterTagName(task: task("c", "x", type: .counting, linkedTo: "gone"), pool: []))
    }

    func test_indexedOverloadAgrees() {
        let unit = task("u", "Finish Dune", countsToward: "root")
        XCTAssertEqual(rowCounterTagName(task: unit, rootsById: ["root": root]), "Books")
        XCTAssertNil(rowCounterTagName(task: unit, rootsById: [:]))
    }

    // MARK: - Search

    func test_counterNameMatchesUnitTasksButNotUnrelated() {
        let unit = task("u", "Finish Dune", countsToward: "root")
        XCTAssertFalse(TasksTabViewModel.matchesSearch(unit, trimmedLower: "books"))
        XCTAssertTrue(TasksTabViewModel.matchesSearch(unit, trimmedLower: "books", counterRoot: root))
        XCTAssertTrue(TasksTabViewModel.matchesSearch(unit, trimmedLower: "dune", counterRoot: root))
        XCTAssertFalse(TasksTabViewModel.matchesSearch(unit, trimmedLower: "garden", counterRoot: root))
        XCTAssertTrue(TasksTabViewModel.matchesSearch(unit, trimmedLower: "", counterRoot: nil))
    }

    func test_placementMatcherCounterOverload() {
        let unit = task("u", "Finish Dune", countsToward: "root")
        XCTAssertTrue(CounterPlacement.taskSearchMatches("BOOK", task: unit, counterRoot: root))
        XCTAssertTrue(CounterPlacement.taskSearchMatches("dune", task: unit, counterRoot: nil))
        XCTAssertFalse(CounterPlacement.taskSearchMatches("book", task: unit, counterRoot: nil))
        XCTAssertTrue(CounterPlacement.taskSearchMatches("", task: unit, counterRoot: nil))
    }

    func test_fullCounterMatchSetFindsUnitTasks() {
        let unit = task("u", "Finish Dune", countsToward: "root")
        // Display name + noun only; the verb ("read") and stored title do not widen it.
        let named = task("root2", "Read 12 books", type: .counting, counterName: "Shelf")
        XCTAssertTrue(TasksTabViewModel.matchesSearch(unit, trimmedLower: "shel", counterRoot: named))
        XCTAssertTrue(TasksTabViewModel.matchesSearch(unit, trimmedLower: "books", counterRoot: named))
        XCTAssertFalse(TasksTabViewModel.matchesSearch(unit, trimmedLower: "read", counterRoot: named))
    }

    func test_goalLessHubCounterRootStillTagsAndMatches() {
        var goalless = task("hub", "Read books", type: .counting, counterName: "Shelf")
        goalless.isCounter = true
        goalless.maxCount = nil
        let unit = task("u", "Finish Dune", countsToward: "hub")
        XCTAssertEqual(rowCounterTagName(task: unit, pool: [goalless, unit]), "Shelf")
        // Resolved from the FULL library even when browse filtering hides the root.
        let library = TaskLibraryViewModel()
        library.libraryTasks = [goalless, unit]
        library.browsableTasks = [unit]
        XCTAssertEqual(library.counterTagNames, ["u": "Shelf"])
        let vm = TasksTabViewModel()
        vm.search = "shelf"
        XCTAssertEqual(vm.filteredTasks(library: library).map(\.id), ["u"])
    }

    func test_aCounterRootNeverGetsATag() {
        var other = root
        other.countsTowardCounterId = "root"
        other.isCounter = true
        XCTAssertNil(rowCounterTagName(task: other, pool: [root]))
    }

    func test_tasksTabFilterFindsUnitTasksByCounterName() {
        let library = TaskLibraryViewModel()
        let tasks = [
            root, task("u", "Finish Dune", countsToward: "root"),
            task("c", "Read 2 books", type: .counting, linkedTo: "root"), task("p", "Walk the dog"),
        ]
        library.libraryTasks = tasks
        library.browsableTasks = tasks
        XCTAssertEqual(library.counterTagNames, ["u": "Books", "c": "Books"])

        let vm = TasksTabViewModel()
        vm.search = "books"
        let ids = Set(vm.filteredTasks(library: library).map(\.id))
        XCTAssertEqual(ids, ["root", "u", "c"])
        vm.search = "walk"
        XCTAssertEqual(vm.filteredTasks(library: library).map(\.id), ["p"])
    }

    // MARK: - Fix round 1

    func test_selfReferenceAndEmptyNameYieldNoTag() {
        var selfRef = task("s", "x", countsToward: "s")
        selfRef.isCounter = false
        XCTAssertNil(rowCounterTagName(task: selfRef, pool: [selfRef]))
        var blank = task("b", "", type: .counting, counterName: "")
        blank.action = nil
        blank.unit = nil
        XCTAssertNil(rowCounterTagName(task: task("u", "x", countsToward: "b"), pool: [blank]))
    }

    func test_rankedMatchesPutDirectHitsFirst() {
        let viaCounter = task("u", "Finish Dune", countsToward: "root")
        let direct = task("d", "Books club")
        let ranked = CounterPlacement.rankedTaskMatches([viaCounter, direct], query: "books", rootsById: ["root": root])
        XCTAssertEqual(ranked.map(\.id), ["d", "u"])
    }

    func test_poolPickerFindsUnitTasksByCounterName() {
        let unit = task("u", "Finish Dune", countsToward: "root")
        let r = PoolEditorViewModel.filterLibraryResults(
            browsableTasks: [unit], selectedIds: [], query: "books", rootsById: ["root": root]
        )
        XCTAssertEqual(r.map(\.id), ["u"])
    }

    func test_counterRowSubtitleOmitsARestatedTitle() {
        var t = task("c", "Read 2 books", type: .counting)
        t.action = "Read"; t.unit = "books"; t.maxCount = 2
        XCTAssertNil(TaskCountDisplay.counterRowSubtitle(for: t))
        t.title = "Shelf"
        XCTAssertEqual(TaskCountDisplay.counterRowSubtitle(for: t), "Read 2 books")
        t.maxCount = nil
        XCTAssertNil(TaskCountDisplay.counterRowSubtitle(for: t))
    }
}
