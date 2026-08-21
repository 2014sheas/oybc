import SwiftUI

/// RisoProfileSubPageKit — shared Riso building blocks used across Profile
/// sub-pages (and, in a few cases, well beyond Profile). Extracted from
/// `RecurringTemplatesView.swift` / `DefaultPoolsListView.swift` (Task
/// Pools + Recurring Boards Rework, P7) when both of those page structs
/// retired in favor of `BoardSettingsView` — these five pieces are load-
/// bearing for OTHER surfaces (see each type's doc below) and had to
/// survive the page deletion verbatim.

/// Back square button + "PROFILE" kicker + H2 title used by all Profile sub-pages.
struct RisoSubPageHeader: View {
    let title: String
    /// Kicker label above the title (Bricolage 700, uppercase via
    /// `.risoKicker()`). Defaults to "Profile" / red — every pre-existing
    /// sub-page keeps this unchanged. Counter Detail (R2 Counters UX
    /// refresh) overrides both to "Shared counter" / blue, rendered as the
    /// "SHARED COUNTER" kicker per the design handoff.
    var kicker: String = "Profile"
    var kickerColor: Color = .risoRed
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        HStack(spacing: 12) {
            Button { dismiss() } label: {
                Image(systemName: "chevron.left")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(Color.risoInk)
                    .frame(width: 40, height: 40)
                    .risoCard(fill: .risoPaper2)
            }
            .buttonStyle(RisoButtonStyle(offset: Riso.Shadow.small))
            VStack(alignment: .leading, spacing: 2) {
                Text(kicker).risoKicker(kickerColor)
                Text(title).risoH2()
            }
            Spacer()
        }
        .padding(.horizontal, Riso.gutter)
    }
}

/// Dashed "+ New ___" button matching the prototype's pp-dashedbtn style.
struct RisoDashedButton: View {
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(label)
                .font(.risoHead(14, .bold)).foregroundStyle(Color.risoInk)
                .frame(maxWidth: .infinity).padding(.vertical, 14)
                .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(Color.risoPaper2))
                .overlay(RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .strokeBorder(Color.risoInk.opacity(0.5),
                                  style: StrokeStyle(lineWidth: 1.5, dash: [6, 4])))
        }.buttonStyle(.plain)
    }
}

/// Keyline pill toggle styled to Riso green accent.
struct RisoPillSwitch: View {
    @Binding var isOn: Bool
    var body: some View {
        Toggle("", isOn: $isOn).labelsHidden().tint(Color.risoGreen)
    }
}

// MARK: - Timeframe helpers

extension Timeframe {
    /// Short label used in UI tags and segmented controls.
    var risoDisplayName: String {
        switch self {
        case .daily: return "Daily"
        case .weekly: return "Weekly"
        case .monthly: return "Monthly"
        case .yearly: return "Yearly"
        case .custom: return "Custom"
        case .indefinite: return "Ongoing"
        }
    }

    /// Riso color for timeframe tags: Daily=gold, Weekly=blue, Monthly=green, Yearly=red.
    var risoColor: Color {
        switch self {
        case .daily: return .risoGold
        case .weekly: return .risoBlue
        case .monthly: return .risoGreen
        case .yearly: return .risoRed
        case .custom: return .risoMuted
        case .indefinite: return .risoMuted
        }
    }
}

// MARK: - FlowLayout

/// Simple left-to-right wrapping layout for tag/chip rows.
/// Wrapping row layout — places subviews left-to-right, wrapping to a new
/// row when the current one would overflow the proposed width. Shared by
/// any card-style chip row (pool/task chips throughout the Pools +
/// Recurring Boards surfaces; `RecurringTemplateCard`'s pool-preview chips
/// — issue #321).
struct FlowLayout: Layout {
    var spacing: CGFloat = 6

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        let width = proposal.width ?? 0
        var height: CGFloat = 0; var x: CGFloat = 0; var rowH: CGFloat = 0
        for sub in subviews {
            let sz = sub.sizeThatFits(.unspecified)
            if x + sz.width > width && x > 0 { height += rowH + spacing; x = 0; rowH = 0 }
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
        return CGSize(width: width, height: height + rowH)
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        var x: CGFloat = bounds.minX; var y: CGFloat = bounds.minY; var rowH: CGFloat = 0
        for sub in subviews {
            let sz = sub.sizeThatFits(.unspecified)
            if x + sz.width > bounds.maxX && x > bounds.minX {
                y += rowH + spacing; x = bounds.minX; rowH = 0
            }
            sub.place(at: CGPoint(x: x, y: y), proposal: ProposedViewSize(sz))
            x += sz.width + spacing; rowH = max(rowH, sz.height)
        }
    }
}
