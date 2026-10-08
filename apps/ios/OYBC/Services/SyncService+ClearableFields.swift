import Foundation
import FirebaseFirestore
import GRDB

// MARK: - Clearable fields (Board Edit redesign slice 4, D2 — per-collection since 2026-09-29)
//
// Some fields must propagate their ABSENCE across sync, not just their
// presence — a Reopen locally clears `boards.sealedAt` / `sealedCompletedCells`,
// and a per-timeframe core-board default cleared back to "inherit prefs" drops
// `coreBoardDefaults.defaultBoardSize` / `defaultCenterType`. Under Firestore's
// `merge: true` write, simply omitting an absent field would PRESERVE the stale
// value remotely (silently undoing the clear) or leave it stuck locally on
// pull. `tasks.endDate` joined for the windowed-linked-counter heal: stamping
// a legacy task row onto an INDEFINITE board must clear its old `endDate`
// cross-device. This file centralizes every such field behind one
// per-collection map, mirroring the TS `CLEARABLE_FIELDS_BY_COLLECTION`
// (`packages/shared/src/constants/syncContract.ts`), pinned equal by
// `SyncContractTests.testClearableFieldsByCollectionMatchesFixture`.

/// Per-collection fields whose ABSENCE (not just presence) must sync: push
/// deletes the remote field with `FieldValue.delete()`; pull NULLs the local
/// column when absent from a winning remote doc. Keyed by Firestore collection
/// name. Order within a list matches the TS array (not load-bearing —
/// comparisons are set-based).
let clearableFieldsByCollection: [String: [String]] = [
    "boards": ["endDate", "completedAt", "sealedAt", "sealedCompletedCells"],
    "coreBoardDefaults": ["defaultBoardSize", "defaultCenterType"],
    "tasks": ["endDate"],
]

/// The `boards` entry of `clearableFieldsByCollection` — kept as a named
/// constant because the Board Edit docs/tests reference it by this name and
/// `SyncContractTests` still pins it against the fixture's `clearableBoardFields`.
let clearableBoardFields: [String] = clearableFieldsByCollection["boards"] ?? []

extension SyncService {

    /// The clearable fields for `collection` — empty for a collection with
    /// none, so call sites loop unconditionally.
    ///
    /// - Parameter collection: A Firestore subcollection name (e.g. `"boards"`).
    /// - Returns: The field names whose absence must sync as a delete/NULL.
    nonisolated static func clearableFields(for collection: String) -> [String] {
        clearableFieldsByCollection[collection] ?? []
    }

    /// Push-side: for every clearable field of `collection` absent from
    /// `cleaned`, stamp `FieldValue.delete()` so the remote doc drops the
    /// field instead of keeping a stale value under `merge: true`. No-op for
    /// a collection with no clearable fields.
    ///
    /// - Parameters:
    ///   - collection: The doc's collection name.
    ///   - cleaned: The push payload being assembled, mutated in place.
    nonisolated static func applyClearableFieldDeletes(collection: String, cleaned: inout [String: Any]) {
        for field in clearableFields(for: collection) where cleaned[field] == nil {
            cleaned[field] = FieldValue.delete()
        }
    }

    /// Pull-side: for every clearable field of the table's collection absent
    /// from the winning remote doc, NULL the local column directly (the
    /// generic upsert only SETs columns present in `data`, so an absent field
    /// would otherwise leave a stale local value — e.g. a Reopen's cleared
    /// `sealedAt`, or a cleared size override, never reaching a peer). No-op
    /// for a table with no clearable fields or a doc missing `id`.
    ///
    /// MUST run inside the caller's write transaction, immediately after the
    /// generic upsert for the same row. `nonisolated`: the pull applies on
    /// GRDB's writer queue, off the main actor (`AppDatabase+PullApply.swift`).
    ///
    /// - Parameters:
    ///   - db: The active GRDB write transaction.
    ///   - grdbTable: The local table name (mapped to its collection via
    ///     `syncableCollections`).
    ///   - cleaned: The remote doc's cleaned field dictionary (metadata keys
    ///     like `_syncedAt` already stripped by the caller).
    nonisolated static func applyClearableFieldNulls(db: Database, grdbTable: String, cleaned: [String: Any]) throws {
        guard let collection = syncableCollections.first(where: { $0.grdbTable == grdbTable })?.firestoreName,
              let rowId = cleaned["id"] as? String else { return }
        for field in clearableFields(for: collection) where cleaned[field] == nil {
            try db.execute(
                sql: "UPDATE \"\(grdbTable)\" SET \"\(field)\" = NULL WHERE id = ?",
                arguments: [rowId]
            )
        }
    }
}
