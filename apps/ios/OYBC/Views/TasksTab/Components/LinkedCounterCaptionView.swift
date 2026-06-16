import GRDB
import SwiftUI

/// Small "Linked to <source title>" caption rendered below the counting
/// progress in the task detail surface (Phase 2 — Shared Counters).
/// Detail-only — no list/cell badge (Decision 3 from Phase 0 design).
/// Performs a one-shot GRDB fetch on appear so the parent detail view
/// stays a pure prop view.
///
/// Used by `RisoTaskDetailContentView`. Extracted to its own file when the
/// legacy `TaskDetailContentView` (its former home) was retired.
struct LinkedCounterCaptionView: View {

    let sharedCounterId: String

    @State private var sourceTitle: String? = nil
    @State private var loading = true

    var body: some View {
        Group {
            if loading {
                EmptyView()
            } else if let sourceTitle {
                HStack(spacing: 4) {
                    Text("Linked to")
                        .foregroundStyle(.secondary)
                    Text(sourceTitle)
                        .fontWeight(.medium)
                        .foregroundStyle(.primary)
                }
                .font(.system(size: 12))
            } else {
                Text("Linked to source task (deleted or not found)")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
                    .italic()
            }
        }
        .onAppear { fetchSource() }
    }

    private func fetchSource() {
        _Concurrency.Task {
            do {
                let task = try await AppDatabase.shared.read { db in
                    try OYBC.Task.fetchOne(db, key: sharedCounterId)
                }
                await MainActor.run {
                    sourceTitle = task?.isDeleted == false ? task?.title : nil
                    loading = false
                }
            } catch {
                await MainActor.run { loading = false }
            }
        }
    }
}
