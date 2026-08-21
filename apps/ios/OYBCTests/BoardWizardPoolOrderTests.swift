import XCTest
@testable import OYBC

/// Insertion-ordered pool (Inline Task Editing PR 1, Task 1). The wizard pool
/// must render in insertion order — not alphabetical — so a renamed task keeps
/// its position when inline editing lands.
final class BoardWizardPoolOrderTests: XCTestCase {

    private func makeVM() -> BoardWizardViewModel {
        BoardWizardViewModel(preferences: .defaults, database: try! AppDatabase.makeTestInstance())
    }

    func test_add_appends_to_order() {
        let vm = makeVM()
        vm.toggleTaskSelection("a")
        vm.toggleTaskSelection("b")
        XCTAssertEqual(vm.poolOrder, ["a", "b"])
    }

    func test_remove_drops_from_order() {
        let vm = makeVM()
        ["a", "b", "c"].forEach { vm.toggleTaskSelection($0) }
        vm.toggleTaskSelection("b") // remove
        XCTAssertEqual(vm.poolOrder, ["a", "c"])
        XCTAssertFalse(vm.selectedTaskIds.contains("b"))
    }

    func test_restore_reinserts_at_index() {
        let vm = makeVM()
        ["a", "b", "c"].forEach { vm.toggleTaskSelection($0) }
        vm.toggleTaskSelection("b") // remove -> ["a","c"]
        vm.restoreToPool("b", at: 1)
        XCTAssertEqual(vm.poolOrder, ["a", "b", "c"])
        XCTAssertTrue(vm.selectedTaskIds.contains("b"))
    }

    func test_restore_clamps_out_of_range_index() {
        let vm = makeVM()
        vm.toggleTaskSelection("a")
        vm.restoreToPool("z", at: 99) // clamps to end
        XCTAssertEqual(vm.poolOrder, ["a", "z"])
    }

    func test_readd_does_not_duplicate() {
        let vm = makeVM()
        vm.toggleTaskSelection("a")
        vm.toggleTaskSelection("a") // remove
        vm.toggleTaskSelection("a") // re-add
        XCTAssertEqual(vm.poolOrder, ["a"])
    }
}
