import GRDB
import SwiftUI

/// Small "Linked to <source title>" caption rendered below the counting
/// progress in the task detail surface (Phase 2 — Shared Counters).
/// Detail-only — no list/cell badge (Decision 3 from Phase 0 design).
/// Loads the source title itself (via the injected `database`) so the parent
/// detail view stays a pure prop view; the pixels live in
/// ``LinkedCounterCaptionLabel`` so snapshots can render every state without
/// a database.
///
/// Used by `RisoTaskDetailContentView`. Extracted to its own file when the
/// legacy `TaskDetailContentView` (its former home) was retired.
struct LinkedCounterCaptionView: View {

    let sharedCounterId: String
    /// Injected for tests; defaults to the production singleton.
    var database: AppDatabase = .shared

    @State private var sourceTitle: String? = nil
    @State private var loading = true

    var body: some View {
        Group {
            if loading {
                EmptyView()
            } else {
                LinkedCounterCaptionLabel(sourceTitle: sourceTitle)
            }
        }
        // Keyed on the id so a different linked counter refetches, and
        // cancelled when the caption leaves the screen.
        .task(id: sharedCounterId) { await loadSource() }
    }

    private func loadSource() async {
        loading = true
        let db = database
        let id = sharedCounterId
        do {
            let title = try await _Concurrency.Task.detached(priority: .userInitiated) {
                try Self.resolveSourceTitle(database: db, sharedCounterId: id)
            }.value
            guard !_Concurrency.Task.isCancelled else { return }
            sourceTitle = title
        } catch {
            guard !_Concurrency.Task.isCancelled else { return }
            dlog("linked counter caption: failed to load source \(id): \(error)")
            sourceTitle = nil
        }
        loading = false
    }

    /// The live source task's title, or nil when the source is missing or
    /// soft-deleted (the caption then reads "deleted or not found").
    ///
    /// - Parameters:
    ///   - database: The database to read from.
    ///   - sharedCounterId: The linked counter's source task id.
    /// - Returns: The source title, or nil.
    /// - Throws: Any GRDB read error.
    nonisolated static func resolveSourceTitle(database: AppDatabase, sharedCounterId: String) throws -> String? {
        let task = try database.read { db in
            try OYBC.Task.fetchOne(db, key: sharedCounterId)
        }
        return task?.isDeleted == false ? task?.title : nil
    }
}

/// The caption's pixels — "Linked to <title>", or the not-found line when
/// `sourceTitle` is nil. A pure prop view (snapshotted by
/// `LinkedCounterCaptionSnapshotTests`).
struct LinkedCounterCaptionLabel: View {

    let sourceTitle: String?

    var body: some View {
        if let sourceTitle {
            HStack(spacing: 4) {
                Text("Linked to")
                    .font(.risoBody(12, .regular))
                    .foregroundStyle(Color.risoMuted)
                Text(sourceTitle)
                    .font(.risoBody(12, .medium))
                    .foregroundStyle(Color.risoInk)
            }
        } else {
            // No `.italic()`: the bundled Archivo has no italic face, so the
            // old system-font italic can't carry over — muted ink marks it.
            Text("Linked to source task (deleted or not found)")
                .font(.risoBody(12, .regular))
                .foregroundStyle(Color.risoMuted)
        }
    }
}
