import SwiftUI

/// Presentational view for the Create-New tab — type picker,
/// per-type fields, progress-step rows, feedback banners, and the
/// submit button. Composite selection falls through to
/// `CompositeTaskFormView` which owns its own state.
///
/// Mirrors the web `CreateNewTaskForm.tsx` component. No data-layer
/// calls live here; the `form` / `userId` / callbacks the parent
/// threads in carry all side-effect plumbing.
struct CreateNewTaskFormView: View {
    @Bindable var form: CreateFormViewModel
    let userId: String?
    /// Called when the user taps "Create & Add to Pool" on the
    /// NORMAL/COUNTING/PROGRESS form. Parent binds this to
    /// `form.handleCreateAndAddToPool(userId:...)` with the right
    /// onTaskCreated + onLibraryReloadRequested callbacks.
    var onSubmit: () -> Void
    /// Called when `CompositeTaskFormView` reports a successful save.
    /// Parent uses this to flash "Created composite ... add subtasks
    /// from Existing Tasks" and reload the library.
    var onCompositeCreated: (CompositeTask) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Create Task")
                .font(.headline)

            // Type picker
            Picker("Task Type", selection: $form.taskType) {
                ForEach(CreateTaskType.allCases, id: \.self) { pt in
                    Text(pt.rawValue).tag(pt)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: form.taskType) {
                form.clearFeedback()
            }

            if form.taskType == .composite {
                if let userId = userId {
                    CompositeTaskFormView(userId: userId, onCreated: onCompositeCreated)
                }
            } else {
                // Shared title field
                VStack(alignment: .leading, spacing: 4) {
                    TextField(
                        form.selectedType == .counting
                            ? "Title (auto-generated if blank)"
                            : "Title (required)",
                        text: $form.title
                    )
                    .textFieldStyle(.roundedBorder)
                    Text("\(form.title.count)/\(CreateFormLimits.title)")
                        .font(.caption)
                        .foregroundColor(form.title.count > CreateFormLimits.title ? .red : .secondary)
                }

                // Shared description field
                VStack(alignment: .leading, spacing: 4) {
                    TextField("Description (optional)", text: $form.description, axis: .vertical)
                        .textFieldStyle(.roundedBorder)
                        .lineLimit(3...)
                    Text("\(form.description.count)/\(CreateFormLimits.description)")
                        .font(.caption)
                        .foregroundColor(form.description.count > CreateFormLimits.description ? .red : .secondary)
                }

                // Counting-specific fields
                if form.selectedType == .counting {
                    countingFields
                }

                // Progress-specific fields
                if form.selectedType == .progress {
                    progressFields
                }

                // Feedback
                if let error = form.errorMessage {
                    Text(error)
                        .foregroundColor(.red)
                        .font(.caption)
                }
                if let success = form.successMessage {
                    Text(success)
                        .foregroundColor(.green)
                        .font(.caption)
                }

                // Submit
                Button("Create & Add to Pool") {
                    onSubmit()
                }
                .buttonStyle(.borderedProminent)
                .disabled(form.isSubmitting || userId == nil)
            }
        }
    }

    // MARK: - Counting fields

    @ViewBuilder
    private var countingFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Counting Details")
                .font(.subheadline)
                .fontWeight(.semibold)

            VStack(alignment: .leading, spacing: 4) {
                TextField("Action (e.g. Run, Read)", text: $form.countingAction)
                    .textFieldStyle(.roundedBorder)
                Text("\(form.countingAction.count)/\(CreateFormLimits.action)")
                    .font(.caption)
                    .foregroundColor(form.countingAction.count > CreateFormLimits.action ? .red : .secondary)
            }

            TextField("Max Count (positive integer)", text: $form.countingMaxCount)
                .textFieldStyle(.roundedBorder)
                .keyboardType(.numberPad)

            VStack(alignment: .leading, spacing: 4) {
                TextField("Unit (e.g. miles, pages)", text: $form.countingUnit)
                    .textFieldStyle(.roundedBorder)
                Text("\(form.countingUnit.count)/\(CreateFormLimits.unit)")
                    .font(.caption)
                    .foregroundColor(form.countingUnit.count > CreateFormLimits.unit ? .red : .secondary)
            }
        }
        .padding(8)
        .background(Color(.systemGray5))
        .cornerRadius(6)
    }

    // MARK: - Progress fields

    @ViewBuilder
    private var progressFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Steps")
                .font(.subheadline)
                .fontWeight(.semibold)

            ForEach(form.progressSteps.indices, id: \.self) { i in
                ProgressStepRowView(
                    index: i,
                    step: $form.progressSteps[i],
                    stepCount: form.progressSteps.count,
                    errors: form.progressStepErrors[form.progressSteps[i].id],
                    onRemove: {
                        guard form.progressSteps.count > 1 else { return }
                        form.progressSteps.remove(at: i)
                    }
                )
            }

            Button("Add Step") {
                form.progressSteps.append(ProgressStepFormState())
            }
            .font(.subheadline)
        }
    }
}
