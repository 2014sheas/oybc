import XCTest
@testable import OYBC

/// PoolEditorViewModelTests — Task Pools + Recurring Boards Rework (P2
/// final review; renamed from `PoolEditSheetViewTests` when the sheet became
/// the full-screen editor). Covers the pure helpers `PoolEditorViewModel`
/// exposes for testability (mirrors web's `poolEditSheetOps.test.ts` /
/// `poolEditSheetSelectors.test.ts`):
///
/// - `nameLengthError(for:)` — I-1, the 120-char `PoolSchema.name` bound.
/// - `filterLibraryResults(browsableTasks:selectedIds:query:)` — I-2, the
///   library-reuse picker must offer only browse-visible tasks.
/// - `resolveChips(taskIds:libraryTasks:)` — I-3, chip/count display must
///   resolve against the FULL library set so a pool that already
///   references a wizard-born draft task (or any other reference the
///   picker itself would filter out) still renders its chip.
final class PoolEditorViewModelTests: XCTestCase {

    private static let ts = "2026-07-19T00:00:00.000Z"

    private func buildTask(_ id: String, title: String? = nil, createdInWizard: Bool = false) -> Task {
        Task(
            id: id, userId: "u1", title: title ?? "Task \(id)", description: nil, type: .normal,
            action: nil, unit: nil, maxCount: nil,
            operatorType: nil, threshold: nil,
            referencedBoardId: nil, referencedTemplateId: nil,
            achievementTrigger: nil, requiredCount: nil,
            totalCompletions: 0, totalInstances: 0,
            isCompleted: false, completedAt: nil, currentCount: nil,
            createdAt: Self.ts, updatedAt: Self.ts,
            lastSyncedAt: nil, version: 1, isDeleted: false, deletedAt: nil,
            timeframe: nil, startDate: nil, endDate: nil,
            sharedCounterId: nil, baseline: nil,
            lastSyncedCount: nil, createdInWizard: createdInWizard
        )
    }

    // MARK: - I-1: nameLengthError

    func testNameLengthError_NilAtExactly120() {
        let name = String(repeating: "a", count: 120)
        XCTAssertNil(PoolEditorViewModel.nameLengthError(for: name))
    }

    func testNameLengthError_ErrorAt121() {
        let name = String(repeating: "a", count: 121)
        XCTAssertEqual(
            PoolEditorViewModel.nameLengthError(for: name),
            "Could not save pool: Pool name must be 120 characters or fewer."
        )
    }

    func testNameLengthError_NilForShortName() {
        XCTAssertNil(PoolEditorViewModel.nameLengthError(for: "Morning Kickstart"))
    }

    // #340 review Minor 1: the bound is UTF-16 code units (like Zod's max(120)
    // / web's name.length), NOT Swift Characters — else an emoji-heavy name
    // ≤120 graphemes but >120 units passes here yet a web peer drops it on pull.
    func testNameLengthError_CountsUTF16UnitsNotGraphemes() {
        // 61 × 🎯 = 61 graphemes but 122 UTF-16 units → must error.
        let emojiName = String(repeating: "🎯", count: 61)
        XCTAssertEqual(emojiName.count, 61)
        XCTAssertEqual(emojiName.utf16.count, 122)
        XCTAssertNotNil(PoolEditorViewModel.nameLengthError(for: emojiName))
        // 60 × 🎯 = 120 units → exactly at the bound, no error.
        XCTAssertNil(PoolEditorViewModel.nameLengthError(for: String(repeating: "🎯", count: 60)))
    }

    func testNameLengthError_MatchesWebCopyByteForByte() {
        // `poolEditSheetOps.ts`'s `savePoolFromSheet` throws
        // "Pool name must be 120 characters or fewer." and the sheet's
        // catch branch prefixes "Could not save pool: " — the same full
        // string this helper returns.
        let name = String(repeating: "z", count: 200)
        XCTAssertEqual(
            PoolEditorViewModel.nameLengthError(for: name),
            "Could not save pool: Pool name must be 120 characters or fewer."
        )
    }

    // MARK: - I-2: filterLibraryResults

    func testHeaderInputs_HealthyAndShort() {
        let floor = PoolHealth.DeckFloor(boardSize: 3, floor: 8)
        let ok = PoolEditorViewModel.headerInputs(taskCount: 9, deckFloor: floor)
        XCTAssertEqual(ok.count, 9)
        XCTAssertEqual(ok.required, 8)
        XCTAssertEqual(ok.note, "9 tasks in the pool · fills a 3×3")
        let short = PoolEditorViewModel.headerInputs(taskCount: 1, deckFloor: floor)
        XCTAssertEqual(short.note, "1 task in the pool · short on required tasks")
        let over = PoolEditorViewModel.headerInputs(taskCount: 12, deckFloor: floor)
        XCTAssertEqual(over.count, 12)
        XCTAssertEqual(over.required, 8)
        XCTAssertEqual(over.note, "12 tasks in the pool · fills a 3×3")
    }

    func testFilterLibraryResults_ExcludesAlreadySelectedIds() {
        let t1 = buildTask("t1")
        let t2 = buildTask("t2")
        let result = PoolEditorViewModel.filterLibraryResults(
            browsableTasks: [t1, t2], selectedIds: ["t1"], query: ""
        )
        XCTAssertEqual(result.map(\.id), ["t2"])
    }

    func testFilterLibraryResults_ExcludesWizardBornDraftNotInBrowsableInput() {
        // Simulates the caller passing `library.browsableTasks` (already
        // draft-filtered) — a wizard-born draft with no live-board
        // placement never reaches this helper's input in the first place.
        let normal = buildTask("t1", title: "Normal task")
        let draft = buildTask("t2", title: "Draft task", createdInWizard: true)
        let browsable = [normal] // `draft` excluded upstream, mirrors `TaskLibraryViewModel.browsableTasks`

        let result = PoolEditorViewModel.filterLibraryResults(
            browsableTasks: browsable, selectedIds: [], query: ""
        )

        XCTAssertEqual(result.map(\.id), ["t1"])
        XCTAssertFalse(result.contains { $0.id == draft.id })
    }

    func testFilterLibraryResults_TrimmedCaseInsensitiveQuery() {
        let morning = buildTask("t1", title: "Morning Kickstart")
        let evening = buildTask("t2", title: "Evening wind-down")
        let result = PoolEditorViewModel.filterLibraryResults(
            browsableTasks: [morning, evening], selectedIds: [], query: "  MORNING  "
        )
        XCTAssertEqual(result.map(\.id), ["t1"])
    }

    func testFilterLibraryResults_EmptyQueryReturnsAllUnselected() {
        let t1 = buildTask("t1")
        let t2 = buildTask("t2")
        let result = PoolEditorViewModel.filterLibraryResults(
            browsableTasks: [t1, t2], selectedIds: [], query: "   "
        )
        XCTAssertEqual(Set(result.map(\.id)), Set(["t1", "t2"]))
    }

    // MARK: - I-3: resolveChips

    func testResolveChips_ResolvesInTaskIdsOrder() {
        let t1 = buildTask("t1")
        let t2 = buildTask("t2")
        let result = PoolEditorViewModel.resolveChips(taskIds: ["t2", "t1"], libraryTasks: [t1, t2])
        XCTAssertEqual(result.map(\.id), ["t2", "t1"])
    }

    func testResolveChips_WizardBornDraftTaskStillResolvesItsChip() {
        // Contrast with `testFilterLibraryResults_ExcludesWizardBornDraftNotInBrowsableInput`:
        // the picker would never OFFER this task again, but a pool that
        // already has it must still render the chip — chip resolution
        // reads the FULL library set, never the browsable/picker subset.
        let draft = buildTask("t1", title: "Draft task", createdInWizard: true)
        let result = PoolEditorViewModel.resolveChips(taskIds: ["t1"], libraryTasks: [draft])
        XCTAssertEqual(result.map(\.id), ["t1"])
    }

    func testResolveChips_DropsAnUnresolvableIdFromDisplayOnly() {
        // Soft-deleted / stale reference: absent from `libraryTasks`
        // entirely. The DISPLAY drops it (this helper); the WRITE path
        // (`PoolEditorViewModel.poolTaskIds`, raw) is unaffected — that's
        // covered by inspection of `handleSave`/`seedForm`, which never
        // filter `poolTaskIds`.
        let t1 = buildTask("t1")
        let result = PoolEditorViewModel.resolveChips(taskIds: ["t1", "ghost-id"], libraryTasks: [t1])
        XCTAssertEqual(result.map(\.id), ["t1"])
    }

    // MARK: - Pool editor state (rows / staging / canSave)

    private func buildTyped(
        _ id: String, title: String, type: TaskType,
        action: String? = nil, unit: String? = nil, maxCount: Int? = nil
    ) -> Task {
        var t = buildTask(id, title: title)
        t.type = type
        t.action = action; t.unit = unit; t.maxCount = maxCount
        return t
    }

    private func makeVM(
        _ tasks: [Task], poolTaskIds: [String], db: AppDatabase? = nil, name: String = "Pool"
    ) throws -> PoolEditorViewModel {
        let database = try db ?? AppDatabase.makeTestInstance()
        let library = TaskLibraryViewModel(database: database)
        library.libraryTasks = tasks
        library.browsableTasks = tasks
        let vm = PoolEditorViewModel(
            pool: nil, userId: "u1", library: library, initialTaskIds: poolTaskIds, database: database
        )
        vm.name = name
        return vm
    }

    func testRows_ResolveInPoolOrder_AndLegacyAchievementStaysRemovableButNotPoolable() throws {
        let t1 = buildTask("t1"), t2 = buildTask("t2")
        let ach = buildTyped("a1", title: "Watch", type: .achievement)
        let vm = try makeVM([t1, t2, ach], poolTaskIds: ["t2", "a1", "t1", "ghost"])
        XCTAssertEqual(vm.selectedTasks.map(\.id), ["t2", "a1", "t1"])
        XCTAssertFalse(vm.poolableBrowsableTasks.contains { $0.id == "a1" })
        vm.remove("a1")
        XCTAssertEqual(vm.poolTaskIds, ["t2", "t1", "ghost"], "unresolvable ids are kept; only the row is removed")
    }

    func testStageEdit_OverlaysEffectiveTask_AndReopenReusesStagedPatch() throws {
        let t1 = buildTask("t1", title: "Old")
        let vm = try makeVM([t1], poolTaskIds: ["t1"])
        vm.openEditor("t1")
        XCTAssertEqual(vm.editingTaskId, "t1")
        vm.editDraft.title = "New"
        vm.saveEdit()
        XCTAssertNil(vm.editingTaskId)
        XCTAssertEqual(vm.effectiveTaskById["t1"]?.title, "New")
        XCTAssertEqual(vm.selectedTasks.first?.title, "New")
        vm.openEditor("t1")
        XCTAssertEqual(vm.editDraft.title, "New")
    }

    func testDiscardEdit_ComparesAgainstOpenBaseline() throws {
        let t1 = buildTask("t1", title: "Old")
        let vm = try makeVM([t1], poolTaskIds: ["t1"])
        vm.openEditor("t1")
        XCTAssertFalse(vm.discardEdit(), "an untouched editor drops nothing")
        vm.openEditor("t1")
        vm.editDraft.title = "Typed"
        XCTAssertTrue(vm.discardEdit())
        XCTAssertTrue(vm.stagedEdits.isEmpty)
        XCTAssertEqual(vm.effectiveTaskById["t1"]?.title, "Old")
    }

    func testOpenEditor_CountingTaskWithAutoTitleSeedsBlankTitle() throws {
        let auto = TaskTitle.generateCounterTaskTitle(action: "Run", maxCount: 5, unit: "km")
        let c = buildTyped("c1", title: auto, type: .counting, action: "Run", unit: "km", maxCount: 5)
        let vm = try makeVM([c], poolTaskIds: ["c1"])
        vm.openEditor("c1")
        XCTAssertEqual(vm.editDraft.title, "")
        XCTAssertEqual(vm.editDraft.goal, "5")
    }

    func testRemove_PurgesStagedEditAndClosesItsEditor() throws {
        let t1 = buildTask("t1")
        let vm = try makeVM([t1], poolTaskIds: ["t1"])
        vm.openEditor("t1"); vm.editDraft.title = "X"; vm.saveEdit()
        vm.openEditor("t1")
        vm.remove("t1")
        XCTAssertNil(vm.stagedEdits["t1"])
        XCTAssertNil(vm.editingTaskId)
    }

    func testCanSave_NeedsNameAndResolvableTaskAndIdle() throws {
        let t1 = buildTask("t1")
        let vm = try makeVM([t1], poolTaskIds: [], name: "  ")
        XCTAssertFalse(vm.canSave)
        vm.name = "Morning"
        XCTAssertFalse(vm.canSave, "no tasks")
        vm.add("ghost")
        XCTAssertFalse(vm.canSave, "only an unresolvable id")
        vm.add("t1")
        XCTAssertTrue(vm.canSave)
        vm.busy = true
        XCTAssertFalse(vm.canSave)
    }

    func testSave_AppliesStagedEditAndMembershipTogether_DerivesCountingTitle() async throws {
        let db = try AppDatabase.makeTestInstance()
        let now = AppDatabase.currentTimestamp()
        try db.saveUser(User(
            id: "u1", email: "t@e.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
        let auto = TaskTitle.generateCounterTaskTitle(action: "Run", maxCount: 5, unit: "km")
        let c = buildTyped("c1", title: auto, type: .counting, action: "Run", unit: "km", maxCount: 5)
        try db.saveTask(c)
        let vm = try makeVM([c], poolTaskIds: ["c1"], db: db, name: "Cardio")
        vm.openEditor("c1")
        vm.editDraft.goal = "10"
        vm.saveEdit()

        let outcome = await vm.save()
        guard case .saved(let created) = outcome else { return XCTFail("expected saved") }
        let pool = try XCTUnwrap(created)
        XCTAssertEqual(pool.taskIds, ["c1"])
        let stored = try XCTUnwrap(try db.read { try Task.fetchOne($0, key: "c1") })
        XCTAssertEqual(stored.maxCount, 10)
        XCTAssertEqual(stored.title, TaskTitle.generateCounterTaskTitle(action: "Run", maxCount: 10, unit: "km"))
    }

    func testSave_NameTooLong_FailsWithoutWriting() async throws {
        let t1 = buildTask("t1")
        let vm = try makeVM([t1], poolTaskIds: ["t1"], name: String(repeating: "a", count: 121))
        let outcome = await vm.save()
        guard case .failed = outcome else { return XCTFail("expected failure") }
        XCTAssertEqual(vm.errorMessage, "Could not save pool: Pool name must be 120 characters or fewer.")
        XCTAssertTrue(try vm.database.fetchPools(userId: "u1").isEmpty)
    }

    // MARK: - Review fixes (count/empty over resolvable rows; stale staged edits)

    func testSelectedTasks_AllUnresolvableIds_YieldsNoRows_SoListShowsEmptyNote() throws {
        let vm = try makeVM([], poolTaskIds: ["g1", "g2", "g3"])
        XCTAssertTrue(vm.selectedTasks.isEmpty, "count pill / empty note derive from resolvable rows, not raw ids")
        XCTAssertEqual(vm.poolTaskIds.count, 3, "ids are still kept for save")
    }

    func testPruneStagedEdits_DropsNonMembersAndUnresolvable() {
        let edits = ["a": TaskEditPatch(title: "A"), "b": TaskEditPatch(title: "B"), "c": TaskEditPatch(title: "C")]
        let kept = PoolEditorViewModel.pruneStagedEdits(edits, poolTaskIds: ["a", "b"], resolvableIds: ["a", "c"])
        XCTAssertEqual(Set(kept.keys), ["a"])
    }

    private func seededDB() throws -> AppDatabase {
        let db = try AppDatabase.makeTestInstance()
        let now = AppDatabase.currentTimestamp()
        try db.saveUser(User(
            id: "u1", email: "t@e.com", displayName: "T", photoURL: nil,
            preferences: User.encodePreferences(.defaults),
            createdAt: now, updatedAt: now, lastSyncedAt: nil, version: 1
        ))
        return db
    }

    func testSave_StagedEditOnSinceDeletedTask_SucceedsAndAppliesNoEdit() async throws {
        let db = try seededDB()
        let t1 = buildTask("t1", title: "Keep"), t2 = buildTask("t2", title: "Gone")
        try db.saveTask(t1)
        let vm = try makeVM([t1, t2], poolTaskIds: ["t1", "t2"], db: db, name: "P")
        vm.openEditor("t2"); vm.editDraft.title = "Renamed"; vm.saveEdit()
        // Sync deleted t2 after staging: library reload no longer resolves it.
        vm.library.libraryTasks = [t1]
        let outcome = await vm.save()
        guard case .saved(let created) = outcome else { return XCTFail("expected saved, got error: \(vm.errorMessage ?? "-")") }
        XCTAssertEqual(try XCTUnwrap(created).taskIds, ["t1", "t2"])
        XCTAssertTrue(vm.stagedEdits.isEmpty)
        XCTAssertNil(try db.read { try Task.fetchOne($0, key: "t2") })
    }

    func testSave_StagedEditOnRemovedRow_IsNotApplied() async throws {
        let db = try seededDB()
        let t1 = buildTask("t1", title: "Keep"), t2 = buildTask("t2", title: "Orig")
        try db.saveTask(t1); try db.saveTask(t2)
        let vm = try makeVM([t1, t2], poolTaskIds: ["t1", "t2"], db: db, name: "P")
        vm.openEditor("t2"); vm.editDraft.title = "Renamed"; vm.saveEdit()
        vm.stagedEdits["t2"] = TaskEditPatch(title: "Renamed") // simulate a leaked entry
        vm.poolTaskIds.removeAll { $0 == "t2" }
        let outcome = await vm.save()
        guard case .saved = outcome else { return XCTFail("expected saved") }
        XCTAssertEqual(try XCTUnwrap(try db.read { try Task.fetchOne($0, key: "t2") }).title, "Orig")
    }
}
