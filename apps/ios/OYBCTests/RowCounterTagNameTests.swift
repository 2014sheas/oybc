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
        XCTAssertTrue(TasksTabViewModel.matchesSearch(unit, trimmedLower: "books", counterName: "Books"))
        XCTAssertTrue(TasksTabViewModel.matchesSearch(unit, trimmedLower: "dune", counterName: "Books"))
        XCTAssertFalse(TasksTabViewModel.matchesSearch(unit, trimmedLower: "garden", counterName: "Books"))
        XCTAssertTrue(TasksTabViewModel.matchesSearch(unit, trimmedLower: "", counterName: nil))
    }

    func test_placementMatcherCounterOverload() {
        let unit = task("u", "Finish Dune", countsToward: "root")
        XCTAssertTrue(CounterPlacement.taskSearchMatches("BOOK", task: unit, counterName: "Books"))
        XCTAssertTrue(CounterPlacement.taskSearchMatches("dune", task: unit, counterName: nil))
        XCTAssertFalse(CounterPlacement.taskSearchMatches("book", task: unit, counterName: nil))
        XCTAssertTrue(CounterPlacement.taskSearchMatches("", task: unit, counterName: nil))
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
}
