import SwiftUI

/// BoardWizardPreviewStepView — Step 3 of the wizard.
///
/// **Riso reskin** — wizard-only view, reskinned in place. All persist logic,
/// callback wiring, and branch behaviour are preserved verbatim:
///   - `performCreation(status:)` with its recurring / one-off branches.
///   - Three button-set variants (one-off: Back/Draft/Activate; recurring: Back/Create or Save).
///   - `persistWizardBoard`, `persistRecurringTemplate` call sites unchanged.
///
/// Layout (per README §3 Step-3 + wizard.jsx):
///   - Centred board name (Bricolage 800 24px) + meta line (timeframe · size · task count).
///   - Riso preview mini-grid: keyline cells, task titles, ink FREE + gold star.
///   - Dashed note: "Tap Create and your board goes live right away."
///   - Summary card rows: Name / Size / Timeframe / Center / Tasks [/ Recurring] with
///     Edit jumps per step.
///   - Riso footer buttons per variant.
struct BoardWizardPreviewStepView: View {
    @Bindable var controller: BoardWizardViewModel
    let library: TaskLibraryViewModel
    let userId: String
    let onBack: () -> Void
    let onComplete: (_ boardId: String, _ status: WizardStatus) -> Void
    var onTemplateComplete: ((_ templateId: String) -> Void)? = nil

    @State private var isCreating: Bool = false
    @State private var errorMessage: String? = nil

    // MARK: - Computed helpers

    private var selectionKey: String {
        Array(controller.selectedTaskIds).sorted().joined(separator: "|")
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

    private var recurringSummary: String {
        "Spawns a new \(controller.timeframe.rawValue) board from a \(controller.selectedTaskIds.count)-task pool (random subset each window)."
    }

    private var recurringPrimaryLabel: String {
        if isCreating { return "Saving…" }
        if controller.editingTemplateId != nil { return "Save changes" }
        return "Create template & spawn"
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    // Centred name + meta
                    previewHeader

                    // Mini board grid
                    HStack { Spacer(); previewGrid; Spacer() }

                    // Dashed note
                    previewNote

                    // Summary card
                    summaryCard

                    // Error
                    if let msg = errorMessage {
                        Text(msg)
                            .font(.risoBody(12, .semibold))
                            .foregroundStyle(Color.risoRed)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 8)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .risoCard(fill: Color.risoRed.opacity(0.08))
                    }
                }
                .padding(.horizontal, Riso.gutter)
                .padding(.top, 4)
                .padding(.bottom, 16)
            }

            risoFooter
        }
    }

    // MARK: - Header

    @ViewBuilder
    private var previewHeader: some View {
        VStack(spacing: 4) {
            Text(controller.name.isEmpty ? "Unnamed Board" : controller.name)
                .font(.risoHead(24, .extraBold))
                .tracking(-0.48)
                .foregroundStyle(Color.risoInk)
                .multilineTextAlignment(.center)

            Text("\(controller.timeframe.rawValue.capitalized) · \(controller.size)×\(controller.size) · \(controller.selectedTaskIds.count) tasks")
                .font(.risoBody(12, .bold))
                .foregroundStyle(Color.risoMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    // MARK: - Preview grid

    @ViewBuilder
    private var previewGrid: some View {
        // Reuse the existing BingoBoard widget in readOnly mode — it already
        // renders correctly and is the established verification surface.
        // `.id(...)` forces re-mount on layout-affecting changes (same as
        // the original implementation).
        BingoBoard(
            taskNames: taskNames,
            gridSize: controller.size,
            squareSize: 60,
            centerSquareType: controller.centerType,
            centerSquareCustomName: controller.centerCustomName.isEmpty ? nil : controller.centerCustomName,
            readOnly: true
        )
        .id("\(controller.size)-\(controller.centerType.rawValue)-\(selectionKey)-\(controller.centerTaskId ?? "")")
        .padding(8)
        .risoCard(fill: .risoPaper2)
        .risoHardShadow(Riso.Shadow.card)
    }

    // MARK: - Note

    /// Note copy matching the actual primary action for this flow, so it's
    /// not misleading in the draft / recurring-edit states.
    private var previewNoteText: String {
        if controller.editingTemplateId != nil {
            return "Save changes to update your recurring template."
        }
        if controller.isRecurring {
            return "Create your template and spawn the first board."
        }
        return "Activate to go live now, or save it as a draft for later."
    }

    @ViewBuilder
    private var previewNote: some View {
        HStack(spacing: 8) {
            Image(systemName: "star.fill")
                .font(.system(size: 11))
                .foregroundStyle(Color.risoGold)
            Text(previewNoteText)
                .font(.risoBody(12, .semibold))
                .foregroundStyle(Color.risoMuted)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .overlay(
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .strokeBorder(style: StrokeStyle(lineWidth: Riso.Keyline.container, dash: [6, 4]))
                .foregroundStyle(Color.risoInk)
        )
    }

    // MARK: - Summary card

    @ViewBuilder
    private var summaryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            previewRow(label: "Name",
                       value: controller.name.isEmpty ? "(unset)" : controller.name,
                       jumpTo: 1)
            Divider().background(Color.risoInk.opacity(0.12))
            previewRow(label: "Size",
                       value: "\(controller.size)×\(controller.size)",
                       jumpTo: 1)
            Divider().background(Color.risoInk.opacity(0.12))
            previewRow(label: "Timeframe",
                       value: timeframeSummary,
                       jumpTo: 1)
            Divider().background(Color.risoInk.opacity(0.12))
            previewRow(label: "Center",
                       value: centerSummary,
                       jumpTo: 1)
            Divider().background(Color.risoInk.opacity(0.12))
            previewRow(
                label: "Tasks",
                value: "\(controller.selectedTaskIds.count) selected · \(controller.tasksRequired) required",
                jumpTo: 2
            )
            if controller.isRecurring {
                Divider().background(Color.risoInk.opacity(0.12))
                previewRow(label: "Recurring",
                           value: recurringSummary,
                           jumpTo: 1)
            }
        }
        .risoCard()
    }

    @ViewBuilder
    private func previewRow(label: String, value: String, jumpTo step: WizardStep) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Text(label)
                .risoSectionLabel()
                .frame(width: 80, alignment: .leading)

            Text(value)
                .font(.risoBody(12, .semibold))
                .foregroundStyle(Color.risoInk)
                .frame(maxWidth: .infinity, alignment: .leading)

            Button("Edit") {
                controller.goToStep(step)
            }
            .font(.risoHead(11, .bold))
            .foregroundStyle(Color.risoBlue)
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
    }

    // MARK: - Footer

    @ViewBuilder
    private var risoFooter: some View {
        VStack(spacing: 0) {
            Rectangle()
                .fill(Color.risoInk)
                .frame(height: Riso.Keyline.container)

            if !controller.isRecurring {
                oneOffFooter
            } else {
                recurringFooter
            }
        }
    }

    /// One-off: ‹ Back · Save as Draft · Activate Board
    @ViewBuilder
    private var oneOffFooter: some View {
        HStack(spacing: 10) {
            RisoButton(title: "‹ Back", kind: .neutral, action: onBack)
                .disabled(isCreating)

            Spacer()

            RisoButton(title: isCreating ? "Saving…" : "Save as Draft", kind: .neutral) {
                performCreation(status: .draft)
            }
            .disabled(isCreating)

            RisoButton(title: isCreating ? "Activating…" : "Activate Board", kind: .primary) {
                performCreation(status: .active)
            }
            .disabled(isCreating)
        }
        .padding(.horizontal, Riso.gutter)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .background(Color.risoPaper)
    }

    /// Recurring: ‹ Back · Create template & spawn (or Save changes)
    @ViewBuilder
    private var recurringFooter: some View {
        HStack(spacing: 10) {
            RisoButton(title: "‹ Back", kind: .neutral, action: onBack)
                .disabled(isCreating)

            Spacer()

            RisoButton(title: recurringPrimaryLabel, kind: .primary) {
                performCreation(status: .active)
            }
            .disabled(isCreating)
        }
        .padding(.horizontal, Riso.gutter)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .background(Color.risoPaper)
    }

    // MARK: - Creation logic (verbatim from original)

    private func performCreation(status: WizardStatus) {
        errorMessage = nil

        if controller.isRecurring {
            isCreating = true
            persistRecurringTemplate(
                controller: controller,
                userId: userId,
                onSuccess: { outcome in
                    isCreating = false
                    switch outcome {
                    case .createdAndSpawned(let templateId, let boardId):
                        _ = templateId
                        onComplete(boardId, status)
                    case .createdSpawnSkipped(let templateId, _):
                        onTemplateComplete?(templateId)
                    case .updated(let templateId):
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
