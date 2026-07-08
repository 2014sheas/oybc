import XCTest
@testable import OYBC

/// Proof of the B3 DB-injection seam (issue #284): every iOS ViewModel that
/// touches `AppDatabase` now takes it as an injectable `database:` init
/// parameter defaulting to `.shared`, mirroring the pattern
/// `BoardPlayViewModel` established in B2-I1.
///
/// This file doesn't re-test each ViewModel's behavior (that's E3's job) —
/// it only proves the seam exists: every ViewModel below is constructed
/// against a fresh, isolated `AppDatabase.makeTestInstance()` rather than
/// the production `.shared` singleton, and a trivial published-state read
/// confirms the instance is usable immediately. If any of these inits
/// silently ignored the injected `database` and fell back to `.shared`,
/// this at least demonstrates the call compiles and runs against an
/// injected instance without crashing or touching the real app DB.
@MainActor
final class ViewModelInjectionTests: XCTestCase {

    private func makeDb() throws -> AppDatabase {
        try AppDatabase.makeTestInstance()
    }

    // MARK: - CreateTab ViewModels

    func test_recurringBoardTemplatesViewModel_constructsAgainstInjectedDb() throws {
        let db = try makeDb()
        let vm = RecurringBoardTemplatesViewModel(database: db)
        XCTAssertTrue(vm.templates.isEmpty)
        XCTAssertNil(vm.loadError)
    }

    func test_taskLibraryViewModel_constructsAgainstInjectedDb() throws {
        let db = try makeDb()
        let vm = TaskLibraryViewModel(database: db)
        XCTAssertTrue(vm.libraryTasks.isEmpty)
        XCTAssertNil(vm.loadError)
    }

    func test_createHubViewModel_constructsAgainstInjectedDb() throws {
        let db = try makeDb()
        let vm = CreateHubViewModel(database: db)
        XCTAssertEqual(vm.mode, .hub)
        XCTAssertTrue(vm.drafts.isEmpty)
    }

    func test_boardWizardViewModel_constructsAgainstInjectedDb() throws {
        let db = try makeDb()
        let vm = BoardWizardViewModel(preferences: .defaults, database: db)
        // Trivial published-state read — construction is the seam proof.
        XCTAssertEqual(vm.currentStep, 1)
    }

    func test_createFormViewModel_constructsAgainstInjectedDb() throws {
        let db = try makeDb()
        let vm = CreateFormViewModel(database: db)
        XCTAssertEqual(vm.taskType, .normal)
        XCTAssertTrue(vm.title.isEmpty)
    }

    func test_parentBoardTasksViewModel_constructsAgainstInjectedDb() throws {
        let db = try makeDb()
        let vm = ParentBoardTasksViewModel(database: db)
        XCTAssertTrue(vm.tasks.isEmpty)
        XCTAssertNil(vm.loadError)
    }

    func test_sourceBoardsViewModel_constructsAgainstInjectedDb() throws {
        let db = try makeDb()
        let vm = SourceBoardsViewModel(database: db)
        XCTAssertTrue(vm.eligibleBoards.isEmpty)
        XCTAssertTrue(vm.placements.isEmpty)
    }

    // MARK: - TasksTab ViewModels

    func test_tasksTabViewModel_constructsAgainstInjectedDb() throws {
        let db = try makeDb()
        let vm = TasksTabViewModel(database: db)
        XCTAssertTrue(vm.boardStatusById.isEmpty)
        XCTAssertNil(vm.loadError)
    }

    // MARK: - BoardsTab ViewModels

    func test_boardPlayViewModel_constructsAgainstInjectedDb() throws {
        let db = try makeDb()
        let vm = BoardPlayViewModel(boardId: "b1", userId: "u1", database: db)
        XCTAssertNil(vm.board, "no reload() called yet — construction is the seam proof")
    }

    func test_coreBoardWindowViewModel_constructsAgainstInjectedDb() throws {
        let db = try makeDb()
        let vm = CoreBoardWindowViewModel(
            timeframe: .daily,
            seedWindowStart: wizardLocalISOString(Date()),
            userId: "u1",
            weekStartDay: "monday",
            database: db
        )
        XCTAssertFalse(vm.isLoaded, "no reload() called yet — construction is the seam proof")
    }

    func test_coreBoardSlotsViewModel_constructsAgainstInjectedDb() throws {
        let db = try makeDb()
        // `PendingRecurringBoardsViewModel` is a back-compat typealias for
        // `CoreBoardSlotsViewModel` (same type, same init).
        let vm = PendingRecurringBoardsViewModel(database: db)
        XCTAssertTrue(vm.slots.isEmpty)
        XCTAssertNil(vm.loadError)
    }

    func test_recurringBoardSpawnViewModel_constructsAgainstInjectedDb() throws {
        let db = try makeDb()
        let vm = RecurringBoardSpawnViewModel(database: db)
        XCTAssertTrue(vm.succeededTemplateIds.isEmpty)
        XCTAssertNil(vm.loadError)
    }

    func test_coreBoardBrowserViewModel_constructsAgainstInjectedDb() throws {
        let db = try makeDb()
        let vm = CoreBoardBrowserViewModel(database: db)
        XCTAssertTrue(vm.cells.isEmpty)
        XCTAssertNil(vm.loadError)
    }
}
