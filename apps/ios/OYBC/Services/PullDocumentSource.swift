import Foundation
import FirebaseFirestore

/// Raw Firestore document dictionaries crossing an actor boundary (source →
/// main actor → GRDB writer queue). `@unchecked Sendable` because the payload
/// is an immutable value tree once `data()` has produced it — nobody mutates
/// it after the source returns.
struct PullDocs: @unchecked Sendable {
    let docs: [[String: Any]]
}

/// A live listener; `remove()` detaches it. Idempotent.
final class PullListener {
    private var onRemove: (() -> Void)?

    init(onRemove: @escaping () -> Void) { self.onRemove = onRemove }

    func remove() {
        onRemove?()
        onRemove = nil
    }
}

/// The remote reads `SyncService`'s PULL path goes through (the push path has
/// `FirestoreDocStore`). Production uses `LiveFirestorePullSource`; tests
/// inject a fake so the pull orchestration — collection order, per-collection
/// checkpoints, resume, listener attach timing — runs without a network.
///
/// Deliberately NOT `@MainActor`: its async reads run on the generic
/// executor, so turning a large snapshot into dictionaries (`data()`) happens
/// off the main thread.
protocol PullDocumentSource {
    /// Reads the parent `users/{userId}` doc.
    ///
    /// - Returns: The doc's data, or nil when it doesn't exist.
    /// - Throws: Any transport / permission error.
    func fetchUserDoc(userId: String) async throws -> [String: Any]?

    /// Reads one subcollection: everything when `since` is nil, else every doc
    /// with `_syncedAt >= since`.
    ///
    /// - Throws: Any transport / permission error.
    func fetchCollection(userId: String, collection: String, since: PullWatermark?) async throws -> PullDocs

    /// Listens to the parent user doc. `onChange` gets each delivered doc.
    func listenUserDoc(userId: String, onChange: @escaping ([String: Any]) -> Void) -> PullListener

    /// Listens to one subcollection filtered to `_syncedAt >= since`.
    /// `onChange` gets the added / modified docs of each snapshot (never
    /// called with an empty batch).
    func listenCollection(
        userId: String, collection: String, since: PullWatermark,
        onChange: @escaping (PullDocs) -> Void
    ) -> PullListener
}

/// The Firestore-backed pull source. Resolves `Firestore.firestore()` per call
/// so constructing it never touches Firebase (the logic-test bundle has no
/// `FirebaseApp.configure()` host).
struct LiveFirestorePullSource: PullDocumentSource {
    private func userRef(_ userId: String) -> DocumentReference {
        Firestore.firestore().collection("users").document(userId)
    }

    func fetchUserDoc(userId: String) async throws -> [String: Any]? {
        let snapshot = try await userRef(userId).getDocument()
        return snapshot.exists ? snapshot.data() : nil
    }

    func fetchCollection(userId: String, collection: String, since: PullWatermark?) async throws -> PullDocs {
        let colRef = userRef(userId).collection(collection)
        // `_syncedAt` is a server `Timestamp`; a range query needs a
        // type-matched operand. nil = first sync: the whole collection, which
        // also covers legacy docs that never carried `_syncedAt`.
        let query: Query = since.map { colRef.whereField("_syncedAt", isGreaterThanOrEqualTo: $0.timestamp) } ?? colRef
        let snapshot = try await query.getDocuments()
        return PullDocs(docs: snapshot.documents.map { $0.data() })
    }

    func listenUserDoc(userId: String, onChange: @escaping ([String: Any]) -> Void) -> PullListener {
        let reg = userRef(userId).addSnapshotListener { snapshot, error in
            if let error { dlog("[SyncService] users listener error: \(error.localizedDescription)"); return }
            guard let snapshot, snapshot.exists, let data = snapshot.data() else { return }
            onChange(data)
        }
        return PullListener { reg.remove() }
    }

    func listenCollection(
        userId: String, collection: String, since: PullWatermark,
        onChange: @escaping (PullDocs) -> Void
    ) -> PullListener {
        let query = userRef(userId).collection(collection)
            .whereField("_syncedAt", isGreaterThanOrEqualTo: since.timestamp)
        let reg = query.addSnapshotListener { snapshot, error in
            if let error { dlog("[SyncService] \(collection) listener error: \(error.localizedDescription)"); return }
            guard let snapshot else { return }
            let docs = snapshot.documentChanges.filter { $0.type != .removed }.map { $0.document.data() }
            if !docs.isEmpty { onChange(PullDocs(docs: docs)) }
        }
        return PullListener { reg.remove() }
    }
}
