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
/// Layout (Board Creation Split, iOS PR A — per-mode; README §Screens "2. One-off
/// wizard" / "3. Recurring wizard"):
///   - Centred board name (Bricolage 800 24px) + meta line (mode-specific format).
///   - **One-off**: Preview ⇄ Rearrange toggle + optional Shuffle button, then
///     `RearrangeGrid` (display-only in Preview mode, interactive in Rearrange
///     mode; drag-to-insert + tap-to-swap; center square pinned). NO summary card.
///   - **Recurring**: the selected-task list (`RisoPoolListView`, no grid/
///     rearrange/shuffle), then a 3-row Repeats/Size/Pool summary card with
///     blue "Edit" jumps.
///   - Riso footer buttons per mode (one-off: Back/Draft/Activate — red;
///     recurring: Back/Create Board — blue, no draft).
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
    /// Task Pools + Recurring Boards Rework (P4) — the user's pools, needed
    /// for the recurring "deck" branch's `onRemove`/provenance lookups
    /// (`controller.toggleTaskSelection`/`provenanceByTaskId` both take a
    /// `poolsById` map so removing a pool-sourced task records the right
    /// `removedTaskIds` bookkeeping). Mirrors `BoardWizardView`'s own
    /// `poolsById` derivation. Defaults empty so one-off callers (snapshot
    /// tests, the non-recurring branch) don't need to thread it.
    var pools: [Pool] = []

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
    ///   - `FREE`: center slot is nil in placement → pinned, taskId nil.
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
            // Pin FREE and CHOSEN center slots on odd boards.
            // NONE falls through — the task occupying the center is movable.
            let isPinnedCenter = isOdd && i == centerIdx && controller.centerType != .none

            if isPinnedCenter, task == nil {
                // FREE — nil slot, always pinned.
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
    /// wizard-born pending tasks resolve too. Also carries Inline Task
    /// Editing's staged-new-child placeholders (see
    /// `previewChildrenByCompound`) so a compound's windowed completion isn't
    /// evaluated against a stale child set right after an unsaved edit.
    private var previewTaskById: [String: Task] {
        var map: [String: Task] = [:]
        for task in library.libraryTasks { map[task.id] = task }
        for task in placement.compactMap({ $0 }) { map[task.id] = task }
        for (id, task) in stagedNewChildPlaceholders(userId: userId, stagedEdits: controller.stagedEdits) {
            map[id] = task
        }
        return map
    }

    // MARK: - Recurring "deck" branch lookups (Task Pools + Recurring
    // Boards Rework, P4)

    private var poolsById: [String: Pool] {
        Dictionary(pools.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    private var tasksById: [String: OYBC.Task] {
        Dictionary(library.libraryTasks.map { ($0.id, $0) }, uniquingKeysWith: { first, _ in first })
    }

    /// Task lookup for the deck's `RisoPoolListView`, independent of
    /// `placement` — unlike `previewTaskById`, this must resolve EVERY
    /// selected task, including any beyond a repeating board's fillable
    /// floor that `placement`'s truncated grid never places (overfill is
    /// the variety mechanism for a repeating board's mix, per
    /// docs/POOLS_RECURRING.md §Behavior invariants). Same staged-edit
    /// overlay + staged-new-child-placeholder handling as `previewTaskById`.
    private var deckTaskById: [String: Task] {
        var map: [String: Task] = [:]
        for task in library.libraryTasks { map[task.id] = task }
        for payload in controller.pendingTasks.values { map[payload.task.id] = payload.task }
        for (id, patch) in controller.stagedEdits {
            if let base = map[id] { map[id] = patch.applied(to: base) }
        }
        for (id, task) in stagedNewChildPlaceholders(userId: userId, stagedEdits: controller.stagedEdits) {
            map[id] = task
        }
        return map
    }

    /// Compound-children map, staged-edit-aware — the Step-3 twin of
    /// `BoardWizardTasksStepView.effectiveChildrenByCompound` (both delegate
    /// to the shared `effectiveCompoundChildrenByCompound`), so an unsaved
    /// inline sub-task add/remove is reflected in the preview grid's
    /// completion state exactly as Step 2's pool subtitle already shows it.
    private var previewChildrenByCompound: [String: [CompoundChild]] {
        effectiveCompoundChildrenByCompound(
            library: library,
            pendingTasks: controller.pendingTasks,
            stagedEdits: controller.stagedEdits
        )
    }

    /// Windowed completion for a preview cell (the "green squares from
    /// previous windows" bug — see `wizardPreviewIsCompleted`).
    private func previewIsCompleted(_ task: Task) -> Bool {
        guard let windowStart = previewWindowStart else { return task.isCompleted }
        return wizardPreviewIsCompleted(
            task: task,
            taskById: previewTaskById,
            childrenByCompound: previewChildrenByCompound,
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
            dlog("wizard preview: failed to load task events: \(error)")
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
                // FREE center — remains nil in placement.
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

    // MARK: - Recurring summary-card rows (Board Creation Split, iOS PR A)
    //
    // The one-off Preview has NO summary card at all (frame 1k) — these
    // three rows are recurring-only, replacing the old shared Name/Size/
    // Timeframe/Center/Tasks/Recurring rows. Canonical copy: README
    // §Screens "3. Recurring wizard" — "Every week · first board Aug 17 –
    // 23" / "5×5 · Free center" / "27 tasks · needs at least 25".

    private var recurringRepeatsSummary: String {
        guard let b = controller.computedBoundaries else { return "—" }
        let windowLabel = formatTimeframeLabel(timeframe: controller.timeframe, startDate: b.start)
        return "\(formatRecurringCadence(timeframe: controller.timeframe)) · first board \(windowLabel)"
    }

    private var recurringSizeSummary: String {
        "\(controller.size)×\(controller.size) · \(recurringCenterLabel)"
    }

    /// CHOSEN is unreachable while `isRecurring` (the center-type selector
    /// suppresses it) — the `.chosen` case is a defensive fallback only.
    private var recurringCenterLabel: String {
        switch controller.centerType {
        case .free:   return "Free center"
        case .none:   return "No center"
        case .chosen: return "Free center"
        }
    }

    private var recurringPoolSummary: String {
        "\(controller.selectedTaskIds.count) tasks · needs at least \(controller.tasksRequired)"
    }

    /// Task Pools + Recurring Boards Rework (P5) — core-board setup's
    /// fillable-floor gate on Step 3's Activate button
    /// (docs/POOLS_RECURRING.md §Behavior invariants "Fillable floor
    /// everywhere"). Confirmed gap: before this, Activate was only
    /// `.disabled(isCreating)` — a core board below the floor could reach
    /// Step 3 (Step 2's Next is already gated, but a jump via the stepper
    /// or summary "Edit" links bypasses it) and Activate anyway. Save as
    /// Draft is intentionally NOT gated — drafts may be incomplete.
    private var isBelowCoreFloor: Bool {
        controller.isCore && controller.selectedTaskIds.count < controller.tasksRequired
    }

    /// Board Creation Split (iOS PR A) — "Create Board" replaces the
    /// former "Create template & spawn" (banned mechanics words: no
    /// "template", no "spawn" anywhere in UI copy).
    private var recurringPrimaryLabel: String {
        if isCreating { return "Saving…" }
        if controller.editingTemplateId != nil { return "Save Changes" }
        return "Create Board"
    }

    // MARK: - Body

    var body: some View {
        VStack(spacing: 0) {
            ScrollView {
                VStack(spacing: 20) {
                    // Centred name + meta
                    previewHeader

                    if controller.isRecurring {
                        // Task Pools + Recurring Boards Rework (P4) — a
                        // repeating board's mix isn't a fixed grid (extras
                        // shuffle in per window), so Preview shows the
                        // DECK, not an arrange/shuffle grid. One-off boards
                        // keep the grid below unchanged.
                        deckSection
                    } else {
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
                            rearrange: arrangeSubMode == .rearrange,
                            sideLength: gridSideLength,
                            onReorder: { handleReorder($0) },
                            windowedIsCompleted: { previewIsCompleted($0) }
                        )
                    }

                    // Board Creation Split (iOS PR A) — neither mode's
                    // Preview shows the old dashed "star" note anymore
                    // (frames 1j/1k have no note card at all). One-off has
                    // NO summary card either; recurring's summary is the
                    // 3-row Repeats/Size/Pool card (see `recurringSummaryCard`).
                    if controller.isRecurring {
                        recurringSummaryCard
                    }

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

            Text(previewMetaText)
                .font(.risoBody(12, .bold))
                .foregroundStyle(Color.risoMuted)
        }
        .frame(maxWidth: .infinity)
        .padding(.top, 4)
    }

    /// Board Creation Split (iOS PR A) — meta line diverges per mode
    /// (README §Screens): one-off "Weekly · 3×3 · 8 tasks"; recurring
    /// "Every week · 5×5 · 27-task pool".
    private var previewMetaText: String {
        if controller.isRecurring {
            return "\(formatRecurringCadence(timeframe: controller.timeframe)) · \(controller.size)×\(controller.size) · \(controller.selectedTaskIds.count)-task pool"
        }
        return "\(controller.timeframe.rawValue.capitalized) · \(controller.size)×\(controller.size) · \(controller.selectedTaskIds.count) tasks"
    }

    // MARK: - Pool-list section (recurring — Board Creation Split, iOS PR A)

    /// Recurring-board Preview branch: the full selected-task list (no
    /// health-note header — frame 1j goes straight from the centred name/
    /// meta to the list; `RisoPoolListView` renders its own "On your
    /// board · N" header), reusing `RisoPoolListView` (the exact list the
    /// Pool step already renders) rather than a second list renderer. No
    /// grid/rearrange/shuffle here — a repeating board's mix isn't a fixed
    /// grid (docs/POOLS_RECURRING.md §Behavior invariants: "extras shuffle
    /// into the mix").
    @ViewBuilder
    private var deckSection: some View {
        VStack(alignment: .leading, spacing: 10) {
            RisoPoolListView(
                selectedTaskIds: controller.selectedTaskIds,
                orderedTaskIds: controller.poolOrder,
                effectiveTaskById: deckTaskById,
                effectiveChildrenByCompound: previewChildrenByCompound,
                isRecurring: controller.isRecurring,
                onRemove: { taskId in
                    controller.toggleTaskSelection(taskId, poolsById: poolsById, tasksById: tasksById)
                },
                provenanceByTaskId: controller.provenanceByTaskId(poolsById: poolsById, tasksById: tasksById)
            )
        }
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

    // MARK: - Summary card (recurring only — Board Creation Split, iOS PR A)

    /// Three rows only — Repeats / Size / Pool — each with a blue "Edit"
    /// jump back to Setup (Repeats, Size) or Pool (the task-count row).
    /// The one-off Preview renders no summary card at all (see `body`).
    @ViewBuilder
    private var recurringSummaryCard: some View {
        VStack(alignment: .leading, spacing: 0) {
            previewRow(label: "Repeats", value: recurringRepeatsSummary, jumpTo: 1)
            Divider().background(Color.risoInk.opacity(0.12))
            previewRow(label: "Size", value: recurringSizeSummary, jumpTo: 1)
            Divider().background(Color.risoInk.opacity(0.12))
            previewRow(label: "Pool", value: recurringPoolSummary, jumpTo: 2)
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
        VStack(alignment: .trailing, spacing: 8) {
            if isBelowCoreFloor {
                RisoCoreFloorGateView(remaining: controller.tasksRequired - controller.selectedTaskIds.count)
                    .frame(maxWidth: .infinity, alignment: .trailing)
            }
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
                .disabled(isCreating || isBelowCoreFloor)
            }
        }
        .padding(.horizontal, Riso.gutter)
        .padding(.top, 16)
        .padding(.bottom, 8)
        .background(Color.risoPaper)
    }

    /// Recurring: ‹ Back · Save as Draft · Create Board (or ‹ Back · Save
    /// Changes when editing an existing repeating board — there's no
    /// "draft" concept for an edit, so "Save as Draft" is omitted in that
    /// case, mirroring the pre-PR-B footer exactly). Board Creation Split
    /// (PR B) — accent is blue, matching the wizard's fixed mode.
    @ViewBuilder
    private var recurringFooter: some View {
        HStack(spacing: 10) {
            RisoButton(title: "‹ Back", kind: .neutral, action: onBack)
                .disabled(isCreating)

            Spacer()

            if controller.editingTemplateId == nil {
                RisoButton(title: isCreating ? "Saving…" : "Save as Draft", kind: .neutral) {
                    performCreation(status: .draft)
                }
                .disabled(isCreating)
            }

            RisoButton(title: recurringPrimaryLabel, kind: .blue) {
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
            if status == .draft {
                // Board Creation Split (PR B) — "Save as Draft" now saves
                // a real DRAFT `Board` (the same one-off persist path a
                // one-off wizard uses) instead of creating — and
                // immediately spawning — a `RecurringBoardTemplate`.
                // Nothing runs until "Create Board".
                performRecurringDraftSave()
                return
            }
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
                        ? "Failed to create recurring board: \(msg)"
                        : "Failed to update recurring board: \(msg)"
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

    /// Board Creation Split (PR B) — recurring "Save as Draft". Reuses the
    /// EXACT one-off persist path (`persistWizardBoard(status: .draft)`);
    /// `controller.isRecurring` drives that function's own
    /// `isRecurringDraft` + `recurringDraftMix` bookkeeping (see
    /// `BoardWizardPersist.swift`), so this call site needs no special
    /// casing beyond skipping the (grid-only) `placement` fallback message
    /// wording, which stays the plain "Failed to save draft" — a recurring
    /// draft is never "updating" in the one-off sense of resurrecting a
    /// prior ACTIVE board.
    private func performRecurringDraftSave() {
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
        let snapshot = placement.isEmpty
            ? buildWizardPlacement(controller: controller, library: library)
            : placement
        persistWizardBoard(
            controller: controller,
            userId: userId,
            placement: snapshot,
            dates: dates,
            status: .draft,
            onSuccess: { boardId in
                isCreating = false
                onComplete(boardId, .draft)
            },
            onError: { message in
                isCreating = false
                errorMessage = "Failed to save draft: \(message)"
            }
        )
    }
}
