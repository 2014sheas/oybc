import SwiftUI

/// Size variants for TypeBadgeView.
enum TypeBadgeSize {
    case `default`
    case small
}

/// Colored badge showing a task type label.
///
/// Used across task library cards, derivation panels, pool items, and
/// composite subtask lists to display a consistent type indicator.
/// Mirrors the web `TypeBadge` component in `TypeBadge.tsx`.
///
/// - Parameters:
///   - type: Task type string (e.g. "normal", "counting", "progress", "composite").
///   - size: Optional size variant. `.small` renders a compact badge.
struct TypeBadgeView: View {

    // MARK: - Parameters

    let type: String
    var size: TypeBadgeSize = .default

    // MARK: - Derived Properties

    /// Background/foreground color based on the task type.
    private var badgeColor: Color {
        switch type.lowercased() {
        case "normal":    return .blue
        case "counting":  return .orange
        case "progress":  return .green
        case "composite": return .indigo
        default:          return .gray
        }
    }

    /// Label text — the type string in all caps.
    private var label: String {
        type.uppercased()
    }

    // MARK: - Body

    var body: some View {
        Text(label)
            .font(size == .small
                  ? .system(size: 9, weight: .semibold)
                  : .system(size: 11, weight: .semibold))
            .foregroundColor(.white)
            .padding(.horizontal, size == .small ? 5 : 7)
            .padding(.vertical, size == .small ? 2 : 3)
            .background(badgeColor)
            .clipShape(Capsule())
            .accessibilityLabel("\(type) task type")
    }
}

#Preview("All types — default size") {
    HStack(spacing: 8) {
        TypeBadgeView(type: "normal")
        TypeBadgeView(type: "counting")
        TypeBadgeView(type: "progress")
        TypeBadgeView(type: "composite")
    }
    .padding()
}

#Preview("All types — small size") {
    HStack(spacing: 6) {
        TypeBadgeView(type: "normal", size: .small)
        TypeBadgeView(type: "counting", size: .small)
        TypeBadgeView(type: "progress", size: .small)
        TypeBadgeView(type: "composite", size: .small)
    }
    .padding()
}
