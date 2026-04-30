import GRDB
import SwiftUI

/// CountingTemplatePickerView — "Derive from existing" affordance for the
/// counting-type variant of `CreateNewTaskFormView`. Mirrors the web
/// `CountingTemplatePicker` component.
///
/// When no template is selected: shows a dashed "Use existing counting task
/// as template..." button that opens a `.confirmationDialog` / sheet list of
/// counting tasks from the user's library.
///
/// When a template is selected: shows a compact banner "Template: <title>"
/// with a clear (×) button. The parent view model's `countingAction` and
/// `countingUnit` will have been pre-filled; `countingMaxCount` is left empty
/// for the user to enter.
///
/// Loads counting tasks via a one-shot GRDB read on appear so it doesn't
/// need to thread a full `TaskLibraryViewModel` down the call chain.
struct CountingTemplatePickerView: View {

    /// The authenticated user whose task library to query.
    let userId: String

    /// The counting Task currently used as a derivation template, or nil.
    let selectedTemplate: OYBC.Task?

    /// Called when the user picks a source counting task.
    let onSelect: (OYBC.Task) -> Void

    /// Called when the user clears the current template selection.
    let onClear: () -> Void

    @State private var showPicker = false
    @State private var countingTasks: [OYBC.Task] = []
    @State private var loadError: String?

    var body: some View {
        Group {
            if let template = selectedTemplate {
                selectedBanner(template: template)
            } else {
                affordanceButton
            }
        }
        .onAppear { loadCountingTasks() }
        // Re-load on every sheet open so a counting task created elsewhere
        // in this session shows up. `.onAppear` only fires once on the
        // outer Group; without this, the picker silently omits any task
        // the user created while the form was already mounted.
        .onChange(of: showPicker) {
            if showPicker { loadCountingTasks() }
        }
        .sheet(isPresented: $showPicker) {
            pickerSheet
        }
    }

    // MARK: - Sub-views

    /// Dashed button shown when no template is selected.
    private var affordanceButton: some View {
        Button {
            showPicker = true
        } label: {
            HStack {
                Image(systemName: "doc.on.doc")
                    .font(.caption)
                Text("Use existing counting task as template...")
                    .font(.subheadline)
                Spacer()
            }
            .foregroundColor(.secondary)
            .padding(.vertical, 8)
            .padding(.horizontal, 10)
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .stroke(style: StrokeStyle(lineWidth: 1, dash: [4]))
                    .foregroundColor(.secondary.opacity(0.5))
            )
        }
        .buttonStyle(.plain)
    }

    /// Compact banner shown after a template is chosen.
    private func selectedBanner(template: OYBC.Task) -> some View {
        HStack(spacing: 6) {
            Text("Template:")
                .font(.caption)
                .foregroundColor(.secondary)
                .fixedSize()

            Text(template.title)
                .font(.subheadline)
                .fontWeight(.medium)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button {
                onClear()
            } label: {
                Image(systemName: "xmark.circle.fill")
                    .foregroundColor(.secondary)
                    .font(.subheadline)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Clear template")
        }
        .padding(.vertical, 7)
        .padding(.horizontal, 10)
        .background(Color(.systemGray6))
        .overlay(
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.accentColor.opacity(0.6), lineWidth: 1)
        )
        .cornerRadius(6)
    }

    /// Sheet that lists all counting tasks for selection.
    private var pickerSheet: some View {
        NavigationStack {
            Group {
                if let error = loadError {
                    Text(error)
                        .foregroundColor(.red)
                        .padding()
                } else if countingTasks.isEmpty {
                    VStack(spacing: 12) {
                        Image(systemName: "tray")
                            .font(.largeTitle)
                            .foregroundColor(.secondary)
                        Text("No counting tasks in your library yet.")
                            .foregroundColor(.secondary)
                            .multilineTextAlignment(.center)
                    }
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                } else {
                    List(countingTasks, id: \.id) { task in
                        Button {
                            onSelect(task)
                            showPicker = false
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text(task.title)
                                    .foregroundColor(.primary)
                                if let action = task.action, let unit = task.unit {
                                    Text("\(action) · \(unit)")
                                        .font(.caption)
                                        .foregroundColor(.secondary)
                                }
                            }
                        }
                    }
                    .listStyle(.plain)
                }
            }
            .navigationTitle("Choose template")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { showPicker = false }
                }
            }
        }
    }

    // MARK: - Data loading

    /// One-shot GRDB read. Lightweight; counting tasks are small-N.
    private func loadCountingTasks() {
        _Concurrency.Task {
            do {
                let tasks = try await AppDatabase.shared.read { db in
                    try OYBC.Task
                        .filter(Column("userId") == userId &&
                                Column("type") == "counting" &&
                                Column("isDeleted") == false)
                        .order(Column("title"))
                        .fetchAll(db)
                }
                await MainActor.run {
                    self.countingTasks = tasks
                    self.loadError = nil
                }
            } catch {
                await MainActor.run {
                    self.loadError = "Could not load counting tasks: \(error.localizedDescription)"
                }
            }
        }
    }
}
