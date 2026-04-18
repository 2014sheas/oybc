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
    let onComplete: (_ boardId: String, _ status: WizardStatus) -> Void

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
        if let b = controller.computedBoundaries {
            return playgroundTimeframeLabel(timeframe: controller.timeframe, startDate: b.start)
        }
        return "—"
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

            HStack {
                Button("‹ Back", action: onBack)
                    .buttonStyle(.bordered)
                    .disabled(isCreating)
                Spacer()
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
