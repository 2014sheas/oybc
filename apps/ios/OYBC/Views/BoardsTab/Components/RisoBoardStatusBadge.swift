import SwiftUI

/// Status pill badge displayed in the top-right of a `RisoBoardCard`.
///
/// Colors match the prototype's `.r-badge` variants:
/// - Active → blue fill / paper text
/// - Completed → green fill / paper text
/// - Draft → paper fill / muted text
/// - Expiring → gold fill / ink text
/// - Archived → paper fill / muted text (treated like draft visually)
struct RisoBoardStatusBadge: View {

    enum Kind {
        case active
        case completed
        case draft
        case expiring
        case archived

        var label: String {
            switch self {
            case .active:    return "Active"
            case .completed: return "Completed"
            case .draft:     return "Draft"
            case .expiring:  return "Expiring"
            case .archived:  return "Archived"
            }
        }
        var fill: Color {
            switch self {
            case .active:    return .risoBlue
            case .completed: return .risoGreen
            case .draft:     return .risoPaper
            case .expiring:  return .risoGold
            case .archived:  return .risoPaper
            }
        }
        var foreground: Color {
            switch self {
            case .active:    return .risoPaper
            case .completed: return .risoPaper
            case .draft:     return .risoMuted
            case .expiring:  return .risoInk
            case .archived:  return .risoMuted
            }
        }
    }

    let kind: Kind

    var body: some View {
        Text(kind.label.uppercased())
            .font(.risoHead(10, .bold))
            .tracking(0.6)
            .foregroundStyle(kind.foreground)
            .padding(.vertical, 4)
            .padding(.horizontal, 9)
            .background(Capsule().fill(kind.fill))
            .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
    }
}

extension RisoBoardStatusBadge.Kind {
    /// Derive badge kind from board status + expiry flag.
    init(status: BoardStatus, isExpiring: Bool) {
        switch status {
        case .active:
            self = isExpiring ? .expiring : .active
        case .completed:
            self = .completed
        case .draft:
            self = .draft
        case .archived:
            self = .archived
        }
    }
}

#if DEBUG
#Preview("Status Badges") {
    VStack(spacing: 10) {
        RisoBoardStatusBadge(kind: .active)
        RisoBoardStatusBadge(kind: .completed)
        RisoBoardStatusBadge(kind: .draft)
        RisoBoardStatusBadge(kind: .expiring)
        RisoBoardStatusBadge(kind: .archived)
    }
    .padding()
}
#endif
