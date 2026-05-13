import SwiftUI

/// BoardWizardPreviewStepView — Step 3 of the wizard. iOS twin of
/// web's `BoardWizardPreviewStep`.
///
/// Renders a read-only `BingoBoard` preview, a summary card with
/// edit-jumps, and Activate / Save Draft buttons. The actual DB
/// writes delegate to `persistWizardBoard` in `BoardWizardPersist.swift`
/// so the same logic can be reused by the cancel dialog's Save-Draft
/// path.
///
/// The placement (which task goes where) is computed once via the
/// `placement` computed property, keyed off the wizard's selection
/// signature so the visual preview and the persisted records stay in
/// sync.
struct BoardWizardPreviewStepView: View {
    @Bindable var controller: BoardWizardViewModel
    let library: TaskLibraryViewModel
    let userId: String
    let onBack: () -> Void
    /// Called after the board record + all `BoardTask` rows have been
    /// written. In recurring mode this fires only when the spawn produced
    /// a board — the parent appends `boardId` to its NavigationPath, so
    /// passing a templateId here would navigate to a non-existent board.
    /// Use `onTemplateComplete` for template-only outcomes.
    let onComplete: (_ boardId: String, _ status: WizardStatus) -> Void
    /// Phase 6.2: called when a recurring template was saved without a
    /// spawnable board (skip OR edit). The parent should switch to the
    /// Profile tab so the user lands on the templates list, not on a
    /// board id that doesn't exist. Optional so existing one-off call
    /// sites that wire the old `onComplete` only continue to work.
    var onTemplateComplete: ((_ templateId: String) -> Void)? = nil

    @State private var isCreating: Bool = false
    @State private var errorMessage: String? = nil

    private var selectionKey: String {
        Array(controller.selectedTaskIds).sorted().joined(separator: "|")
    }

    private var selectedTasks: [Task] {
        library.libraryTasks.filter { controller.selectedTaskIds.contains($0.id) }
    }

    private var placement: WizardPlacement {
        buildWizardPlacement(controller: controller, library: library)
    }

    private var taskNames: [String] {
        placement.map { $0?.title ?? "" }
    }

    private var timeframeSummary: String {
        if controller.timeframe == .custom {
            if !controller.customStartDate.isEmpty && !controller.customEndDate.isEmpty {
                return "Custom · \(controller.customStartDate) → \(controller.customEndDate)"
            }
            return "Custom (no dates set)"
        }
        guard let b = controller.computedBoundaries else { return "—" }
        let windowLabel = playgroundTimeframeLabel(timeframe: controller.timeframe, startDate: b.start)
        if controller.isRecurring {
            // Recurring: lead with the cadence ("Every week") and show
            // the first-spawn window after, so the row can't be confused
            // with a one-off board for that single window.
            return "\(recurringCadenceLabel(timeframe: controller.timeframe)) · starting \(windowLabel)"
        }
        return windowLabel
    }

    private var centerSummary: String {
        if !controller.isOddBoard { return "n/a (even board)" }
        switch controller.centerType {
        case .free:
            return "Free space"
        case .customFree:
            let trimmed = controller.centerCustomName.trimmingCharacters(in: .whitespacesAndNewlines)
            return trimmed.isEmpty ? "Custom (unnamed)" : "Custom · \"\(trimmed)\""
        case .chosen:
            if let id = controller.centerTaskId,
               let task = library.libraryTasks.first(where: { $0.id == id }) {
                return "Chosen · \"\(task.title)\""
            }
            return "Chosen (none picked)"
        case .none:
            return "None"
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {

            // Live preview using existing BingoBoard in readOnly mode
            HStack { Spacer(); previewBoard; Spacer() }

            // Summary card with edit jumps
            VStack(alignment: .leading, spacing: 4) {
                summaryRow(label: "Name", value: controller.name.isEmpty ? "(unset)" : controller.name, jumpTo: 1)
                summaryRow(label: "Size", value: "\(controller.size)×\(controller.size)", jumpTo: 1)
                summaryRow(label: "Timeframe", value: timeframeSummary, jumpTo: 1)
                summaryRow(label: "Center", value: centerSummary, jumpTo: 1)
                summaryRow(
                    label: "Tasks",
                    value: "\(controller.selectedTaskIds.count) selected · \(controller.tasksRequired) required",
                    jumpTo: 2
                )
                summaryRow(label: "Randomize", value: controller.isRandomized ? "Yes" : "No", jumpTo: 1)
                if controller.isRecurring {
                    summaryRow(
                        label: "Recurring",
                        value: recurringSummary,
                        jumpTo: 1
                    )
                }
            }
            .padding(12)
            .background(Color(.systemGray6))
            .cornerRadius(8)

            if let msg = errorMessage {
                Text(msg)
                    .font(.caption)
                    .foregroundColor(.red)
                    .padding(.horizontal, 10)
                    .padding(.vertical, 6)
                    .background(Color.red.opacity(0.1))
                    .cornerRadius(6)
            }

            Divider()

            // Three button-set variants — see web `BoardWizardPreviewStep`
            // for parallel rationale. The actual write branching lives
            // in `BoardWizardPersist` (see Commit B); this view only
            // chooses the label.
            HStack {
                Button("‹ Back", action: onBack)
                    .buttonStyle(.bordered)
                    .disabled(isCreating)
                Spacer()
                if !controller.isRecurring {
                    Button(isCreating ? "Saving…" : "Save as Draft") {
                        performCreation(status: .draft)
                    }
                    .buttonStyle(.bordered)
                    .disabled(isCreating)
                    Button(isCreating ? "Activating…" : "Activate Board") {
                        performCreation(status: .active)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(isCreating)
                } else {
                    Button(recurringPrimaryLabel) {
                        performCreation(status: .active)
                    }
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
                    .disabled(isCreating)
                }
            }
        }
        .padding(16)
        .background(Color(.systemBackground))
    }

    @ViewBuilder
    private var previewBoard: some View {
        BingoBoard(
            taskNames: taskNames,
            gridSize: controller.size,
            squareSize: 70,
            centerSquareType: controller.centerType,
            centerSquareCustomName: controller.centerCustomName.isEmpty ? nil : controller.centerCustomName,
            readOnly: true
        )
        // Force re-mount on layout-affecting changes since BingoBoard
        // snapshots its task labels on first render.
        .id("\(controller.size)-\(controller.centerType.rawValue)-\(selectionKey)-\(controller.centerTaskId ?? "")-\(controller.isRandomized)")
    }

    private var recurringSummary: String {
        return "Spawns a new \(controller.timeframe.rawValue) board from a \(controller.selectedTaskIds.count)-task pool (random subset each window)."
    }

    private var recurringPrimaryLabel: String {
        if isCreating { return "Saving…" }
        if controller.editingTemplateId != nil { return "Save changes" }
        return "Create template & spawn first board"
    }

    @ViewBuilder
    private func summaryRow(label: String, value: String, jumpTo step: WizardStep) -> some View {
        HStack(alignment: .top) {
            Text(label)
                .font(.caption)
                .fontWeight(.semibold)
                .foregroundColor(.secondary)
                .frame(width: 88, alignment: .leading)
            Text(value)
                .font(.caption)
                .foregroundColor(.primary)
                .frame(maxWidth: .infinity, alignment: .leading)
            Button("Edit") {
                controller.goToStep(step)
            }
            .font(.caption)
            .buttonStyle(.borderless)
        }
    }

    private func performCreation(status: WizardStatus) {
        errorMessage = nil

        // Recurring branch — persist the template and (for fresh creates)
        // immediately spawn the current window's board. The status arg
        // is ignored: recurring templates have no draft concept.
        if controller.isRecurring {
            isCreating = true
            persistRecurringTemplate(
                controller: controller,
                userId: userId,
                onSuccess: { outcome in
                    isCreating = false
                    switch outcome {
                    case .createdAndSpawned(let templateId, let boardId):
                        // Pass the spawned board id so cross-tab nav can
                        // land on the actual board (matches web behavior).
                        _ = templateId
                        onComplete(boardId, status)
                    case .createdSpawnSkipped(let templateId, _):
                        // Template saved; spawn skipped — route the user
                        // to the Profile templates list (via the parent's
                        // `onTemplateComplete`) so they see the attention
                        // badge. Falling back to `onComplete(templateId, …)`
                        // would push the templateId onto the boards
                        // NavigationPath and try to render BoardPlayView
                        // for a non-existent board.
                        onTemplateComplete?(templateId)
                    case .updated(let templateId):
                        // Edit path — no spawn. Same routing as the skip
                        // case so the user lands back on the templates list.
                        onTemplateComplete?(templateId)
                    }
                },
                onError: { msg in
                    isCreating = false
                    errorMessage = controller.editingTemplateId == nil
                        ? "Failed to create recurring template: \(msg)"
                        : "Failed to update recurring template: \(msg)"
                }
            )
            return
        }

        // One-off branch — existing behavior unchanged.
        let resolved = resolveWizardDates(controller: controller)
        let dates: (start: String, end: String)
        switch resolved {
        case .ok(let start, let end):
            dates = (start, end)
        case .error(let msg):
            errorMessage = msg
            return
        }

        isCreating = true
        let snapshot = placement
        persistWizardBoard(
            controller: controller,
            userId: userId,
            placement: snapshot,
            dates: dates,
            status: status,
            onSuccess: { boardId in
                isCreating = false
                onComplete(boardId, status)
            },
            onError: { message in
                isCreating = false
                errorMessage = controller.draftBoardId == nil
                    ? "Failed to create board: \(message)"
                    : "Failed to update draft: \(message)"
            }
        )
    }
}
