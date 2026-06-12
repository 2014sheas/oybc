import SwiftUI

// MARK: - Buttons

enum RisoButtonKind {
    case neutral   // paper2 / ink
    case primary   // red / paper
    case blue      // blue / paper

    var fill: Color {
        switch self {
        case .neutral: return .risoPaper2
        case .primary: return .risoRed
        case .blue: return .risoBlue
        }
    }
    var foreground: Color {
        switch self {
        case .neutral: return .risoInk
        default: return .risoPaper
        }
    }
}

/// Primary Riso button — Bricolage label, keyline, hard-shadow press.
struct RisoButton: View {
    let title: String
    var kind: RisoButtonKind = .neutral
    var systemImage: String? = nil
    var fullWidth: Bool = false
    var large: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.risoHead(large ? 17 : 15, .bold))
            .foregroundStyle(kind.foreground)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.vertical, large ? 16 : 13)
            .padding(.horizontal, large ? 20 : 18)
            .risoCard(fill: kind.fill)
        }
        .buttonStyle(RisoButtonStyle())
    }
}

/// 46×46 gold icon square (e.g. the + on Boards/Tasks).
struct RisoIconButton: View {
    let systemImage: String
    var fill: Color = .risoGold
    var size: CGFloat = 46
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(Color.risoInk)
                .frame(width: size, height: size)
                .risoCard(fill: fill)
        }
        .buttonStyle(RisoButtonStyle())
    }
}

// MARK: - Filter chip

/// Pill chip — selected = ink fill / paper text. No hard shadow (flat).
struct RisoChip: View {
    let title: String
    var isOn: Bool = false
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.risoHead(12, .bold))
                .foregroundStyle(isOn ? Color.risoPaper : Color.risoInk)
                .padding(.vertical, 7)
                .padding(.horizontal, 13)
                .background(Capsule().fill(isOn ? Color.risoInk : Color.risoPaper2))
                .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Segmented control

/// Generic segmented control — selected segment = blue fill / paper text.
struct RisoSegmented<T: Hashable>: View {
    let options: [(value: T, label: String)]
    @Binding var selection: T

    var body: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.value) { opt in
                Button { selection = opt.value } label: {
                    Text(opt.label)
                        .font(.risoHead(13, .bold))
                        .foregroundStyle(selection == opt.value ? Color.risoPaper : Color.risoInk)
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 10)
                        .background(
                            RoundedRectangle(cornerRadius: Riso.cardRadius)
                                .fill(selection == opt.value ? Color.risoBlue : Color.risoPaper2)
                        )
                        .overlay(
                            RoundedRectangle(cornerRadius: Riso.cardRadius)
                                .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
                        )
                }
                .buttonStyle(.plain)
            }
        }
    }
}

// MARK: - Progress bar

/// Keyline progress bar — paper track, colored fill (red by default; green
/// when complete). `value` is 0…1.
struct RisoProgressBar: View {
    var value: Double
    var color: Color = .risoRed
    var height: CGFloat = 12

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                Capsule().fill(Color.risoPaper)
                Rectangle()
                    .fill(color)
                    .frame(width: max(0, min(1, value)) * geo.size.width)
            }
            .clipShape(Capsule())
            .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
        }
        .frame(height: height)
    }
}

// MARK: - Type badge

enum RisoTaskKind {
    case normal, counting, compound, achievement

    var letter: String {
        switch self {
        case .normal: return "N"
        case .counting: return "C"
        case .compound: return "K"
        case .achievement: return "A"
        }
    }
    var label: String {
        switch self {
        case .normal: return "Normal"
        case .counting: return "Counting"
        case .compound: return "Compound"
        case .achievement: return "Achievement"
        }
    }
    /// Fill for filled variants (pill / letter square). Normal is the
    /// exception — it reads as quiet paper with muted text.
    var fill: Color {
        switch self {
        case .normal: return .risoPaper
        case .counting: return .risoBlue
        case .compound: return .risoGreen
        case .achievement: return .risoAchievement
        }
    }
    var foreground: Color {
        switch self {
        case .normal: return .risoMuted
        default: return .risoPaper
        }
    }
}

enum RisoBadgeStyle { case pill, letterSquare }

/// Task-type indicator — either an uppercase pill tag or a letter square
/// (N/C/K/A), matching the prototype's `ttype` / `lb-badge` styles.
struct RisoTypeBadge: View {
    let kind: RisoTaskKind
    var style: RisoBadgeStyle = .pill

    var body: some View {
        switch style {
        case .pill:
            Text(kind.label.uppercased())
                .font(.risoHead(9, .bold))
                .tracking(0.45)
                .foregroundStyle(kind.foreground)
                .padding(.vertical, 3)
                .padding(.horizontal, 8)
                .background(Capsule().fill(kind.fill))
                .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
        case .letterSquare:
            Text(kind.letter)
                .font(.risoHead(10, .extraBold))
                .foregroundStyle(kind.foreground)
                .frame(width: 20, height: 20)
                .background(RoundedRectangle(cornerRadius: Riso.cellRadius).fill(kind.fill))
                .overlay(RoundedRectangle(cornerRadius: Riso.cellRadius).strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
        }
    }
}
