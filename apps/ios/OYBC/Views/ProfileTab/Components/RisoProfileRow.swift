import SwiftUI

/// A single row inside a Riso profile card.
///
/// Layout: `[icon-square] [label] [count pill?] [value?] [chevron?]`
///
/// - `icon`: An SF Symbol name rendered in a 26×26 keyline square.
/// - `label`: Row title (Bricolage 700, ink).
/// - `countBadge`: Optional integer — rendered as the "N" ink pill from
///   the prototype's `ts-lib-count` style.
/// - `value`: Optional trailing text (Archivo semibold, muted).
/// - `chevron`: When `true`, renders a `>` disclosure indicator.
/// - `danger`: When `true`, label + icon use red ink (Sign Out row).
struct RisoProfileRow: View {
    let icon: String
    let label: String
    var countBadge: Int? = nil
    var value: String? = nil
    var chevron: Bool = false
    var danger: Bool = false

    private var labelColor: Color { danger ? .risoRed : .risoInk }

    var body: some View {
        HStack(spacing: 12) {
            // Icon square — 26×26, 2px keyline
            iconSquare

            // Label
            Text(label)
                .font(.risoBody(14, .bold))
                .foregroundStyle(labelColor)
                .frame(maxWidth: .infinity, alignment: .leading)
                .lineLimit(1)

            // Count badge (ink pill, cream text)
            if let n = countBadge {
                Text("\(n)")
                    .font(.risoHead(10, .extraBold))
                    .foregroundStyle(Color.risoPaper)
                    .padding(.vertical, 1)
                    .padding(.horizontal, 7)
                    .background(Capsule().fill(Color.risoInk))
            }

            // Value text
            if let value {
                Text(value)
                    .risoSub()
                    .lineLimit(1)
            }

            // Chevron
            if chevron {
                Image(systemName: "chevron.right")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.risoMuted)
            }
        }
        .padding(.vertical, 12)
        .padding(.horizontal, Riso.cardPadding)
    }

    private var iconSquare: some View {
        Image(systemName: icon)
            .font(.system(size: 13, weight: .semibold))
            .foregroundStyle(danger ? Color.risoRed : Color.risoInk)
            .frame(width: 26, height: 26)
            .background(
                RoundedRectangle(cornerRadius: 6)
                    .fill(Color.risoPaper)
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6)
                    .strokeBorder(danger ? Color.risoRed : Color.risoInk, lineWidth: Riso.Keyline.dense)
            )
    }
}

#if DEBUG
#Preview {
    ZStack {
        RisoPaperBackground()
        VStack(spacing: 0) {
            RisoProfileRow(icon: "circle.lefthalf.filled", label: "Theme", value: "System")
            Divider().background(Color.risoInk.opacity(0.12)).padding(.horizontal, Riso.cardPadding)
            RisoProfileRow(icon: "arrow.triangle.2.circlepath", label: "Sync", value: "Synced · just now")
        }
        .risoCard()
        .padding(20)
    }
}
#endif
