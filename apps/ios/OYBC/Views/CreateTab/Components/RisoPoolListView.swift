import SwiftUI

/// Riso-styled pool list for the wizard Tasks step.
///
/// Shows the user's current selection as ink-keylined rows:
///   grip · name · type-detail subtitle · `RisoTypeBadge` pill · remove ✕
///
/// The "empty pool" state is a dashed-border note card matching screenshot 04.
///
/// Removal fires `onRemove(taskId)` which routes to the parent's
/// `toggleSelection` helper to keep deselection logic centralized.
struct RisoPoolListView: View {

    /// Which surface hosts the list — only the copy differs (the pool editor
    /// reuses the wizard's list verbatim). `.board` is the wizard default.
    enum Surface {
        case board, pool

        var header: String { self == .board ? "On your board" : "In this pool" }
        var removeLabel: String { self == .board ? "Remove from board" : "Remove from pool" }
        var emptyNote: String { "Nothing here yet." }
    }

    var surface: Surface = .board
    let selectedTaskIds: Set<String>
    /// Render order (insertion order from `BoardWizardViewModel.poolOrder`).
    /// Rows render in this order — no alphabetical sort — so a renamed task
    /// keeps its position. `selectedTaskIds` still drives membership + the count.
    let orderedTaskIds: [String]
    let effectiveTaskById: [String: OYBC.Task]
    let effectiveChildrenByCompound: [String: [CompoundChild]]
    let isRecurring: Bool
    let onRemove: (_ taskId: String) -> Void

    /// When true (center type == CHOSEN), each pool row shows a tappable
    /// star to mark that task as the board's center square. Mirrors web's
    /// per-row center radio in `BoardWizardTasksStep`.
    var centerTaskMode: Bool = false
    /// The currently-marked center task id, or `nil` if none picked.
    var centerTaskId: String? = nil
    /// Fired when the user taps a row's star. Caller toggles the mark
    /// (set, or unset when tapping the already-marked task).
    var onSetCenter: ((_ taskId: String) -> Void)? = nil

    /// Fired when the user taps a row's pencil (editable tasks only). nil ⇒ no
    /// pencil is shown (e.g. snapshot contexts that don't wire editing).
    var onEdit: ((_ taskId: String) -> Void)? = nil
    /// The board's window: a counting row that isn't a linked copy captions
    /// the goal placement gives it there (a counter's window default, else its own).
    var counterGoalWindow: CounterPlacement.PickWindow? = nil
    /// The wizard's per-cell placement parameters: a hand-edited goal wins
    /// over the window default (`BoardWizardViewModel.placementParams`).
    var placementParams: [String: PlacementParamsDraft] = [:]

    /// The row currently open in the inline editor, if any. That row is
    /// replaced in place by `editor`.
    var editingTaskId: String? = nil
    /// Builds the inline editor view for the open row (owned by the parent, so
    /// it holds the draft/focus/toast state). nil ⇒ never swaps.
    var editor: ((OYBC.Task) -> AnyView)? = nil

    /// Board Sources P2 — overrides the count pill (the CAPACITY, not the
    /// flat selection size). Defaults to the legacy selection count so
    /// existing call sites render unchanged.
    var countOverride: Int? = nil
    /// Board Sources P2 — source rows rendered ABOVE the hand-added task
    /// rows inside the same "On your board" section (the step passes a
    /// `ForEach` of `RisoSourceRowView`s). nil ⇒ task rows only.
    var leadingRows: AnyView? = nil

    /// §Member rules (B3) — dice level per HAND-ADDED counting task
    /// (`BoardWizardViewModel.manualTaskVary`). Absent ids are `.off`.
    var manualTaskVary: [String: VaryLevel] = [:]
    /// Sets a hand-added counting task's dice level. nil ⇒ no dice is
    /// shown (and no range line, which without a control to change it
    /// would be a dead end).
    var onSetManualVary: ((_ taskId: String, _ level: VaryLevel) -> Void)? = nil

    // MARK: - Ordered pool

    /// Pool in insertion order (from the parent's `poolOrder`). No sort — a
    /// renamed task must keep its position. Ids without a resolved task
    /// (mid-hydration races) are skipped.
    private var poolTasks: [OYBC.Task] {
        orderedTaskIds.compactMap { effectiveTaskById[$0] }
    }

    var body: some View {
        if selectedTaskIds.isEmpty && leadingRows == nil {
            emptyPoolNote
        } else {
            VStack(alignment: .leading, spacing: 9) {
                // Section header
                HStack(spacing: 6) {
                    Text(surface.header)
                        .risoSectionLabel()
                    // Count pill (capacity when sources are in play).
                    Text("\(countOverride ?? selectedTaskIds.count)")
                        .font(.risoHead(10, .extraBold))
                        .foregroundStyle(Color.risoPaper)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.risoInk))
                }

                VStack(spacing: 7) {
                    if let leadingRows { leadingRows }
                    ForEach(poolTasks, id: \.id) { task in
                        if task.id == editingTaskId, let editor {
                            editor(task).id(task.id)
                        } else {
                            poolRow(task).id(task.id)
                        }
                    }
                }
            }
        }
    }

    // MARK: - Empty state

    private var emptyPoolNote: some View {
        Text(surface.emptyNote)
            .font(.risoBody(12.5, .semibold))
            .foregroundStyle(Color.risoMuted)
            .multilineTextAlignment(.center)
            .padding(16)
            .frame(maxWidth: .infinity)
            .overlay(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .strokeBorder(
                        style: StrokeStyle(lineWidth: Riso.Keyline.container, dash: [5, 4])
                    )
                    .foregroundStyle(Color.risoMuted.opacity(0.5))
            )
    }

    // MARK: - Pool row

    private func poolRow(_ task: OYBC.Task) -> some View {
        let isCenter = centerTaskMode && centerTaskId == task.id
        let detail = typeDetailSubtitle(task, isCenter: isCenter)
        // Pencil is shown for editable in-pool tasks (normal / counting /
        // compound). Achievement is never editable in the pool (it shows the
        // "TASKS TAB" marker instead).
        let showsPencil = onEdit != nil
            && (task.type == .normal || task.type == .counting || task.type == .compound)
        // §Member rules (B3) — a hand-added COUNTING row earns a dice: it
        // needs a goal to vary around. Hand-added counters vary around
        // their own goal, so there is no window to pro-rate against.
        let goal = task.type == .counting ? (boardGoal(task) ?? task.maxCount ?? 0) : 0
        let showsDice = onSetManualVary != nil && goal > 0
        let varyLevel = manualTaskVary[task.id] ?? .off
        let varyRange = showsDice
            ? BoardSources.varyRangeLabel(
                t: goal, level: varyLevel, goal: goal, unit: task.unit ?? "",
                kind: resolveCountKind(task.countKind)
            )
            : nil

        return HStack(alignment: .center, spacing: 9) {
            badge(task, isCenter: isCenter)

            // Name + detail (+ the blue range line, left-aligned with the
            // title, when the dice is on).
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.risoHead(14, .bold))
                    .foregroundStyle(Color.risoInk)
                    .lineLimit(1)
                RisoRowSubtitleView(
                    counterTagName: rowCounterTagName(task: task, rootsById: effectiveTaskById),
                    text: detail, fontSize: 10.5, weight: .semibold
                )
                if let varyRange {
                    Text(varyRange)
                        .font(.risoBody(10.5, .semibold))
                        .foregroundStyle(Color.risoBlue)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)

            if showsDice, let onSetManualVary {
                RisoDiceButton(level: varyLevel) {
                    onSetManualVary(task.id, varyLevel.next)
                }
            }

            // Edit affordance: pencil (editable) or the read-only "TASKS TAB"
            // marker (achievement). Compound in PR 1 shows neither.
            if showsPencil {
                pencilButton(task)
            } else if task.type == .achievement && surface == .board {
                // Board surface only: the pool editor already lives in the
                // Tasks tab, so a legacy achievement row keeps an empty gutter.
                tasksTabMarker
            }

            // Remove button
            Button {
                onRemove(task.id)
            } label: {
                Text("✕")
                    .font(.system(size: 14, weight: .semibold))
                    .foregroundStyle(Color.risoMuted)
                    .frame(width: 28, height: 28)
            }
            .buttonStyle(.plain)
            .contentShape(Rectangle())
            .accessibilityLabel(surface.removeLabel)
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .risoCard(fill: .risoPaper2)
    }

    /// Type badge (letter square). In CHOSEN center mode it doubles as the
    /// center control; the marked task carries a gold ★ notch at the badge's
    /// top-right (replaces the old leading star column, which left no room for
    /// a pencil at 393pt).
    @ViewBuilder
    private func badge(_ task: OYBC.Task, isCenter: Bool) -> some View {
        let badgeView = RisoTypeBadge(kind: risoKind(for: task.type), style: .letterSquare)
            .overlay(alignment: .topTrailing) {
                if isCenter { centerNotch.offset(x: 6, y: -6) }
            }

        if centerTaskMode {
            Button { onSetCenter?(task.id) } label: { badgeView }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel(isCenter ? "Center task" : "Mark as center task")
                .accessibilityAddTraits(isCenter ? [.isSelected] : [])
        } else {
            badgeView
        }
    }

    private var centerNotch: some View {
        Text("★")
            .font(.system(size: 8, weight: .bold))
            .foregroundStyle(Color.risoInkStatic)
            .frame(width: 15, height: 15)
            .background(RoundedRectangle(cornerRadius: 4).fill(Color.risoGold))
            .overlay(RoundedRectangle(cornerRadius: 4).strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
    }

    private func pencilButton(_ task: OYBC.Task) -> some View {
        Button {
            onEdit?(task.id)
        } label: {
            Image(systemName: "pencil")
                .font(.system(size: 14, weight: .semibold))
                .foregroundStyle(Color.risoInk)
                .frame(width: 32, height: 32)
                .risoCard(fill: .risoPaper)
        }
        .buttonStyle(.plain)
        .contentShape(Rectangle())
        .accessibilityLabel("Edit task")
    }

    /// Read-only marker for achievement rows — trigger/target are edited in the
    /// Tasks tab, not inline.
    private var tasksTabMarker: some View {
        Text("TASKS TAB")
            .font(.risoBody(9, .extraBold))
            .tracking(0.9)
            .foregroundStyle(Color.risoMuted)
            .padding(.horizontal, 7)
            .padding(.vertical, 5)
            .overlay(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .strokeBorder(style: StrokeStyle(lineWidth: Riso.Keyline.container, dash: [3, 3]))
                    .foregroundStyle(Color.risoInk)
            )
    }

    // MARK: - Helpers

    /// The goal an unlinked counting row gets on this board: its placement
    /// override, else a counter's window default, else its own (nil without
    /// either). Web twin: `PoolList`'s `windowGoalOf`.
    private func boardGoal(_ task: OYBC.Task) -> CountValue? {
        guard task.type == .counting, task.sharedCounterId == nil else { return nil }
        if let override = placementParams[task.id]?.targetOverride { return override }
        guard let w = counterGoalWindow else { return nil }
        return CounterPlacement.placementGoalForCounter(
            CounterSettings.Fields(task: task), timeframe: w.timeframe, startDate: w.startDate, endDate: w.endDate
        )
    }

    /// Counting row detail — `goal {value}` at the task's kind (the title carries action + unit).
    static func countingSubtitle(_ task: OYBC.Task) -> String? {
        TaskCountDisplay.goalOnlySubtitle(for: task)
    }

    /// Detail subtitle. `isCenter` prefixes "Center square · ".
    private func typeDetailSubtitle(_ task: OYBC.Task, isCenter: Bool) -> String? {
        let base: String? = {
            switch task.type {
            case .normal:
                return nil
            case .counting:
                // The goal the board will get: a counter's window default, else its own.
                if let goal = boardGoal(task) {
                    return "goal \(formatCount(goal, kind: resolveCountKind(task.countKind)))"
                }
                return Self.countingSubtitle(task)
            case .compound:
                // `effectiveChildrenByCompound` / `task.operatorType` /
                // `task.threshold` are all already staged-edit-aware (Inline
                // Task Editing overlays them onto `effectiveTaskById` /
                // `effectiveChildrenByCompound` upstream in
                // `BoardWizardTasksStepView`), so this subtitle reflects an
                // unsaved sub-task add/remove/rule change immediately.
                let children = effectiveChildrenByCompound[task.id] ?? []
                let n = children.count
                guard n > 0 else { return nil }
                var parts = ["\(n) sub-task\(n == 1 ? "" : "s")"]
                switch task.operatorType {
                case .or: parts.append("any of \(n)")
                case .mOfN: parts.append("≥\(task.threshold ?? n) of \(n)")
                case .and, .none: parts.append("all of \(n)")
                }
                return parts.joined(separator: " · ")
            case .achievement:
                return task.achievementTrigger == .bingo ? "First Bingo" : "GREENLOG"
            }
        }()

        // Board Sources P2 — provenance subtitles removed (docs/
        // BOARD_SOURCES.md §Removed: no "added by hand"/"from X" copy).
        if isCenter {
            return base.map { "Center square · \($0)" } ?? "Center square"
        }
        return base
    }

    private func risoKind(for type: TaskType) -> RisoTaskKind {
        switch type {
        case .normal: return .normal
        case .counting: return .counting
        case .compound: return .compound
        case .achievement: return .achievement
        }
    }
}
