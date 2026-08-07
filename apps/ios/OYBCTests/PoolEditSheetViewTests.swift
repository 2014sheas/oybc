import XCTest
@testable import OYBC

/// PoolEditSheetViewTests — Task Pools + Recurring Boards Rework (P2
/// final review). Covers the three pure helpers `PoolEditSheetView`
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
final class PoolEditSheetViewTests: XCTestCase {

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
        XCTAssertNil(PoolEditSheetView.nameLengthError(for: name))
    }

    func testNameLengthError_ErrorAt121() {
        let name = String(repeating: "a", count: 121)
        XCTAssertEqual(
            PoolEditSheetView.nameLengthError(for: name),
            "Could not save pool: Pool name must be 120 characters or fewer."
        )
    }

    func testNameLengthError_NilForShortName() {
        XCTAssertNil(PoolEditSheetView.nameLengthError(for: "Morning Kickstart"))
    }

    // #340 review Minor 1: the bound is UTF-16 code units (like Zod's max(120)
    // / web's name.length), NOT Swift Characters — else an emoji-heavy name
    // ≤120 graphemes but >120 units passes here yet a web peer drops it on pull.
    func testNameLengthError_CountsUTF16UnitsNotGraphemes() {
        // 61 × 🎯 = 61 graphemes but 122 UTF-16 units → must error.
        let emojiName = String(repeating: "🎯", count: 61)
        XCTAssertEqual(emojiName.count, 61)
        XCTAssertEqual(emojiName.utf16.count, 122)
        XCTAssertNotNil(PoolEditSheetView.nameLengthError(for: emojiName))
        // 60 × 🎯 = 120 units → exactly at the bound, no error.
        XCTAssertNil(PoolEditSheetView.nameLengthError(for: String(repeating: "🎯", count: 60)))
    }

    func testNameLengthError_MatchesWebCopyByteForByte() {
        // `poolEditSheetOps.ts`'s `savePoolFromSheet` throws
        // "Pool name must be 120 characters or fewer." and the sheet's
        // catch branch prefixes "Could not save pool: " — the same full
        // string this helper returns.
        let name = String(repeating: "z", count: 200)
        XCTAssertEqual(
            PoolEditSheetView.nameLengthError(for: name),
            "Could not save pool: Pool name must be 120 characters or fewer."
        )
    }

    // MARK: - I-2: filterLibraryResults

    func testFilterLibraryResults_ExcludesAlreadySelectedIds() {
        let t1 = buildTask("t1")
        let t2 = buildTask("t2")
        let result = PoolEditSheetView.filterLibraryResults(
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

        let result = PoolEditSheetView.filterLibraryResults(
            browsableTasks: browsable, selectedIds: [], query: ""
        )

        XCTAssertEqual(result.map(\.id), ["t1"])
        XCTAssertFalse(result.contains { $0.id == draft.id })
    }

    func testFilterLibraryResults_TrimmedCaseInsensitiveQuery() {
        let morning = buildTask("t1", title: "Morning Kickstart")
        let evening = buildTask("t2", title: "Evening wind-down")
        let result = PoolEditSheetView.filterLibraryResults(
            browsableTasks: [morning, evening], selectedIds: [], query: "  MORNING  "
        )
        XCTAssertEqual(result.map(\.id), ["t1"])
    }

    func testFilterLibraryResults_EmptyQueryReturnsAllUnselected() {
        let t1 = buildTask("t1")
        let t2 = buildTask("t2")
        let result = PoolEditSheetView.filterLibraryResults(
            browsableTasks: [t1, t2], selectedIds: [], query: "   "
        )
        XCTAssertEqual(Set(result.map(\.id)), Set(["t1", "t2"]))
    }

    // MARK: - I-3: resolveChips

    func testResolveChips_ResolvesInTaskIdsOrder() {
        let t1 = buildTask("t1")
        let t2 = buildTask("t2")
        let result = PoolEditSheetView.resolveChips(taskIds: ["t2", "t1"], libraryTasks: [t1, t2])
        XCTAssertEqual(result.map(\.id), ["t2", "t1"])
    }

    func testResolveChips_WizardBornDraftTaskStillResolvesItsChip() {
        // Contrast with `testFilterLibraryResults_ExcludesWizardBornDraftNotInBrowsableInput`:
        // the picker would never OFFER this task again, but a pool that
        // already has it must still render the chip — chip resolution
        // reads the FULL library set, never the browsable/picker subset.
        let draft = buildTask("t1", title: "Draft task", createdInWizard: true)
        let result = PoolEditSheetView.resolveChips(taskIds: ["t1"], libraryTasks: [draft])
        XCTAssertEqual(result.map(\.id), ["t1"])
    }

    func testResolveChips_DropsAnUnresolvableIdFromDisplayOnly() {
        // Soft-deleted / stale reference: absent from `libraryTasks`
        // entirely. The DISPLAY drops it (this helper); the WRITE path
        // (`PoolEditSheetView.poolTaskIds`, raw) is unaffected — that's
        // covered by inspection of `handleSave`/`seedForm`, which never
        // filter `poolTaskIds`.
        let t1 = buildTask("t1")
        let result = PoolEditSheetView.resolveChips(taskIds: ["t1", "ghost-id"], libraryTasks: [t1])
        XCTAssertEqual(result.map(\.id), ["t1"])
    }
}
