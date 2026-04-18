import SwiftUI

/// BoardWizardPreviewStepStubView — Step 3 placeholder used to verify
/// end-to-end wizard navigation in the playground. iOS twin of web's
/// `BoardWizardPreviewStepStub`.
///
/// Renders a real `BingoBoard` preview from the wizard's selected
/// task ids plus a summary card and stub Activate / Save Draft
/// buttons. The full implementation (seeded shuffle, edit-jumps that
/// preserve state, real DB writes, navigation to the created board)
/// lands in build sequence step 3.
struct BoardWizardPreviewStepStubView: View {
    @Bindable var controller: BoardWizardViewModel
    let library: TaskLibraryViewModel
    let onBack: () -> Void
    /// Stub callback — real DB write lands in build-sequence step 3.
    let onActivate: () -> Void
    /// Stub callback — real DB write lands in build-sequence step 3.
    let onSaveDraft: () -> Void

    private var selectedTasks: [Task] {
        library.libraryTasks.filter { controller.selectedTaskIds.contains($0.id) }
    }

    /// Task names laid out for the preview grid. Matches the web stub:
    /// for CHOSEN center, the chosen task is placed at the center cell;
    /// remaining tasks fill the rest in the configured order (shuffled
    /// or not).
    private var taskNames: [String] {
        let base = selectedTasks.map { $0.title }
        let size = controller.size
        let needed = size * size
        if controller.centerMode, let id = controller.centerTaskId,
           let centerTask = selectedTasks.first(where: { $0.id == id }) {
            let rest = selectedTasks.filter { $0.id != id }.map { $0.title }
            let ordered = controller.isRandomized ? Shuffle.fisherYatesShuffle(rest) : rest
            var cells = Array(ordered.prefix(needed - 1))
            let centerIdx = (size / 2) * size + (size / 2)
            if centerIdx <= cells.count {
                cells.insert(centerTask.title, at: centerIdx)
            } else {
                cells.append(centerTask.title)
            }
            return Array(cells.prefix(needed))
        }
        let ordered = controller.isRandomized ? Shuffle.fisherYatesShuffle(base) : base
        return Array(ordered.prefix(controller.tasksRequired))
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

            // Stub banner
            HStack(spacing: 8) {
                Image(systemName: "info.circle")
                    .foregroundColor(.blue)
                Text("**Preview stub** — full preview, edit-jumps, and real DB writes ship in build-sequence step 3.")
                    .font(.caption)
                    .foregroundColor(.blue)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .padding(8)
            .background(Color.blue.opacity(0.10))
            .cornerRadius(6)

            // Live preview — uses existing BingoBoard view
            HStack { Spacer(); previewBoard; Spacer() }

            // Summary card with edit jumps
            VStack(alignment: .leading, spacing: 4) {
                summaryRow(label: "Name", value: controller.name.isEmpty ? "(unset)" : controller.name, jumpTo: 1)
                summaryRow(label: "Size", value: "\(controller.size)×\(controller.size)", jumpTo: 1)
                summaryRow(label: "Timeframe", value: timeframeSummary, jumpTo: 1)
                summaryRow(label: "Center", value: centerSummary, jumpTo: 1)
                summaryRow(
                    label: "Tasks",
                    value: "\(selectedTasks.count) selected · \(controller.tasksRequired) required",
                    jumpTo: 2
                )
                summaryRow(label: "Randomize", value: controller.isRandomized ? "Yes" : "No", jumpTo: 1)
            }
            .padding(12)
            .background(Color(.systemGray6))
            .cornerRadius(8)

            Divider()

            // Footer
            HStack {
                Button("‹ Back", action: onBack)
                    .buttonStyle(.bordered)
                Spacer()
                Button("Save as Draft", action: onSaveDraft)
                    .buttonStyle(.bordered)
                Button("Activate Board", action: onActivate)
                    .buttonStyle(.borderedProminent)
                    .tint(.green)
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
            centerSquareCustomName: controller.centerCustomName.isEmpty ? nil : controller.centerCustomName
        )
        // Force re-mount when geometry / selection changes since
        // BingoBoard snapshots its task labels on first render.
        .id("\(controller.size)-\(controller.centerType.rawValue)-\(taskNames.joined(separator: "|"))")
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
}
