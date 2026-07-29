import SwiftUI

// MARK: - ArrangeSubMode

/// The two sub-modes available in the wizard's Preview step.
///
/// - `preview`: display-only — no jiggle, no drag. Default.
/// - `rearrange`: squares jiggle; drag-to-insert + tap-to-swap enabled.
///
/// `internal` so `@testable import OYBC` can address it in snapshot tests.
enum ArrangeSubMode: String, Hashable {
    case preview   = "Preview"
    case rearrange = "Rearrange"
}

// MARK: - BoardWizardPreviewStepView

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
///   - Preview ⇄ Rearrange toggle + optional Shuffle button.
///   - Rearrange hint line (when in Rearrange mode).
///   - `RearrangeGrid` — display-only in Preview mode, interactive in Rearrange mode.
///     Drag-to-insert + tap-to-swap; the center square is pinned.
///   - Dashed note: "Tap Create and your board goes live right away."
///   - Summary card rows: Name / Size / Timeframe / Center / Tasks [/ Recurring] with
///     Edit jumps per step.
///   - Riso footer buttons per variant.
///
/// Persistence: `placement` (`@State`) is the single source of truth for both the
/// grid and `persistWizardBoard`. Rearranging via drag/tap updates `placement` via
/// `handleReorder(_:)`; Shuffle re-seeds via `reseedPlacement()`. Both paths ensure
/// what the user sees is exactly what gets saved — no re-roll at persist time.
struct BoardWizardPreviewStepView: View {
    @Bindable var controller: BoardWizardViewModel
    let library: TaskLibraryViewModel
    let userId: String
    let onBack: () -> Void
    let onComplete: (_ boardId: String, _ status: WizardStatus) -> Void
    var onTemplateComplete: ((_ templateId: String) -> Void)? = nil

    @State private var isCreating: Bool = false
    @State private var errorMessage: String? = nil

    /// The arrangement shown in the preview grid AND written to the DB.
    ///
    /// Captured once (seeded on appear, re-seeded when the selection /
    /// geometry / center choice changes, or when the user taps Shuffle)
    /// so the preview and the persisted `BoardTask` rows are guaranteed
    /// identical. A bare computed property here re-rolled the shuffle on
    /// every read, so the saved board differed from the previewed one —
    /// this mirrors web's `useMemo` + `placementRef` capture.
    @State private var placement: WizardPlacement = []

    /// Current sub-mode for the Preview ⇄ Rearrange toggle.
    /// Defaults to `.preview` (display-only). Switches to `.rearrange` when
    /// the user taps the Rearrange segment; the grid gains jiggle + drag/tap.
    @State private var arrangeSubMode: ArrangeSubMode = .preview

    /// Non-deleted TaskEvents grouped by taskId, loaded once on appear —
    /// the read-model the preview grid's windowed completion resolves
    /// against (see `previewIsCompleted`). Empty until the fetch lands
    /// (cells render grey, then settle — same progressive pattern as the
    /// boards-list preview cells).
    @State private var eventsByTaskId: [String: [TaskEvent]] = [:]

    // MARK: - Computed helpers

    private var selectionKey: String {
        Array(controller.selectedTaskIds).sorted().joined(separator: "|")
    }

    /// Single composite token that drives placement re-seeding. Folds in
    /// every input `buildWizardPlacement` actually reads so that:
    ///   - a size tap (which mutates size + centerType + centerTaskId in
    ///     one action) re-seeds ONCE, not three times; and
    ///   - the grid re-resolves once the async library / pending tasks
    ///     finish loading (selected ids that weren't yet in the library
    ///     would otherwise stay nil slots and persist as blank squares).
    /// Mirrors web's `useMemo` deps (`library.allTasks`,
    /// `controller.pendingTasks`, size, centerType, centerTaskId, selection).
    private var placementKey: String {
        "\(selectionKey)|\(controller.size)|\(controller.centerType.rawValue)|\(controller.centerTaskId ?? "")|\(library.libraryTasks.count)|\(controller.pendingTasks.count)"
    }

    /// Re-roll the stored placement from the current wizard state.
    private func reseedPlacement() {
        placement = buildWizardPlacement(controller: controller, library: library)
    }

    // MARK: - Arrange grid helpers

    /// Converts `placement` to `[RearrangeCellData]` for `RearrangeGrid`.
    ///
    /// Center detection mirrors `buildWizardPlacement`:
    ///   - `FREE` / `CUSTOM_FREE`: center slot is nil in placement → pinned,
    ///     taskId nil.
    ///   - `CHOSEN`: center slot holds the chosen Task → pinned, taskId set.
    ///   - `NONE`: center slot holds a regular task (no pinning).
    ///   - Even boards: no center slot.
    private var wizardCells: [RearrangeCellData] {
        let size = controller.size
        let isOdd = controller.isOddBoard
        let centerIdx = isOdd ? (size / 2) * size + (size / 2) : -1

        return placement.enumerated().map { (i, task) in
            let row = i / size
            let col = i % size
            // Pin FREE, CUSTOM_FREE, and CHOSEN center slots on odd boards.
            // NONE falls through — the task occupying the center is movable.
            let isPinnedCenter = isOdd && i == centerIdx && controller.centerType != .none

            if isPinnedCenter, task == nil {
                // FREE or CUSTOM_FREE — nil slot, always pinned.
                return RearrangeCellData(
                    id: "center",
                    taskId: nil,
                    isCenter: true,
                    isEmpty: false,
                    originalRow: row,
                    originalCol: col
                )
            } else if let task = task {
                // Task cell — also pinned when it is the CHOSEN center.
                return RearrangeCellData(
                    id: isPinnedCenter ? "center" : task.id,
                    taskId: task.id,
                    isCenter: isPinnedCenter,
                    isEmpty: false,
                    originalRow: row,
                    originalCol: col
                )
            } else {
                // Nil non-center slot: empty grid slot (fewer tasks than cells).
                return RearrangeCellData(
                    id: "empty-\(row)-\(col)",
                    taskId: nil,
                    isCenter: false,
                    isEmpty: true,
                    originalRow: row,
                    originalCol: col
                )
            }
        }
    }

    /// `Task.id`-keyed lookup map for `RearrangeGrid`. Derived from `placement`.
    private var wizardTaskMap: [String: Task] {
        var map: [String: Task] = [:]
        for task in placement.compactMap({ $0 }) {
            map[task.id] = task
        }
        return map
    }

    /// The prospective board's window lower bound — the SAME resolution the
    /// Save handler persists, so the preview's windowed completion matches
    /// the board the user actually gets. nil while dates are invalid (the
    /// Save button surfaces the error; the grid falls back to lifetime).
    private var previewWindowStart: String? {
        if case .ok(let start, _) = resolveWizardDates(controller: controller) { return start }
        return nil
    }

    /// Library-wide task lookup for compound-child resolution (children are
    /// library tasks, not placed cells), merged with the placement map so
    /// wizard-born pending tasks resolve too.
    private var previewTaskById: [String: Task] {
        var map: [String: Task] = [:]
        for task in library.libraryTasks { map[task.id] = task }
        for task in placement.compactMap({ $0 }) { map[task.id] = task }
        return map
    }

    /// Windowed completion for a preview cell (the "green squares from
    /// previous windows" bug — see `wizardPreviewIsCompleted`).
    private func previewIsCompleted(_ task: Task) -> Bool {
        guard let windowStart = previewWindowStart else { return task.isCompleted }
        return wizardPreviewIsCompleted(
            task: task,
            taskById: previewTaskById,
            childrenByCompound: library.compoundChildrenByCompound,
            eventsByTaskId: eventsByTaskId,
            windowStart: windowStart
        )
    }

    /// Load the events read-model for windowed preview completion.
    private func loadPreviewEvents() {
        do {
            let events = try AppDatabase.shared.fetchNonDeletedTaskEvents(userId: userId)
            eventsByTaskId = Dictionary(grouping: events, by: { $0.taskId })
        } catch {
            // Non-fatal: the grid falls back to empty events (all grey for
            // event-owning tasks) rather than blocking the wizard.
            print("wizard preview: failed to load task events: \(error)")
        }
    }

    /// Maps a `RearrangeGrid` reorder callback back to `@State placement`.
    ///
    /// Array index → slot: center cells (isCenter + no taskId) produce nil;
    /// task cells look up the `Task` by `taskId`; empty cells produce nil.
    /// This ensures `placement` always matches the grid the user is looking at,
    /// and `persistWizardBoard` writes exactly that arrangement — no re-roll.
    private func handleReorder(_ newCells: [RearrangeCellData]) {
        let taskMap = wizardTaskMap
        var newPlacement: WizardPlacement = Array(repeating: nil, count: newCells.count)
        for (i, cell) in newCells.enumerated() {
            if cell.isCenter, cell.taskId == nil {
                // FREE / CUSTOM_FREE center — remains nil in placement.
                newPlacement[i] = nil
            } else if let taskId = cell.taskId, let task = taskMap[taskId] {
                // Task cell (including a CHOSEN center that is pinned).
                newPlacement[i] = task
            }
            // else: empty slot → nil (Array(repeating: nil, …) default)
        }
        placement = newPlacement
    }

    private var taskNames: [String] {
        placement.map { $0?.title ?? "" }
    }

    /// Number of tasks that actually get shuffled into the grid (a CHOSEN
    /// center is pinned, so it doesn't count). Drives the Shuffle button's
    /// visibility — re-rolling <2 tasks is a no-op.
    private var shuffleableCount: Int {
        let n = controller.selectedTaskIds.count
        if controller.isOddBoard && controller.centerType == .chosen {
            return max(0, n - 1)
        }
        return n
    }

    private var canShuffle: Bool {
        controller.isRandomized && shuffleableCount >= 2
    }

    /// Side length for the bingo grid in points, passed explicitly to `RearrangeGrid`.
    ///
    /// `RearrangeGrid` accepts `sideLength` directly rather than measuring via an
    /// internal `GeometryReader` because `proxy.size.width` can reflect the pre-padding
    /// or screen width instead of the correctly inset width when nested inside
    /// `.padding()` modifier chains — a known SwiftUI behaviour that caused cells to
    /// be sized too large and positioned in the wrong area.
    ///
    /// Derived from `UIScreen.main.bounds.width` (reliable for all current iPhone form
    /// factors) minus the horizontal gutters applied by the enclosing VStack's
    /// `.padding(.horizontal, Riso.gutter)`.
    private var gridSideLength: CGFloat {
        max(0, UIScreen.main.bounds.width - 2 * Riso.gutter)
    }

    private var timeframeSummary: String {
        if controller.timeframe == .custom {
            if !controller.customStartDate.isEmpty && !controller.customEndDate.isEmpty {
                return "Custom · \(controller.customStartDate) → \(controller.customEndDate)"
            }
            return "Custom (no dates set)"
        }
        guard let b = controller.computedBoundaries else { return "—" }
        let windowLabel = formatTimeframeLabel(timeframe: controller.timeframe, startDate: b.start)
        if controller.isRecurring {
            return "\(formatRecurringCadence(timeframe: controller.timeframe)) · starting \(windowLabel)"
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

                    // Preview ⇄ Rearrange toggle + optional Shuffle button
                    arrangeControlBar

                    // Rearrange hint — visible only in Rearrange mode
                    if arrangeSubMode == .rearrange {
                        Text("Drag to rearrange · tap two squares to swap")
                            .font(.risoBody(12, .regular))
                            .foregroundStyle(Color.risoMuted)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }

                    // Arrangeable board grid — display-only in Preview mode,
                    // drag+tap interactive in Rearrange mode.
                    // sideLength is passed explicitly: GeometryReader inside RearrangeGrid
                    // does not correctly derive the inset width when nested inside
                    // .padding() modifier chains in a ScrollView context. The caller
                    // provides the known side length (screen width minus gutters) directly.
                    RearrangeGrid(
                        cells: wizardCells,
                        gridSize: controller.size,
                        taskMap: wizardTaskMap,
                        centerSquareType: controller.centerType,
                        centerCustomName: controller.centerCustomName,
                        rearrange: arrangeSubMode == .rearrange,
                        sideLength: gridSideLength,
                        onReorder: { handleReorder($0) },
                        windowedIsCompleted: { previewIsCompleted($0) }
                    )

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
        // Seed the stored placement once when the step appears, and re-seed
        // whenever any placement input changes — collapsed into one keyed
        // handler so a single size tap re-seeds once (not per mutated field)
        // and a late async library load re-resolves the grid. The grid and
        // persist both read this single stored array — never a fresh re-roll
        // — so what's previewed is exactly what's saved.
        .onAppear {
            if placement.isEmpty { reseedPlacement() }
            loadPreviewEvents()
        }
        .onChange(of: placementKey) { _, _ in reseedPlacement() }
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

    // MARK: - Arrange control bar

    /// Toggle (Preview ⇄ Rearrange) + optional Shuffle button in one horizontal bar.
    ///
    /// The Shuffle button re-seeds `placement` from scratch via `reseedPlacement()`,
    /// which triggers `RearrangeGrid.onChange(of:cells)` to animate the new order.
    /// Shuffle is only visible when `canShuffle` (isRandomized + ≥2 shuffleable tasks).
    @ViewBuilder
    private var arrangeControlBar: some View {
        HStack(spacing: 8) {
            RisoSegmented(
                options: [
                    (value: ArrangeSubMode.preview,   label: "Preview"),
                    (value: ArrangeSubMode.rearrange, label: "Rearrange"),
                ],
                selection: $arrangeSubMode
            )

            if canShuffle {
                Button {
                    reseedPlacement()
                } label: {
                    HStack(spacing: 5) {
                        Image(systemName: "shuffle")
                            .font(.system(size: 11, weight: .bold))
                        Text("Shuffle")
                            .font(.risoHead(12, .bold))
                    }
                    .foregroundStyle(Color.risoInk)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 9)
                    .risoCard(fill: .risoPaper2)
                    .risoHardShadow(Riso.Shadow.small)
                }
                .buttonStyle(.plain)
                .disabled(isCreating)
                .accessibilityLabel("Shuffle board layout")
            }
        }
    }
}

// Closing brace for BoardWizardPreviewStepView is above.
// The private extension below keeps the file self-contained.
private extension BoardWizardPreviewStepView {

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
        let dates: (start: String, end: String?)
        switch resolved {
        case .ok(let start, let end):
            dates = (start, end)
        case .error(let msg):
            errorMessage = msg
            return
        }

        isCreating = true
        // Persist the exact arrangement the user is looking at. Guard the
        // (practically impossible) empty case so we never write a blank board.
        let snapshot = placement.isEmpty
            ? buildWizardPlacement(controller: controller, library: library)
            : placement
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
