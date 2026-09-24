import Foundation
import FirebaseFirestore

/// The remote document store `SyncService`'s push path reads (conflict check)
/// and writes through, addressed by slash-joined Firestore path
/// (`users/{uid}/{collection}/{id}`, or `users/{uid}` for the user doc).
///
/// Production uses `LiveFirestoreDocStore`; tests inject an in-memory fake so
/// the read → LWW → write → mark-completed orchestration runs without a
/// network. Kept out of `SyncService.swift` (frozen size cap, ROADMAP B6).
/// Web twin: the `SyncDocStore` interface in `syncService.ts`.
protocol FirestoreDocStore {
    /// Reads one document.
    ///
    /// - Parameter path: Slash-joined Firestore document path.
    /// - Returns: The document's data, or `nil` when it doesn't exist.
    /// - Throws: Any transport / permission error from the backing store.
    func fetch(path: String) async throws -> [String: Any]?

    /// Merge-writes one document (`setData(_:merge: true)` semantics).
    ///
    /// - Parameters:
    ///   - path: Slash-joined Firestore document path.
    ///   - data: The wire-shaped payload `SyncService.writeFirestoreDoc`
    ///     built (JSON-string columns already expanded to native values).
    /// - Throws: Any transport / permission error from the backing store.
    func write(path: String, data: [String: Any]) async throws
}

/// The real Firestore-backed store — `SyncService`'s default. Resolves
/// `Firestore.firestore()` per call (the same default-app singleton the
/// service's own handle uses), so constructing it never touches Firebase —
/// the logic-test bundle has no `FirebaseApp.configure()` host.
struct LiveFirestoreDocStore: FirestoreDocStore {
    func fetch(path: String) async throws -> [String: Any]? {
        let snapshot = try await Firestore.firestore().document(path).getDocument()
        // `data()` is nil only for a non-existent document.
        return snapshot.exists ? snapshot.data() : nil
    }

    func write(path: String, data: [String: Any]) async throws {
        try await Firestore.firestore().document(path).setData(data, merge: true)
    }
}
