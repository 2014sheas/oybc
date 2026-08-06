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
    /// Count of OTHER boards each task is placed on — drives the "On N other
    /// boards" detail line for simple tasks. Absent ⇒ not shared.
    var sharedCountByTaskId: [String: Int] = [:]

    /// The row currently open in the inline editor, if any. That row is
    /// replaced in place by `editor`.
    var editingTaskId: String? = nil
    /// Builds the inline editor view for the open row (owned by the parent, so
    /// it holds the draft/focus/toast state). nil ⇒ never swaps.
    var editor: ((OYBC.Task) -> AnyView)? = nil

    // MARK: - Ordered pool

    /// Pool in insertion order (from the parent's `poolOrder`). No sort — a
    /// renamed task must keep its position. Ids without a resolved task
    /// (mid-hydration races) are skipped.
    private var poolTasks: [OYBC.Task] {
        orderedTaskIds.compactMap { effectiveTaskById[$0] }
    }

    var body: some View {
        if selectedTaskIds.isEmpty {
            emptyPoolNote
        } else {
            VStack(alignment: .leading, spacing: 9) {
                // Section header
                HStack(spacing: 6) {
                    Text("On your board")
                        .risoSectionLabel()
                    // Count pill
                    Text("\(selectedTaskIds.count)")
                        .font(.risoHead(10, .extraBold))
                        .foregroundStyle(Color.risoPaper)
                        .padding(.horizontal, 7)
                        .padding(.vertical, 1)
                        .background(Capsule().fill(Color.risoInk))
                }

                VStack(spacing: 7) {
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
        Text("Nothing in your pool yet — reuse a task, type your own, or add a special type.")
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
        // Pencil is shown for editable in-pool tasks. PR 1 edits simple +
        // counting; compound editing arrives in PR 2. Achievement is never
        // editable in the pool (it shows the "TASKS TAB" marker instead).
        let showsPencil = onEdit != nil && (task.type == .normal || task.type == .counting)

        return HStack(alignment: .center, spacing: 9) {
            badge(task, isCenter: isCenter)

            // Name + detail
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title)
                    .font(.risoHead(14, .bold))
                    .foregroundStyle(Color.risoInk)
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.risoBody(10.5, .semibold))
                        .foregroundStyle(Color.risoMuted)
                        .lineLimit(1)
                }
            }
            Spacer(minLength: 4)

            // Edit affordance: pencil (editable) or the read-only "TASKS TAB"
            // marker (achievement). Compound in PR 1 shows neither.
            if showsPencil {
                pencilButton(task)
            } else if task.type == .achievement {
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
            .accessibilityLabel("Remove from board")
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

    /// Detail subtitle. `isCenter` prefixes "Center square · ".
    private func typeDetailSubtitle(_ task: OYBC.Task, isCenter: Bool) -> String? {
        let base: String? = {
            switch task.type {
            case .normal:
                let shared = sharedCountByTaskId[task.id] ?? 0
                return shared > 0 ? "On \(shared) other board\(shared == 1 ? "" : "s")" : nil
            case .counting:
                guard let a = task.action, let m = task.maxCount, let u = task.unit,
                      !a.isEmpty, !u.isEmpty else { return nil }
                return "\(a) · goal \(m) \(u)"
            case .compound:
                let children = effectiveChildrenByCompound[task.id] ?? []
                let n = children.count
                guard n > 0 else { return nil }
                // "with progress" = children that resolve to a counting task.
                let progress = children.filter {
                    effectiveTaskById[$0.childTaskId]?.type == .counting
                }.count
                var parts = ["\(n) step\(n == 1 ? "" : "s")"]
                if progress > 0 { parts.append("\(progress) with progress") }
                if task.isOrdered == true {
                    parts.append("in order")
                } else {
                    switch task.operatorType {
                    case .or: parts.append("any of \(n)")
                    case .mOfN: parts.append("≥\(task.threshold ?? n) of \(n)")
                    default: break // AND: no suffix
                    }
                }
                return parts.joined(separator: " · ")
            case .achievement:
                // referencedBoardId/referencedTemplateId are UUIDs, not names,
                // and the watched board/template isn't loaded here — describe the
                // target kind + trigger rather than leaking a raw id.
                let trigger = task.achievementTrigger == .bingo ? "First Bingo" : "GREENLOG"
                let target = task.referencedBoardId != nil ? "a board" : "a template"
                return "Watch \(target) · \(trigger)"
            }
        }()

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
