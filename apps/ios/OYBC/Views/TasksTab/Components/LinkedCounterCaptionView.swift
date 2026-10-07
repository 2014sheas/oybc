import GRDB
import SwiftUI

/// The linked counting task's row to its counter root, rendered below the
/// counting progress in the task detail surface (Phase 2 — Shared Counters).
/// Shows the root's title + all-time total in the root's kind + chevron; no
/// "Linked to" caption (#548 rows 91/92), and nothing while loading or when
/// the root is gone.
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

    /// The live source task's title, lifetime count, unit and kind, or nil
    /// when the source is missing or soft-deleted (the row then renders
    /// nothing). One primary-key read.
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
        return LinkedCounterSource(
            title: task.title,
            lifetime: task.currentCount ?? 0,
            unit: task.unit ?? "",
            kind: resolveCountKind(task.countKind)
        )
    }
}

/// What the linked-counter row shows about the family root.
struct LinkedCounterSource: Equatable {
    let title: String
    /// The root's lifetime count (`Task.currentCount`).
    let lifetime: CountValue
    let unit: String
    /// The family's kind — the root's `countKind` (absent ⇒ discrete).
    let kind: CountKind
}

/// The row's pixels — a tappable row (root title + lifetime in the root's
/// kind + chevron), or nothing when `source` is nil. A pure prop view
/// (snapshotted by `LinkedCounterCaptionSnapshotTests`).
struct LinkedCounterCaptionLabel: View {

    let source: LinkedCounterSource?
    var onOpen: () -> Void = {}

    var body: some View {
        if let source {
            Button(action: onOpen) {
                HStack(alignment: .center, spacing: 10) {
                    Text(source.title)
                        .font(.risoBody(14, .medium))
                        .foregroundStyle(Color.risoInk)
                        .lineLimit(1)
                    Spacer(minLength: 0)
                    Text("\(formatCountTotal(source.lifetime, kind: source.kind))\(countUnitSuffix(source.kind, unit: source.unit))")
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
            EmptyView()
        }
    }
}
