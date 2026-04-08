import SwiftUI

/// BoardStatusBadgeView — Small colored capsule pill showing board status.
///
/// Mirrors the web `BoardStatusBadge` component in `BoardStatusBadge.tsx`.
///
/// - DRAFT: gray background, primary text
/// - ACTIVE: accent blue background, white text
/// - COMPLETED: green background, white text
/// - ARCHIVED: secondary gray background, white text
///
/// - Parameter status: The board's current `BoardStatus`.
struct BoardStatusBadgeView: View {

    // MARK: - Parameters

    let status: BoardStatus

    // MARK: - Derived Properties

    private var label: String {
        status.rawValue.uppercased()
    }

    private var backgroundColor: Color {
        switch status {
        case .draft:     return Color(.systemGray5)
        case .active:    return .accentColor
        case .completed: return .green
        case .archived:  return Color(.systemGray3)
        }
    }

    private var foregroundColor: Color {
        switch status {
        case .draft:  return .primary
        default:      return .white
        }
    }

    // MARK: - Body

    var body: some View {
        Text(label)
            .font(.caption2)
            .fontWeight(.bold)
            .foregroundStyle(foregroundColor)
            .padding(.horizontal, 8)
            .padding(.vertical, 3)
            .background(backgroundColor)
            .clipShape(Capsule())
            .accessibilityLabel("\(status.rawValue) board status")
    }
}

#Preview {
    HStack(spacing: 8) {
        BoardStatusBadgeView(status: .draft)
        BoardStatusBadgeView(status: .active)
        BoardStatusBadgeView(status: .completed)
        BoardStatusBadgeView(status: .archived)
    }
    .padding()
}
