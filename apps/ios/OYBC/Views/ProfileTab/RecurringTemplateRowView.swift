import SwiftUI

/// RecurringTemplateRowView — Riso-styled card row for a single recurring
/// board template. Used by snapshot tests; the production list now renders
/// cards inline inside RecurringTemplatesView. This component is the
/// snapshot-testable leaf that represents a single card.
///
/// Layout (Riso card): name (H3 bold) + timeframe color tag + active switch,
/// then a meta line showing size · pool count · renew cadence or "paused".
/// Paused cards dim to 0.7 opacity.
struct RecurringTemplateRowView: View {

    // MARK: - Inputs

    let template: RecurringBoardTemplate
    var attentionReason: SpawnAttentionReason? = nil
    let onEdit: () -> Void
    let onTemplatesChanged: () -> Void

    // MARK: - State

    @State private var busy = false
    @State private var showDeleteConfirm = false
    @State private var deleteError: String?
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
        VStack(alignment: .leading, spacing: 8) {
            // Name row + tag + switch
            HStack(spacing: 8) {
                Text(template.name)
                    .font(.risoHead(17, .extraBold))
                    .foregroundStyle(optimisticIsActive ? Color.risoInk : Color.risoMuted)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .lineLimit(1)

                timeframeTag

                RisoPillSwitch(isOn: Binding(
                    get: { optimisticIsActive },
                    set: { newValue in toggleActive(newValue) }
                ))
                .disabled(busy)
            }

            // Attention banner (if any)
            if let reason = attentionReason {
                attentionBanner(reason)
            }

            // Meta line
            HStack(spacing: 4) {
                Text("\(template.boardSize)×\(template.boardSize)")
                    .font(.risoBody(12, .bold))
                    .foregroundStyle(optimisticIsActive ? Color.risoInk : Color.risoMuted)
                Text("board").font(.risoBody(12, .regular)).foregroundStyle(Color.risoMuted)
                Text("·").foregroundStyle(Color.risoMuted)
                Text("\(template.seedTaskIds.count)")
                    .font(.risoBody(12, .bold))
                    .foregroundStyle(optimisticIsActive ? Color.risoInk : Color.risoMuted)
                Text("-task pool").font(.risoBody(12, .regular)).foregroundStyle(Color.risoMuted)
                Text("·").foregroundStyle(Color.risoMuted)
                if optimisticIsActive {
                    Text("renews \(renewText)").font(.risoBody(12, .regular)).foregroundStyle(Color.risoMuted)
                } else {
                    Text("paused").font(.risoBody(12, .regular)).foregroundStyle(Color.risoMuted)
                }
            }

            // Edit / Delete buttons
            HStack(spacing: 8) {
                Button("Edit") { onEdit() }
                    .buttonStyle(.bordered).controlSize(.small).disabled(busy)
                Button(role: .destructive) { showDeleteConfirm = true } label: { Text("Delete") }
                    .buttonStyle(.bordered).controlSize(.small).disabled(busy)
                    .accessibilityLabel("Delete \(template.name)")
                if let err = deleteError {
                    Text(err).font(.caption2).foregroundStyle(Color.risoRed)
                }
            }
        }
        .padding(.vertical, 6)
        .opacity(optimisticIsActive ? 1.0 : 0.7)
        .confirmationDialog(
            "Delete \"\(template.name)\"? Boards spawned from this template will not be deleted.",
            isPresented: $showDeleteConfirm,
            titleVisibility: .visible
        ) {
            Button("Delete", role: .destructive) { delete() }
            Button("Cancel", role: .cancel) {}
        }
    }

    // MARK: - Sub-views

    private var timeframeTag: some View {
        Text(template.timeframe.risoDisplayName.uppercased())
            .font(.risoHead(9, .bold)).tracking(0.4)
            .foregroundStyle(Color.risoPaper)
            .padding(.vertical, 3).padding(.horizontal, 8)
            .background(Capsule().fill(template.timeframe.risoColor))
            .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
    }

    private func attentionBanner(_ reason: SpawnAttentionReason) -> some View {
        HStack(alignment: .top, spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange).font(.caption)
            Text(attentionMessage(reason))
                .font(.caption2).foregroundStyle(.primary)
        }
        .padding(8).frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.1))
        .overlay(RoundedRectangle(cornerRadius: 6).stroke(Color.orange.opacity(0.3), lineWidth: 0.5))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    private var renewText: String {
        switch template.timeframe {
        case .weekly: return "Mondays"
        case .monthly: return "the 1st"
        case .daily: return "every morning"
        case .yearly: return "Jan 1"
        case .custom: return "custom"
        }
    }

    private func attentionMessage(_ reason: SpawnAttentionReason) -> String {
        switch reason {
        case .poolTooSmall: return "Pool is too small for the current configuration. Edit to add tasks."
        case .hasDeletedTasks: return "A task in this template was deleted. Edit to refresh the pool."
        case .unsupportedTimeframe: return "This template's timeframe is no longer supported."
        case .unsupportedCenter: return "This template's center cell is no longer supported."
        case .noPoolTasksResolved: return "None of this template's tasks could be loaded. Edit to refresh."
        case .spawnFailed: return "Spawn failed unexpectedly. Try editing this template to refresh."
        }
    }

    // MARK: - Actions

    private func toggleActive(_ newValue: Bool) {
        guard !busy else { return }
        optimisticIsActive = newValue
        busy = true
        let now = AppDatabase.currentTimestamp()
        var updated = template; updated.isActive = newValue
        updated.updatedAt = now; updated.version += 1
        _Concurrency.Task.detached {
            do {
                try AppDatabase.shared.saveRecurringBoardTemplate(updated)
                try AppDatabase.shared.write { db in
                    try SyncQueueBuilder.makeItem(
                        entityType: "recurringBoardTemplates",
                        entityId: updated.id, operationType: .update,
                        payload: updated, now: now
                    ).insert(db)
                }
                await MainActor.run { busy = false; onTemplatesChanged() }
            } catch {
                print("[RecurringTemplateRowView] toggleActive failed: \(error)")
                await MainActor.run { optimisticIsActive = template.isActive; busy = false }
            }
        }
    }

    private func delete() {
        guard !busy else { return }
        busy = true; deleteError = nil
        _Concurrency.Task.detached {
            do {
                try AppDatabase.shared.softDeleteRecurringBoardTemplate(id: template.id)
                if let tombstone = try AppDatabase.shared.fetchRecurringBoardTemplate(id: template.id) {
                    let now = AppDatabase.currentTimestamp()
                    try AppDatabase.shared.write { db in
                        try SyncQueueBuilder.makeItem(
                            entityType: "recurringBoardTemplates",
                            entityId: tombstone.id, operationType: .delete,
                            payload: tombstone, now: now
                        ).insert(db)
                    }
                }
                await MainActor.run { busy = false; onTemplatesChanged() }
            } catch {
                await MainActor.run { busy = false; deleteError = "Delete failed"
                    print("[RecurringTemplateRowView] delete failed: \(error)") }
            }
        }
    }
}
