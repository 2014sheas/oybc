import SwiftUI

/// A contributor's progress pill — "Done" / "In progress" / "Not started"
/// (the Counter Detail "Counts toward" rows). Same chrome as `RisoTypeBadge`
/// `.pill`; the done fill draws adaptive `risoPaper` text (the C8 on-colour
/// rule), in-progress draws static ink on gold, not-started is quiet paper.
struct RisoStatusPill: View {
    enum Status: Equatable {
        case done, inProgress, notStarted

        /// The pill's text as shown (rendered uppercased).
        var label: String {
            switch self {
            case .done: return "Done"
            case .inProgress: return "In progress"
            case .notStarted: return "Not started"
            }
        }
    }

    let status: Status

    private var fill: Color {
        switch status {
        case .done: return .risoGreen
        case .inProgress: return .risoGold
        case .notStarted: return .risoPaper2
        }
    }

    private var foreground: Color {
        switch status {
        case .done: return .risoPaper
        case .inProgress: return .risoInkStatic
        case .notStarted: return .risoMuted
        }
    }

    var body: some View {
        Text(status.label.uppercased())
            .font(.risoHead(9, .bold))
            .tracking(0.45)
            .foregroundStyle(foreground)
            .padding(.vertical, 3)
            .padding(.horizontal, 8)
            .background(Capsule().fill(fill))
            .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
            .lineLimit(1)
            .fixedSize()
    }
}

extension RisoStatusPill.Status {
    /// The pill state for a section row's status.
    init(_ status: CountsToward.ContributorRowStatus) {
        switch status {
        case .done: self = .done
        case .inProgress: self = .inProgress
        case .notStarted: self = .notStarted
        }
    }
}
