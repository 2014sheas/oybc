import SwiftUI

/// One row in the Create-tab recurring-templates list. Web twin:
/// `apps/web/src/components/recurringTemplates/RecurringTemplateRow.tsx`.
struct RecurringTemplateRowView: View {

    // MARK: - Inputs

    let template: RecurringBoardTemplate
    /// Set when this template's last spawn (or its synchronous validation
    /// against the library) flagged a problem. Surfaces a banner row.
    /// Wider than `SpawnPoolFailureReason` because the spawn driver can
    /// also report `noPoolTasksResolved` and `spawnFailed` outcomes.
    var attentionReason: SpawnAttentionReason?

    /// Tap-to-edit handler. The parent owns the form sheet presentation.
    let onEdit: () -> Void

    /// Invoked after a successful toggle/delete commit so the parent can
    /// reload `RecurringBoardTemplatesViewModel.templates` — without this,
    /// the row's Toggle would snap back to the input prop's value because
    /// the parent's snapshot doesn't reflect the just-written change. The
    /// Section view threads `templatesVM.reloadAsync` through here.
    let onTemplatesChanged: () -> Void

    // MARK: - State

    @State private var busy = false
    @State private var deleteError: String?
    @State private var showDeleteConfirm = false

    /// Optimistic mirror of `template.isActive`. The Toggle binds to this
    /// rather than the immutable input prop so a tap immediately reflects
    /// in the UI; the async write commits in parallel and the parent
    /// reload swaps in the canonical row a moment later. If the write
    /// fails the optimistic flip stays — acceptable given the failure is
    /// logged, and the next view re-render with fresh templates will
    /// correct it. SwiftUI's `@State` initial-value capture only runs
    /// once at row construction, but ForEach with `id: \.id` keys a new
    /// state container per template id, so this stays in sync with the
    /// data identity even when the parent reloads.
    @State private var optimisticIsActive: Bool

    init(
        template: RecurringBoardTemplate,
        attentionReason: SpawnAttentionReason? = nil,
        onEdit: @escaping () -> Void,
        onTemplatesChanged: @escaping () -> Void
    ) {
        self.template = template
        self.attentionReason = attentionReason
        self.onEdit = onEdit
        self.onTemplatesChanged = onTemplatesChanged
        self._optimisticIsActive = State(initialValue: template.isActive)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(alignment: .top, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text(template.name)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundStyle(template.isActive ? .primary : .secondary)
                    Text(metaLine)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Toggle("", isOn: Binding(
                    get: { optimisticIsActive },
                    set: { newValue in toggleActive(newValue) }
                ))
                .labelsHidden()
                .disabled(busy)
                .accessibilityLabel(optimisticIsActive
                                    ? "Pause \(template.name)"
                                    : "Activate \(template.name)")
            }

            if let reason = attentionReason {
                attentionBanner(reason: reason)
            }

            HStack(spacing: 8) {
                Button("Edit") {
                    onEdit()
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(busy)

                Button(role: .destructive) {
                    showDeleteConfirm = true
                } label: {
                    Text("Delete")
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .disabled(busy)
                .accessibilityLabel("Delete \(template.name)")

                if let err = deleteError {
                    Text(err)
                        .font(.caption2)
                        .foregroundStyle(.red)
                }
            }
        }
        .padding(.vertical, 6)
        .opacity(template.isActive ? 1.0 : 0.7)
        .confirmationDialog(
            "Delete \"\(template.name)\"? Boards spawned from this template will not be deleted.",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        }
    }

    private func attentionBanner(reason: SpawnAttentionReason) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
                .font(.caption)
            Text(message(for: reason))
                .font(.caption2)
                .foregroundStyle(.primary)
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.orange.opacity(0.3), lineWidth: 0.5)
        )
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - Display

    private var metaLine: String {
        let tf = template.timeframe.rawValue.capitalized
        let size = "\(template.boardSize)×\(template.boardSize)"
        let pool = "\(template.seedTaskIds.count)-task pool"
        return "\(tf) · \(size) · \(pool)"
    }

    private func message(for reason: SpawnAttentionReason) -> String {
        switch reason {
        case .poolTooSmall:
            return "Pool is too small for the current configuration. Edit to add tasks."
        case .hasDeletedTasks:
            return "A task in this template was deleted. Edit to refresh the pool."
        case .unsupportedTimeframe:
            return "This template's timeframe is no longer supported."
        case .unsupportedCenter:
            return "This template's center cell is no longer supported."
        case .noPoolTasksResolved:
            return "None of this template's tasks could be loaded. Edit to refresh the pool."
        case .spawnFailed:
            return "Spawn failed unexpectedly. Try editing this template to refresh."
        }
    }

    // MARK: - Actions

    private func toggleActive(_ newValue: Bool) {
        guard !busy else { return }
        // Optimistic flip — UI reflects intent immediately; the async
        // write below commits in the background.
        optimisticIsActive = newValue
        busy = true
        let now = AppDatabase.currentTimestamp()
        var updated = template
        updated.isActive = newValue
        updated.updatedAt = now
        updated.version += 1
        _Concurrency.Task.detached {
            do {
                try AppDatabase.shared.saveRecurringBoardTemplate(updated)
                try AppDatabase.shared.write { db in
                    try SyncQueueBuilder.makeItem(
                        entityType: "recurringBoardTemplates",
                        entityId: updated.id,
                        operationType: .update,
                        payload: updated,
                        now: now
                    ).insert(db)
                }
                await MainActor.run {
                    busy = false
                    onTemplatesChanged()
                }
            } catch {
                print("[recurring-template] toggleActive failed: \(error)")
                await MainActor.run {
                    // Roll back optimistic flip so the UI reflects the
                    // committed state on failure.
                    optimisticIsActive = template.isActive
                    busy = false
                }
            }
        }
    }

    private func delete() {
        guard !busy else { return }
        busy = true
        deleteError = nil
        _Concurrency.Task.detached {
            do {
                try AppDatabase.shared.softDeleteRecurringBoardTemplate(id: template.id)
                if let tombstone = try AppDatabase.shared.fetchRecurringBoardTemplate(id: template.id) {
                    let now = AppDatabase.currentTimestamp()
                    try AppDatabase.shared.write { db in
                        try SyncQueueBuilder.makeItem(
                            entityType: "recurringBoardTemplates",
                            entityId: tombstone.id,
                            operationType: .delete,
                            payload: tombstone,
                            now: now
                        ).insert(db)
                    }
                }
                await MainActor.run {
                    busy = false
                    onTemplatesChanged()
                }
            } catch {
                await MainActor.run {
                    busy = false
                    deleteError = "Delete failed"
                    print("[recurring-template] delete failed: \(error)")
                }
            }
        }
    }
}
