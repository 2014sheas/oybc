import SwiftUI

/// Riso-styled Tasks-tab list row.
///
/// Shows the type badge (letterSquare), title, subtitle line, and a
/// right column with "N bds" + green "N active". Mirrors the `TTRow`
/// component in `proto/tabs.jsx`.
///
/// This view is intentionally not a `Button` — the caller wraps it.
struct RisoTaskRowView: View {
    let task: Task
    let placementCount: Int
    let activePlacementCount: Int
    let childCount: Int

    var body: some View {
        HStack(spacing: 10) {
            // ── Type badge (letter square) ──────────────────────────────
            RisoTypeBadge(kind: risoKind, style: .letterSquare)

            // ── Title + subtitle ────────────────────────────────────────
            VStack(alignment: .leading, spacing: 2) {
                Text(task.title.isEmpty ? "(untitled task)" : task.title)
                    .font(.risoBody(15, .semibold))
                    .foregroundStyle(Color.risoInk)
                    .lineLimit(1)
                if let sub = subtitle {
                    Text(sub)
                        .font(.risoBody(12, .regular))
                        .foregroundStyle(Color.risoMuted)
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            // ── Right usage column ──────────────────────────────────────
            VStack(alignment: .trailing, spacing: 2) {
                HStack(spacing: 2) {
                    Text("\(placementCount)")
                        .font(.risoBody(13, .bold))
                        .foregroundStyle(Color.risoInk)
                    Text(placementCount == 1 ? " bd" : " bds")
                        .font(.risoBody(13, .regular))
                        .foregroundStyle(Color.risoMuted)
                }
                Text("\(activePlacementCount) active")
                    .font(.risoBody(11, .semibold))
                    .foregroundStyle(Color.risoGreen)
            }
        }
        .padding(.horizontal, 13)
        .padding(.vertical, 11)
        .frame(maxWidth: .infinity, alignment: .leading)
        .risoCard(keyline: Riso.Keyline.dense)
        .accessibilityLabel("Open \(task.title.isEmpty ? "untitled task" : task.title) details")
    }

    // MARK: - Derived

    private var risoKind: RisoTaskKind {
        switch task.type {
        case .normal: return .normal
        case .counting: return .counting
        case .compound: return .compound
        case .achievement: return .achievement
        }
    }

    /// One-line subtitle specific to each task type.
    private var subtitle: String? {
        switch task.type {
        case .counting:
            guard let action = task.action, let unit = task.unit, let max = task.maxCount else { return nil }
            return "\(action) · goal \(max) \(unit)"
        case .compound:
            let n = childCount
            if n == 0 { return "No subtasks yet" }
            let ruleLabel: String
            if let op = task.operatorType {
                switch op {
                case .or: ruleLabel = "any of \(n)"
                case .and: ruleLabel = task.isOrdered == true ? "in order" : "all of \(n)"
                case .mOfN:
                    let threshold = task.threshold ?? n
                    ruleLabel = "≥\(threshold) of \(n)"
                }
            } else {
                ruleLabel = "all of \(n)"
            }
            return "\(n) sub-task\(n == 1 ? "" : "s") · \(ruleLabel)"
        case .achievement:
            let trigger = task.achievementTrigger ?? .greenlog
            return trigger == .bingo ? "First Bingo" : "GREENLOG"
        case .normal:
            return nil
        }
    }
}
