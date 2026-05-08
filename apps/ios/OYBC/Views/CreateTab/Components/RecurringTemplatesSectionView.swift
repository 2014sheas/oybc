import SwiftUI

/// RecurringTemplatesSectionView — Phase 6.2 surface on the Create tab.
/// Mounted between the drafts list and the library section. Web twin:
/// `apps/web/src/components/recurringTemplates/RecurringTemplatesSection.tsx`.
struct RecurringTemplatesSectionView: View {

    // MARK: - Inputs

    let userId: String
    let templates: [RecurringBoardTemplate]
    let libraryTasks: [Task]
    /// Validation failures keyed by template id, surfaced as a banner per row.
    let attentionByTemplateId: [String: SpawnPoolFailureReason]
    /// Invoked after the form sheet dismisses successfully so the parent
    /// can reload the list (mirrors the iOS drafts-reload-after-save
    /// pattern from `CreateHubView`).
    let onTemplatesChanged: () -> Void

    // MARK: - State

    @State private var presentingForm = false
    @State private var editingTemplate: RecurringBoardTemplate?

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                Text("Recurring templates")
                    .font(.caption2)
                    .fontWeight(.semibold)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    presentingForm = true
                } label: {
                    Label("New template", systemImage: "plus")
                        .labelStyle(.titleAndIcon)
                        .font(.caption)
                        .fontWeight(.semibold)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
            }

            if templates.isEmpty {
                Text("Set up a recurring template to auto-generate boards each day, week, month, or year.")
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .padding(12)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .background(Color.secondary.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 8)
                            .stroke(Color.secondary.opacity(0.2),
                                    style: StrokeStyle(lineWidth: 1, dash: [4]))
                    )
                    .clipShape(RoundedRectangle(cornerRadius: 8))
            } else {
                VStack(alignment: .leading, spacing: 6) {
                    ForEach(templates, id: \.id) { tpl in
                        RecurringTemplateRowView(
                            template: tpl,
                            attentionReason: attentionByTemplateId[tpl.id],
                            onEdit: { editingTemplate = tpl }
                        )
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                        .background(
                            RoundedRectangle(cornerRadius: 10)
                                .fill(Color(.systemBackground))
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: 10)
                                .stroke(Color.secondary.opacity(0.2), lineWidth: 0.5)
                        )
                    }
                }
            }
        }
        .sheet(isPresented: $presentingForm, onDismiss: onTemplatesChanged) {
            RecurringTemplateFormView(
                userId: userId,
                libraryTasks: libraryTasks,
                existing: nil,
                onClose: { presentingForm = false }
            )
        }
        .sheet(item: editingTemplateBinding, onDismiss: onTemplatesChanged) { item in
            RecurringTemplateFormView(
                userId: userId,
                libraryTasks: libraryTasks,
                existing: item.template,
                onClose: { editingTemplate = nil }
            )
        }
    }

    // MARK: - Sheet binding adapter

    /// SwiftUI's `.sheet(item:)` requires `Identifiable`. Wrap the
    /// editing-template state so the existing template can drive sheet
    /// presentation without a separate `bool + ?` pair.
    private var editingTemplateBinding: Binding<EditingItem?> {
        Binding(
            get: {
                if let t = editingTemplate { return EditingItem(template: t) }
                return nil
            },
            set: { newValue in
                if newValue == nil { editingTemplate = nil }
            }
        )
    }

    private struct EditingItem: Identifiable {
        let template: RecurringBoardTemplate
        var id: String { template.id }
    }
}
