import SwiftUI

/// Clickable task list item with title, type badge, and selected state.
///
/// Used in the subtask derivation playground as the selectable parent task
/// list. Shows a title and `TypeBadgeView`, with highlighted border and
/// background when selected. Mirrors the web `SelectableTaskItem` component
/// in `SelectableTaskItem.tsx`.
///
/// - Parameters:
///   - title: Display title of the task.
///   - type: Task type string passed to `TypeBadgeView`.
///   - isSelected: Whether this item is currently selected.
///   - onSelect: Called when the item is tapped.
struct SelectableTaskItemView: View {

    // MARK: - Parameters

    let title: String
    let type: String
    let isSelected: Bool
    let onSelect: () -> Void

    // MARK: - Body

    var body: some View {
        Button(action: onSelect) {
            HStack(spacing: 8) {
                Text(title)
                    .font(.system(size: 14, weight: .medium))
                    .foregroundColor(isSelected ? .blue : .primary)
                    .lineLimit(2)
                    .frame(maxWidth: .infinity, alignment: .leading)

                TypeBadgeView(type: type, size: .small)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            .background(
                RoundedRectangle(cornerRadius: 8)
                    .fill(isSelected ? Color.blue.opacity(0.08) : Color(.systemGray6))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 8)
                    .stroke(isSelected ? Color.blue : Color.clear, lineWidth: 1.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityAddTraits(isSelected ? [.isSelected] : [])
        .accessibilityLabel("\(title), \(type) task\(isSelected ? ", selected" : "")")
    }
}

#Preview {
    VStack(spacing: 8) {
        SelectableTaskItemView(title: "Read 50 pages", type: "counting", isSelected: true, onSelect: {})
        SelectableTaskItemView(title: "Morning run", type: "normal", isSelected: false, onSelect: {})
        SelectableTaskItemView(title: "Weekly workout routine", type: "progress", isSelected: false, onSelect: {})
        SelectableTaskItemView(title: "All fitness goals combined", type: "composite", isSelected: false, onSelect: {})
    }
    .padding()
}
