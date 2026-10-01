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
    /// Tap handler for the found-state row; receives `sharedCounterId`.
    var onOpenCounter: (String) -> Void = { _ in }

    @State private var source: LinkedCounterSource? = nil
    @State private var loading = true

    var body: some View {
        Group {
            if loading {
                EmptyView()
            } else {
                LinkedCounterCaptionLabel(source: source) {
                    onOpenCounter(sharedCounterId)
                }
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
            let resolved = try await _Concurrency.Task.detached(priority: .userInitiated) {
                try Self.resolveSource(database: db, sharedCounterId: id)
            }.value
            guard !_Concurrency.Task.isCancelled else { return }
            source = resolved
        } catch {
            guard !_Concurrency.Task.isCancelled else { return }
            dlog("linked counter caption: failed to load source \(id): \(error)")
            source = nil
        }
        loading = false
    }

    /// The live source task's title, lifetime count and unit, or nil when
    /// the source is missing or soft-deleted (the caption then reads
    /// "deleted or not found"). One primary-key read.
    ///
    /// - Parameters:
    ///   - database: The database to read from.
    ///   - sharedCounterId: The linked counter's source task id.
    /// - Returns: The resolved source, or nil.
    /// - Throws: Any GRDB read error.
    nonisolated static func resolveSource(database: AppDatabase, sharedCounterId: String) throws -> LinkedCounterSource? {
        let task = try database.read { db in
            try OYBC.Task.fetchOne(db, key: sharedCounterId)
        }
        guard let task, !task.isDeleted else { return nil }
        return LinkedCounterSource(title: task.title, lifetime: task.currentCount ?? 0, unit: task.unit ?? "")
    }
}

/// What the linked-counter row shows about the family root.
struct LinkedCounterSource: Equatable {
    let title: String
    /// The root's lifetime count (`Task.currentCount`).
    let lifetime: Int
    let unit: String
}

/// The caption's pixels — a tappable "Linked to" row (title + lifetime +
/// chevron), or the non-interactive not-found line when `source` is nil. A
/// pure prop view (snapshotted by `LinkedCounterCaptionSnapshotTests`).
struct LinkedCounterCaptionLabel: View {

    let source: LinkedCounterSource?
    var onOpen: () -> Void = {}

    var body: some View {
        if let source {
            Button(action: onOpen) {
                HStack(alignment: .center, spacing: 10) {
                    VStack(alignment: .leading, spacing: 4) {
                        Text("Linked to")
                            .risoSectionLabel()
                        Text(source.title)
                            .font(.risoBody(14, .medium))
                            .foregroundStyle(Color.risoInk)
                    }
                    Spacer(minLength: 0)
                    Text("\(source.lifetime.formatted()) \(source.unit)")
                        .font(.risoHead(14, .bold))
                        .foregroundStyle(Color.risoBlue)
                    Image(systemName: "chevron.right")
                        .font(.system(size: 11, weight: .bold))
                        .foregroundStyle(Color.risoMuted)
                }
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                .risoCard(keyline: Riso.Keyline.dense)
                // Plain-style buttons hit-test only opaque content.
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Open the \(source.title) counter")
        } else {
            // No `.italic()`: the bundled Archivo has no italic face, so the
            // old system-font italic can't carry over — muted ink marks it.
            Text("Linked to source task (deleted or not found)")
                .font(.risoBody(12, .regular))
                .foregroundStyle(Color.risoMuted)
        }
    }
}
