import XCTest
@testable import OYBC

/// The Tasks-tab header "+" is segment-aware (owner 2026-10-05): Pools
/// creates a pool, Library creates a task. Web twin: `tasksPlusAction`.
final class TasksTabPlusActionTests: XCTestCase {

    func testLibrarySegment_PlusCreatesTask() {
        XCTAssertEqual(TasksTabSegment.library.plusAction, .newTask)
        XCTAssertEqual(TasksTabSegment.library.plusAction.accessibilityLabel, "New task")
    }

    func testPoolsSegment_PlusCreatesPool() {
        XCTAssertEqual(TasksTabSegment.pools.plusAction, .newPool)
        XCTAssertEqual(TasksTabSegment.pools.plusAction.accessibilityLabel, "New pool")
    }
}
