import SwiftUI

/// Compact chip showing a confirmed subtask selection.
///
/// Displays a `TypeBadgeView`, the subtask title, and edit/remove action
/// buttons in a single horizontal row. Used in the composite task form to
/// show subtasks that have been confirmed by the user. Mirrors the web
/// `SubtaskChip` component in `SubtaskChip.tsx`.
///
/// - Parameters:
///   - title: Display title of the subtask.
///   - type: Task type string passed to `TypeBadgeView`.
///   - onView: Optional. When provided, tapping the chip body fires this
///     callback (e.g., open the task's detail sheet). Edit/remove buttons
///     remain independent.
///   - onEdit: Called when the edit (pencil) button is tapped.
///   - onRemove: Called when the remove (✕) button is tapped.
struct SubtaskChipView: View {

    // MARK: - Parameters

    let title: String
    let type: String
    var onView: (() -> Void)? = nil
    let onEdit: () -> Void
    let onRemove: () -> Void

    // MARK: - Body

    var body: some View {
        HStack(spacing: 8) {
            // Tappable body: fires onView when provided.
            Group {
                if let onView {
                    Button(action: onView) {
                        chipBody
                    }
                    .buttonStyle(.plain)
                    .accessibilityLabel("View \(title) details")
                } else {
                    chipBody
                }
            }

            // Edit button
            Button(action: onEdit) {
                Image(systemName: "pencil")
                    .font(.system(size: 12, weight: .medium))
                    .foregroundColor(.blue)
                    .frame(width: 28, height: 28)
                    .background(Color(.systemGray6))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Edit \(title)")

            // Remove button
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.red)
                    .frame(width: 28, height: 28)
                    .background(Color(.systemGray6))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(title)")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }

    // MARK: - Chip body (shared between tappable and non-tappable forms)

    private var chipBody: some View {
        HStack(spacing: 8) {
            TypeBadgeView(type: type, size: .small)

            Text(title)
                .font(.system(size: 13))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#Preview {
    VStack(spacing: 8) {
        SubtaskChipView(title: "Read 50 pages", type: "counting", onEdit: {}, onRemove: {})
        SubtaskChipView(title: "Morning run", type: "normal", onView: {}, onEdit: {}, onRemove: {})
        SubtaskChipView(title: "Weekly workout routine", type: "progress", onEdit: {}, onRemove: {})
        SubtaskChipView(title: "All fitness goals combined", type: "composite", onEdit: {}, onRemove: {})
    }
    .padding()
}
