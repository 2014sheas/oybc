import XCTest
@testable import OYBC

/// Cross-platform sync-contract enforcement (workstream C4 / issue #261).
///
/// `SyncService.swift`'s `syncableCollections` / `userScopedCollections` /
/// `legacyPullSkipCollections` used to be hand-mirrored against web's
/// `syncService.ts` with only a manual audit backing the claim that they
/// agreed. Web now sources its lists from `@oybc/shared`'s
/// `syncContract.ts`; iOS can't import TypeScript, so this test instead
/// loads the JSON fixture generated from that same TS source
/// (`packages/shared/tests/fixtures/syncContract.json`, regenerate with
/// `pnpm --filter @oybc/shared run gen:sync-contract`) and asserts this
/// file's Swift lists set-match it.
///
/// If this test fails, either:
///  - Someone edited `SyncService.swift`'s lists without updating
///    `syncContract.ts` (fix: mirror the change into the TS source too), or
///  - Someone edited `syncContract.ts` without regenerating the fixture
///    (fix: run the gen script — `packages/shared/tests/constants/syncContract.test.ts`
///    would also be failing on the Jest side in that case).
final class SyncContractTests: XCTestCase {

    private struct SyncContractFixture: Decodable {
        let syncCollections: [String]
        let userScopedSyncCollections: [String]
        let legacyPullSkipCollections: [String]
        let clearableBoardFields: [String]
        let clearableFieldsByCollection: [String: [String]]
    }

    private func loadFixture() throws -> SyncContractFixture {
        guard let url = Bundle(for: SyncContractTests.self).url(
            forResource: "syncContract",
            withExtension: "json"
        ) else {
            XCTFail(
                "syncContract.json not found in test bundle — check project.yml's " +
                "OYBCTests `resources` entry for packages/shared/tests/fixtures, " +
                "and that xcodegen generate has been re-run."
            )
            throw XCTSkip("Fixture missing")
        }
        let data = try Data(contentsOf: url)
        return try JSONDecoder().decode(SyncContractFixture.self, from: data)
    }

    /// `syncableCollections` carries a trailing `users` tuple that is the
    /// parent doc (not a subcollection) — see its doc comment in
    /// SyncService.swift. It intentionally has no counterpart in web's
    /// `SYNCABLE_COLLECTIONS` / shared's `SYNC_COLLECTIONS`, so it's
    /// excluded before comparing.
    private var iosSyncCollectionNames: Set<String> {
        Set(syncableCollections.map(\.firestoreName).filter { $0 != "users" })
    }

    func testSyncCollectionsSetMatchesFixture() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(
            iosSyncCollectionNames,
            Set(fixture.syncCollections),
            "iOS syncableCollections (firestoreName, excluding the parent `users` doc) must " +
            "set-match @oybc/shared's SYNC_COLLECTIONS."
        )
    }

    func testUserScopedCollectionsSetMatchesFixture() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(
            userScopedCollections,
            Set(fixture.userScopedSyncCollections),
            "iOS userScopedCollections must set-match @oybc/shared's USER_SCOPED_SYNC_COLLECTIONS."
        )
    }

    func testLegacyPullSkipCollectionsSetMatchesFixture() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(
            legacyPullSkipCollections,
            Set(fixture.legacyPullSkipCollections),
            "iOS legacyPullSkipCollections must set-match @oybc/shared's LEGACY_PULL_SKIP_COLLECTIONS."
        )
    }

    /// Sanity check on the fixture itself, independent of the live Swift
    /// lists — guards against a corrupted/empty fixture silently passing
    /// the set-equality checks above via two empty sets.
    func testFixtureIsNonEmpty() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.syncCollections.isEmpty)
        XCTAssertFalse(fixture.userScopedSyncCollections.isEmpty)
        XCTAssertFalse(fixture.legacyPullSkipCollections.isEmpty)
        XCTAssertFalse(fixture.clearableBoardFields.isEmpty)
    }

    /// Board Edit redesign slice 4 (D2) — iOS `clearableBoardFields`
    /// (`SyncService+ClearableFields.swift`) must set-match @oybc/shared's
    /// `CLEARABLE_BOARD_FIELDS`, the same drift guardrail as the three
    /// collection lists above.
    func testClearableBoardFieldsSetMatchesFixture() throws {
        let fixture = try loadFixture()
        XCTAssertEqual(
            Set(clearableBoardFields),
            Set(fixture.clearableBoardFields),
            "iOS clearableBoardFields must set-match @oybc/shared's CLEARABLE_BOARD_FIELDS."
        )
    }

    /// Per-collection clearable fields (2026-09-29) — iOS
    /// `clearableFieldsByCollection` must match @oybc/shared's
    /// `CLEARABLE_FIELDS_BY_COLLECTION` key-for-key, each value set-equal.
    func testClearableFieldsByCollectionMatchesFixture() throws {
        let fixture = try loadFixture()
        XCTAssertFalse(fixture.clearableFieldsByCollection.isEmpty)
        XCTAssertEqual(
            Set(clearableFieldsByCollection.keys),
            Set(fixture.clearableFieldsByCollection.keys),
            "iOS clearableFieldsByCollection must cover exactly the collections @oybc/shared lists."
        )
        for (collection, fields) in fixture.clearableFieldsByCollection {
            XCTAssertEqual(
                Set(clearableFieldsByCollection[collection] ?? []),
                Set(fields),
                "iOS clearable fields for \(collection) must set-match @oybc/shared's."
            )
            XCTAssertTrue(
                iosSyncCollectionNames.contains(collection),
                "clearable collection \(collection) must be a real sync collection"
            )
        }
    }
}
