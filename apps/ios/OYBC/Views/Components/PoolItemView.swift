import SwiftUI

/// Pool entry row with title, type badge, and a remove button.
///
/// Shows a title, a small `TypeBadgeView`, and a × remove button in a
/// compact horizontal row. Used in the subtask derivation playground's
/// Board Task Pool staging area. Mirrors the web `PoolItem` component in
/// `PoolItem.tsx`.
///
/// - Parameters:
///   - title: Display title of the task.
///   - type: Task type string passed to `TypeBadgeView`.
///   - onRemove: Called when the × button is tapped.
struct PoolItemView: View {

    // MARK: - Parameters

    let title: String
    let type: String
    let onRemove: () -> Void

    // MARK: - Body

    var body: some View {
        HStack(spacing: 8) {
            Text(title)
                .font(.system(size: 13))
                .lineLimit(1)
                .frame(maxWidth: .infinity, alignment: .leading)

            TypeBadgeView(type: type, size: .small)

            // Remove button
            Button(action: onRemove) {
                Image(systemName: "xmark")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundColor(.secondary)
                    .frame(width: 24, height: 24)
                    .background(Color(.systemGray5))
                    .clipShape(Circle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Remove \(title) from pool")
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .background(Color(.systemGray6))
        .cornerRadius(8)
    }
}

#Preview {
    VStack(spacing: 8) {
        PoolItemView(title: "Read 50 pages", type: "counting", onRemove: {})
        PoolItemView(title: "Morning run", type: "normal", onRemove: {})
        PoolItemView(title: "Weekly workout routine", type: "progress", onRemove: {})
        PoolItemView(title: "All fitness goals combined", type: "composite", onRemove: {})
    }
    .padding()
}
