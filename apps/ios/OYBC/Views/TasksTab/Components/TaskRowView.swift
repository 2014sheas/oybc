import SwiftUI

/// Tasks-tab list row. Title + type badge + a one-line status/usage
/// hint. Mirrors web's `TaskRow.tsx`; kept deliberately simpler than
/// `BoardWizardTasksStepView`'s row (no selection, no center-pinning).
struct TaskRowView: View {
    let task: Task
    /// Pre-computed count of `BoardTask` placements (any board status).
    let placementCount: Int
    /// Pre-computed count of placements on ACTIVE boards specifically.
    let activePlacementCount: Int
    /// Pre-computed count of compound children. Ignored for non-compound
    /// types.
    let childCount: Int
    let onTap: () -> Void

    var body: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                TypeBadgeView(type: typeLabel, size: .small, letterOnly: true)
                VStack(alignment: .leading, spacing: 2) {
                    Text(task.title.isEmpty ? "(untitled task)" : task.title)
                        .font(.system(size: 16, weight: .semibold))
                        .foregroundColor(.primary)
                        .lineLimit(1)
                    if let meta = metaLine {
                        Text(meta)
                            .font(.system(size: 13))
                            .foregroundColor(.secondary)
                            .lineLimit(1)
                    }
                }
                Spacer(minLength: 0)
                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundColor(.secondary)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemBackground))
            .clipShape(RoundedRectangle(cornerRadius: 10, style: .continuous))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .stroke(Color(.separator), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel("Open \(task.title.isEmpty ? "untitled task" : task.title) details")
    }

    // MARK: - Derived display

    /// Compound tasks map to "progress" or "composite" so the badge
    /// colour matches the Tasks-tab filter chip the user followed to
    /// find this row. Other types pass through unchanged.
    private var typeLabel: String {
        if task.type == .compound {
            return task.isOrdered == true ? "progress" : "composite"
        }
        return task.type.rawValue
    }

    private var metaLine: String? {
        let parts: [String] = [subtitle, statusLabel, lastCompletedHint, usageHint].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }

    /// "Last completed Xd ago" — only shown when `completedAt` is set.
    private var lastCompletedHint: String? {
        guard let rel = RelativeTime.formatRelativeTime(task.completedAt) else { return nil }
        return "Last completed \(rel)"
    }

    private var subtitle: String? {
        switch task.type {
        case .counting:
            if let action = task.action, let unit = task.unit, let max = task.maxCount {
                // Mirrors shared/algorithms/taskTitle.ts `generateCounterTaskTitle`
                // — kept inline because iOS doesn't expose a top-level helper.
                return "\(action.trimmingCharacters(in: .whitespacesAndNewlines)) \(max) \(unit.trimmingCharacters(in: .whitespacesAndNewlines))"
            }
            return nil
        case .compound:
            if childCount > 0 {
                return "\(childCount) subtask\(childCount == 1 ? "" : "s")"
            }
            return "No subtasks yet"
        case .achievement:
            let trigger = task.achievementTrigger ?? .greenlog
            return trigger == .bingo ? "On bingo" : "On greenlog"
        case .normal:
            return nil
        }
    }

    private var statusLabel: String? {
        if task.isCompleted { return "Completed" }
        if task.type == .counting {
            let current = task.currentCount ?? 0
            let max = task.maxCount ?? 0
            if current > 0 && max > 0 {
                return "\(current) / \(max)"
            }
        }
        return nil
    }

    private var usageHint: String? {
        if placementCount == 0 { return "Unused" }
        if activePlacementCount > 0 {
            return "On \(activePlacementCount) active board\(activePlacementCount == 1 ? "" : "s")"
        }
        return "Placed on \(placementCount) board\(placementCount == 1 ? "" : "s")"
    }
}
