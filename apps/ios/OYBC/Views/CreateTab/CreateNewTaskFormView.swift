import SwiftUI

/// Presentational view for the Create-New tab — type picker,
/// per-type fields, progress-step rows, feedback banners, and the
/// submit button. Composite selection falls through to
/// `CompositeTaskWizardView` which owns its own state.
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
    /// Called when `CompositeTaskWizardView` reports a successful save.
    /// Parent uses this to flash "Created compound ... add subtasks
    /// from Existing Tasks" and reload the library.
    var onCompositeCreated: (OYBC.Task) -> Void
    /// Label for the submit button. Defaults to the legacy pool-flow wording.
    var submitLabel: String = "Create & Add to Pool"

    // Phase 6.3 — pickers for ACHIEVEMENT task creation. Loaded lazily
    // when the user selects the Achievement type tab. Kept as state on
    // the view rather than the view model because the data is purely
    // for the picker UI (no submit-time relevance — the submit pipeline
    // just reads `form.achievementReferenceId`).
    @State private var availableBoards: [Board] = []
    @State private var availableTemplates: [RecurringBoardTemplate] = []

    var body: some View {
        // `.frame(maxWidth: .infinity, alignment: .leading)` makes the form
        // stretch to the container's width. Without it, the VStack collapses
        // to the maximum intrinsic width of its children, so inside a sheet
        // (NewTaskSheetView) the form rendered noticeably narrower than the
        // sheet itself. This was visible in the board wizard where the
        // "+ New task" sheet showed a left-aligned column with whitespace
        // on the right.
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
                // Clear the template AND the action/unit/maxCount fields it
                // populated — otherwise switching away from Counting and back
                // leaves stale fields with the picker showing the "Use template"
                // affordance, silently submitting another task's action+unit.
                form.clearTemplate()
                // Phase 6.3 — reset the achievement-mode picker so the user
                // doesn't return to Achievement and find a stale
                // recurringTemplate mode selected with an empty picker
                // beneath. specificBoard is the default.
                form.achievementMode = .specificBoard
                form.achievementReferenceId = nil
            }

            if form.taskType == .composite {
                if let userId = userId {
                    CompositeTaskWizardView(userId: userId, onCreated: onCompositeCreated)
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

                // Progress-specific fields. Detect via the form-level
                // taskType — `selectedType` (TaskType?) maps .progress →
                // .compound under the unified model since Progress writes
                // a compound Task with isOrdered=true.
                if form.taskType == .progress {
                    progressFields
                }

                // Achievement-specific fields (Phase 6.3).
                if form.taskType == .achievement {
                    achievementFields
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
                Button(submitLabel) {
                    onSubmit()
                }
                .buttonStyle(.borderedProminent)
                .disabled(form.isSubmitting || userId == nil)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    // MARK: - Counting fields

    @ViewBuilder
    private var countingFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Counting Details")
                .font(.subheadline)
                .fontWeight(.semibold)

            // "Derive from existing" affordance — only shown when userId is available.
            if let uid = userId {
                CountingTemplatePickerView(
                    userId: uid,
                    selectedTemplate: form.countingDeriveFromTask,
                    onSelect: { form.applyTemplate($0) },
                    onClear: { form.clearTemplate() }
                )
            }

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

    // MARK: - Achievement fields (Phase 6.3)

    @ViewBuilder
    private var achievementFields: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("Watch")
                .font(.subheadline)
                .fontWeight(.semibold)

            Picker("Watch mode", selection: $form.achievementMode) {
                ForEach(AchievementMode.allCases, id: \.self) { mode in
                    Text(mode.rawValue).tag(mode)
                }
            }
            .pickerStyle(.segmented)
            .onChange(of: form.achievementMode) {
                // Switching mode clears the picker selection — an id
                // from one mode is not eligible in the other.
                form.achievementReferenceId = nil
                form.clearFeedback()
            }

            switch form.achievementMode {
            case .specificBoard:
                if availableBoards.isEmpty {
                    Text("No boards yet — create one first.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Picker("Board", selection: Binding(
                        get: { form.achievementReferenceId ?? "" },
                        set: { form.achievementReferenceId = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("Select a board…").tag("")
                        ForEach(availableBoards, id: \.id) { b in
                            Text(b.name).tag(b.id)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
            case .recurringTemplate:
                if availableTemplates.isEmpty {
                    Text("No recurring templates yet — create one first.")
                        .font(.caption)
                        .foregroundColor(.secondary)
                } else {
                    Picker("Template", selection: Binding(
                        get: { form.achievementReferenceId ?? "" },
                        set: { form.achievementReferenceId = $0.isEmpty ? nil : $0 }
                    )) {
                        Text("Select a template…").tag("")
                        ForEach(availableTemplates, id: \.id) { t in
                            Text(t.isActive ? t.name : "\(t.name) (paused)").tag(t.id)
                        }
                    }
                    .pickerStyle(.navigationLink)
                }
            }

            // Trigger picker (Phase 6.3) — what "done" means for the
            // watched target. Default `.greenlog` matches the pre-
            // trigger shipped behavior.
            Text("Complete when")
                .font(.subheadline)
                .padding(.top, 6)
            Picker("Trigger", selection: $form.achievementTrigger) {
                Text("Full board complete").tag(AchievementTrigger.greenlog)
                Text("Any bingo line").tag(AchievementTrigger.bingo)
            }
            .pickerStyle(.segmented)

            // Required-count input (template mode only). Specific-board
            // mode is implicitly count=1 — the field doesn't render.
            if form.achievementMode == .recurringTemplate {
                VStack(alignment: .leading, spacing: 4) {
                    Text("Required count")
                        .font(.subheadline)
                        .padding(.top, 6)
                    TextField("e.g. 3", text: $form.achievementRequiredCountStr)
                        .textFieldStyle(.roundedBorder)
                        .keyboardType(.numberPad)
                    Text("How many in-window spawns must hit the trigger?")
                        .font(.caption)
                        .foregroundColor(.secondary)
                }
            }
        }
        .padding(8)
        .background(Color(.systemGray5))
        .cornerRadius(6)
        .onAppear {
            loadAchievementOptions()
        }
        .onChange(of: form.taskType) {
            // Reload when the user switches into Achievement so a board
            // / template created while another type was selected is
            // visible without dismissing the form.
            if form.taskType == .achievement { loadAchievementOptions() }
        }
    }

    /// Loads non-deleted boards and templates for the current user.
    /// Errors are swallowed (the picker just shows the empty-state
    /// fallback) — the form's submit pipeline will surface a more
    /// specific error if the user tries to save without a selection.
    private func loadAchievementOptions() {
        guard let uid = userId else { return }
        _Concurrency.Task.detached {
            let boards = (try? AppDatabase.shared.fetchBoards(userId: uid)) ?? []
            let templates = (try? AppDatabase.shared.fetchRecurringBoardTemplates(userId: uid)) ?? []
            await MainActor.run {
                availableBoards = boards
                availableTemplates = templates
            }
        }
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
