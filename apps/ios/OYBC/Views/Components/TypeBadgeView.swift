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
    /// When true, renders a fixed-width 4-letter abbreviation instead
    /// of the full type name. Used by list layouts (e.g. the composite-
    /// task picker) so rows stack without the badge width varying per
    /// type.
    var letterOnly: Bool = false

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

    /// Label text — either the 4-letter abbreviation (first 4 letters
    /// of the type name, uppercased) or the full uppercase type name.
    private var label: String {
        if letterOnly {
            switch type.lowercased() {
            case "normal":    return "NORM"
            case "counting":  return "COUN"
            case "progress":  return "PROG"
            case "composite": return "COMP"
            default:
                return String(type.prefix(4)).uppercased()
            }
        }
        return type.uppercased()
    }

    /// Fixed width when rendering the 4-letter variant. Sized to fit
    /// any of the four abbreviations and kept uniform across types so
    /// stacked rows align perfectly.
    private var letterWidth: CGFloat {
        size == .small ? 42 : 46
    }

    // MARK: - Body

    var body: some View {
        if letterOnly {
            Text(label)
                .font(size == .small
                      ? .system(size: 9, weight: .semibold)
                      : .system(size: 10, weight: .semibold))
                .foregroundColor(.white)
                .frame(width: letterWidth)
                .padding(.vertical, size == .small ? 2 : 3)
                .background(badgeColor)
                .clipShape(Capsule())
                .accessibilityLabel("\(type) task type")
        } else {
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
