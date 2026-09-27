import Foundation
import FirebaseFirestore
import GRDB

// MARK: - Clearable board fields (Board Edit redesign slice 4, D2)
//
// Some `boards` fields must propagate their ABSENCE across sync, not just
// their presence — a Reopen locally clears `sealedAt` / `sealedCompletedCells`,
// and under Firestore's `merge: true` write, simply omitting an absent field
// would PRESERVE the stale value remotely (silently undoing the Reopen) or
// leave it stuck locally on pull. `endDate` / `completedAt` already had this
// carve-out hand-written twice in `SyncService.swift`; this file centralizes
// all four fields behind one shared list, mirroring the TS
// `CLEARABLE_BOARD_FIELDS` (`packages/shared/src/constants/syncContract.ts`),
// pinned equal by `SyncContractTests.testClearableBoardFieldsSetMatchesFixture`.

/// Board fields whose ABSENCE (not just presence) must sync: push deletes the
/// remote field with `FieldValue.delete()`; pull NULLs the local column when
/// absent from a winning remote doc. Order matches the TS array (not load-bearing
/// — comparisons are set-based).
let clearableBoardFields: [String] = ["endDate", "completedAt", "sealedAt", "sealedCompletedCells"]

extension SyncService {

    /// Push-side: for every `clearableBoardFields` entry absent from `cleaned`,
    /// stamp `FieldValue.delete()` so the remote doc drops the field instead of
    /// keeping a stale value under `merge: true`. No-op for a non-`"boards"`
    /// collection.
    ///
    /// - Parameters:
    ///   - collection: The doc's collection name (only `"boards"` is affected).
    ///   - cleaned: The push payload being assembled, mutated in place.
    static func applyClearableBoardFieldDeletes(collection: String, cleaned: inout [String: Any]) {
        guard collection == "boards" else { return }
        for field in clearableBoardFields where cleaned[field] == nil {
            cleaned[field] = FieldValue.delete()
        }
    }

    /// Pull-side: for every `clearableBoardFields` entry absent from the
    /// winning remote doc, NULL the local column directly (the generic upsert
    /// above only SETs columns present in `data`, so an absent field would
    /// otherwise leave a stale local value — e.g. a Reopen's cleared
    /// `sealedAt` never reaching a peer that already had the board sealed).
    /// No-op for a non-`"boards"` table or a doc missing `id`.
    ///
    /// MUST run inside the caller's write transaction, immediately after the
    /// generic upsert for the same row.
    ///
    /// - Parameters:
    ///   - db: The active GRDB write transaction.
    ///   - grdbTable: The local table name (only `"boards"` is affected).
    ///   - cleaned: The remote doc's cleaned field dictionary (metadata keys
    ///     like `_syncedAt` already stripped by the caller).
    static func applyClearableBoardFieldNulls(db: Database, grdbTable: String, cleaned: [String: Any]) throws {
        guard grdbTable == "boards", let boardId = cleaned["id"] as? String else { return }
        for field in clearableBoardFields where cleaned[field] == nil {
            try db.execute(
                sql: "UPDATE \"boards\" SET \"\(field)\" = NULL WHERE id = ?",
                arguments: [boardId]
            )
        }
    }
}
