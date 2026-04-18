import SwiftUI

/// Status the wizard's `onComplete` callback fires with, mirroring the
/// web `CompletionStatus` union.
enum WizardCompletionStatus: String {
    case active
    case draft
}

/// BoardWizardPreviewStepView — Step 3 of the wizard. iOS twin of
/// web's `BoardWizardPreviewStep`.
///
/// Renders a read-only `BingoBoard` preview, a summary card with
/// edit-jumps, and Activate / Save Draft buttons. Activation writes
/// a new `Board` (status `.active`) plus per-cell `BoardTask`
/// records to GRDB in a single transaction. "Save as Draft" writes
/// the same records but with `status: .draft` and skips the activate
/// flip; either path then fires `onComplete(boardId, status)`.
///
/// The placement (which task goes where) is built once via the
/// computed `placement` property, keyed off the wizard's selection
/// signature so the visual preview and the persisted records are
/// guaranteed to match.
struct BoardWizardPreviewStepView: View {
    @Bindable var controller: BoardWizardViewModel
    let library: TaskLibraryViewModel
    let userId: String
    let onBack: () -> Void
    let onComplete: (_ boardId: String, _ status: WizardCompletionStatus) -> Void

    @State private var isCreating: Bool = false
    @State private var errorMessage: String? = nil

    /// Stable signature for the current selection — drives `.id(...)`
    /// re-mounts on the preview grid so a fresh shuffle happens only
    /// when something layout-affecting actually changes.
    private var selectionKey: String {
        Array(controller.selectedTaskIds).sorted().joined(separator: "|")
    }

    /// All selected tasks resolved to `Task` records.
    private var selectedTasks: [Task] {
        library.libraryTasks.filter { controller.selectedTaskIds.contains($0.id) }
    }

    /// Per-cell placement of size² entries. `nil` slots only appear at
    /// the reserved center for FREE / CUSTOM_FREE; every other slot is
    /// a real Task. Same algorithm as the web side.
    private var placement: [Task?] {
        let size = controller.size
        let total = size * size
        let isOdd = size % 2 != 0
        let centerIdx = (size / 2) * size + (size / 2)

        let chosenCenter: Task? = {
            guard isOdd, controller.centerType == .chosen, let id = controller.centerTaskId else {
                return nil
            }
            return selectedTasks.first(where: { $0.id == id })
        }()
        let others: [Task] = chosenCenter != nil
            ? selectedTasks.filter { $0.id != chosenCenter!.id }
            : selectedTasks
        let ordered = controller.isRandomized
            ? Shuffle.fisherYatesShuffle(others)
            : others

        var grid: [Task?] = Array(repeating: nil, count: total)
        var oi = 0
        for i in 0..<total {
            if i == centerIdx && isOdd {
                if let center = chosenCenter {
                    grid[i] = center
                    continue
                }
                if controller.centerType == .free || controller.centerType == .customFree {
                    // Reserved cell — leave nil; BingoBoard renders FREE label.
                    continue
                }
                // NONE on odd: fall through and place a regular task.
            }
            if oi < ordered.count {
                grid[i] = ordered[oi]
                oi += 1
            }
        }
        return grid
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

    // MARK: - Persistence

    /// Resolves the local-ISO start/end strings for the new Board. Mirrors
    /// the existing `BoardCreatorPanelView` behaviour so the wizard
    /// produces dates indistinguishable from the legacy panel's output.
    private func resolveDates() -> (start: String, end: String)? {
        if controller.timeframe != .custom {
            guard let b = controller.computedBoundaries else { return nil }
            return (wizardLocalISOString(b.start), wizardLocalISOString(b.end))
        }
        guard !controller.customStartDate.isEmpty, !controller.customEndDate.isEmpty,
              let s = parseWizardCalendarDate(controller.customStartDate),
              let e = parseWizardCalendarDate(controller.customEndDate)
        else { return nil }
        let cal = Calendar.current
        let dayStart = cal.startOfDay(for: s)
        let nextDay = cal.date(byAdding: .day, value: 1, to: cal.startOfDay(for: e))!
        let dayEnd = nextDay.addingTimeInterval(-0.001)
        return (wizardLocalISOString(dayStart), wizardLocalISOString(dayEnd))
    }

    private func performCreation(status: WizardCompletionStatus) {
        errorMessage = nil
        guard let dates = resolveDates() else {
            errorMessage = controller.timeframe == .custom
                ? "Pick a start and end date."
                : "Could not resolve timeframe boundaries."
            return
        }

        let trimmedName = controller.name.trimmingCharacters(in: .whitespacesAndNewlines)
        let placementSnapshot = placement
        let size = controller.size
        let isOdd = size % 2 != 0
        let centerRow = size / 2
        let centerCol = size / 2

        let now = AppDatabase.currentTimestamp()
        let boardId = AppDatabase.generateUUID()

        let customCenterName: String? = controller.centerType == .customFree
            ? controller.centerCustomName.trimmingCharacters(in: .whitespacesAndNewlines)
            : nil
        let chosenCenterId: String? = controller.centerType == .chosen
            ? controller.centerTaskId
            : nil

        isCreating = true

        DispatchQueue.global(qos: .userInitiated).async {
            do {
                let boardDict: [String: Any] = {
                    var d: [String: Any] = [
                        "id": boardId,
                        "userId": userId,
                        "name": trimmedName,
                        "status": status.rawValue,
                        "boardSize": size,
                        "timeframe": controller.timeframe.rawValue,
                        "startDate": dates.start,
                        "endDate": dates.end,
                        "centerSquareType": controller.centerType.rawValue,
                        "isRandomized": controller.isRandomized,
                        "totalTasks": size * size,
                        "completedTasks": 0,
                        "linesCompleted": 0,
                        "createdAt": now,
                        "updatedAt": now,
                        "version": 1,
                        "isDeleted": false
                    ]
                    if let name = customCenterName, !name.isEmpty {
                        d["centerSquareCustomName"] = name
                    }
                    if let id = chosenCenterId {
                        d["centerTaskId"] = id
                    }
                    return d
                }()
                let boardData = try JSONSerialization.data(withJSONObject: boardDict)
                let board = try JSONDecoder().decode(Board.self, from: boardData)

                var boardTasks: [BoardTask] = []
                for (i, slot) in placementSnapshot.enumerated() {
                    guard let task = slot else { continue }
                    let row = i / size
                    let col = i % size
                    let isCenterPos = isOdd && row == centerRow && col == centerCol
                    let bt = BoardTask.makePlayground(
                        boardId: boardId,
                        taskId: task.id,
                        row: row,
                        col: col,
                        now: now,
                        isCenter: isCenterPos
                            && (controller.centerType == .chosen || controller.centerType == .none)
                    )
                    boardTasks.append(bt)
                }

                try AppDatabase.shared.write { db in
                    try board.save(db)
                    for bt in boardTasks {
                        try bt.save(db)
                    }
                }

                DispatchQueue.main.async {
                    isCreating = false
                    onComplete(boardId, status)
                }
            } catch {
                DispatchQueue.main.async {
                    isCreating = false
                    errorMessage = "Failed to create board: \(error.localizedDescription)"
                }
            }
        }
    }
}
