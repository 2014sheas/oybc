import SwiftUI

/// Size variants for TypeBadgeView.
enum TypeBadgeSize {
    case `default`
    case small
}

/// Colored badge showing a task type label.
///
/// Used across task library cards, derivation panels, pool items, and
/// compound subtask lists to display a consistent type indicator.
/// Mirrors the web `TypeBadge` component in `TypeBadge.tsx`.
///
/// - Parameters:
///   - type: Task type string (e.g. "normal", "counting", "compound").
///     The legacy "progress" and "composite" strings are mapped to
///     "compound" color + label so old data renders correctly.
///   - size: Optional size variant. `.small` renders a compact badge.
struct TypeBadgeView: View {

    // MARK: - Parameters

    let type: String
    var size: TypeBadgeSize = .default
    /// When true, renders a fixed-width 4-letter abbreviation instead
    /// of the full type name. Used by list layouts (e.g. the compound-
    /// task picker) so rows stack without the badge width varying per
    /// type.
    var letterOnly: Bool = false

    // MARK: - Derived Properties

    /// Normalise legacy type strings to the current vocabulary so
    /// existing data (which may carry "progress"/"composite" as
    /// rawValues from before the unification) renders with the
    /// correct Compound badge color.
    private var normalisedType: String {
        switch type.lowercased() {
        case "progress", "composite": return "compound"
        default: return type.lowercased()
        }
    }

    /// Background/foreground color based on the task type.
    private var badgeColor: Color {
        switch normalisedType {
        case "normal":   return .blue
        case "counting": return .orange
        case "compound": return .indigo
        default:         return .gray
        }
    }

    /// Label text — either the 4-letter abbreviation or the full
    /// uppercase type name.
    private var label: String {
        if letterOnly {
            switch normalisedType {
            case "normal":   return "NORM"
            case "counting": return "COUN"
            case "compound": return "CMPD"
            default:
                return String(normalisedType.prefix(4)).uppercased()
            }
        }
        return normalisedType.uppercased()
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
        TypeBadgeView(type: "compound")
        TypeBadgeView(type: "achievement")
    }
    .padding()
}

#Preview("All types — small size") {
    HStack(spacing: 6) {
        TypeBadgeView(type: "normal", size: .small)
        TypeBadgeView(type: "counting", size: .small)
        TypeBadgeView(type: "compound", size: .small)
        TypeBadgeView(type: "achievement", size: .small)
    }
    .padding()
}
