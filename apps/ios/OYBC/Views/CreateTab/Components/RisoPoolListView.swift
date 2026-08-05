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
                        poolRow(task)
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
        let detail = typeDetailSubtitle(task)
        let isCenter = centerTaskMode && centerTaskId == task.id

        return HStack(alignment: .center, spacing: 9) {
            // Leading affordance: center star (in CHOSEN mode) or grip.
            if centerTaskMode {
                Button {
                    onSetCenter?(task.id)
                } label: {
                    Image(systemName: isCenter ? "star.fill" : "star")
                        .font(.system(size: 15, weight: .bold))
                        .foregroundStyle(isCenter ? Color.risoGold : Color.risoMuted)
                        .frame(width: 28, height: 28)
                }
                .buttonStyle(.plain)
                .contentShape(Rectangle())
                .accessibilityLabel(isCenter ? "Center task" : "Mark as center task")
                .accessibilityAddTraits(isCenter ? [.isSelected] : [])
            } else {
                Image(systemName: "line.3.horizontal")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.risoMuted)
            }

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

            // Type badge (pill style)
            RisoTypeBadge(kind: risoKind(for: task.type), style: .pill)

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
        }
        .padding(.horizontal, 11)
        .padding(.vertical, 9)
        .risoCard(fill: isCenter ? Color.risoGold.opacity(0.16) : .risoPaper2)
        .overlay(
            isCenter
                ? RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .strokeBorder(Color.risoGold, lineWidth: Riso.Keyline.container)
                : nil
        )
    }

    // MARK: - Helpers

    private func typeDetailSubtitle(_ task: OYBC.Task) -> String? {
        switch task.type {
        case .counting:
            guard let a = task.action, let m = task.maxCount, let u = task.unit,
                  !a.isEmpty, !u.isEmpty else { return nil }
            return "\(a) · goal \(m) \(u)"
        case .compound:
            let n = effectiveChildrenByCompound[task.id]?.count ?? 0
            if task.isOrdered == true {
                return n > 0 ? "\(n) step\(n == 1 ? "" : "s") · in order" : nil
            }
            guard n > 0 else { return nil }
            let op = task.operatorType
            switch op {
            case .or: return "Any of \(n)"
            case .mOfN:
                let t = task.threshold ?? n
                return "≥\(t) of \(n)"
            default: return "All of \(n)"
            }
        case .achievement:
            // `referencedBoardId`/`referencedTemplateId` are UUIDs, not names,
            // and the watched board/template isn't loaded here — so describe the
            // target kind + trigger rather than leaking a raw id into the row.
            let trigger = task.achievementTrigger == .bingo ? "First Bingo" : "GREENLOG"
            let target = task.referencedBoardId != nil ? "a board" : "a template"
            return "Watch \(target) · \(trigger)"
        default:
            return nil
        }
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
