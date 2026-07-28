import SwiftUI

// MARK: - Buttons

enum RisoButtonKind {
    case neutral   // paper2 / ink
    case primary   // red / paper
    case blue      // blue / paper
    case green     // green / paper — compound-type submit action
    case gold      // gold / inkStatic — primary CTA on a non-toolbar surface
                    // (e.g. the closing-out banner's Seal action). Uses
                    // risoInkStatic (never adaptive risoInk) so the label
                    // stays legible on gold in dark mode.

    var fill: Color {
        switch self {
        case .neutral: return .risoPaper2
        case .primary: return .risoRed
        case .blue: return .risoBlue
        case .green: return .risoGreen
        case .gold: return .risoGold
        }
    }
    var foreground: Color {
        switch self {
        case .neutral: return .risoInk
        case .gold: return .risoInkStatic
        default: return .risoPaper
        }
    }
}

/// Primary Riso button — Bricolage label, keyline, hard-shadow press.
///
/// Three sizes via mutually-exclusive flags: default (15pt), `large` (17pt,
/// for hero CTAs), `small` (13pt, for inline/dense rows — replaces the
/// hand-rolled mini-buttons that used to drift). `large` wins if both set.
struct RisoButton: View {
    let title: String
    var kind: RisoButtonKind = .neutral
    var systemImage: String? = nil
    var fullWidth: Bool = false
    var large: Bool = false
    var small: Bool = false
    let action: () -> Void

    private var fontSize: CGFloat { large ? 17 : (small ? 13 : 15) }
    private var vPad: CGFloat { large ? 16 : (small ? 8 : 13) }
    private var hPad: CGFloat { large ? 20 : (small ? 12 : 18) }

    var body: some View {
        Button(action: action) {
            HStack(spacing: 8) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
            .font(.risoHead(fontSize, .bold))
            .foregroundStyle(kind.foreground)
            .frame(maxWidth: fullWidth ? .infinity : nil)
            .padding(.vertical, vPad)
            .padding(.horizontal, hPad)
            .risoCard(fill: kind.fill)
        }
        .buttonStyle(RisoButtonStyle())
    }
}

/// Compact pill button for toolbar actions (Done / Save / Delete). Toolbars
/// clip `RisoButton`'s hard shadow, so this uses a capsule with the
/// `RisoButtonStyle` press-translate at a pill radius. This is the canonical
/// home for the gold/red toolbar pill that was previously hand-rolled
/// (with drifting fonts) in NewTaskSheetView, RisoLibrarySheetView,
/// EditTaskSheet, EditBoardSheet, TaskDeleteConfirmView, EditProfileSheet.
///
/// Default is the gold "Done"/"Save" affordance; pass `fill: .risoRed,
/// foreground: .risoPaper` for a destructive "Delete".
struct RisoToolbarPill: View {
    let title: String
    var fill: Color = .risoGold
    // Default sits on the gold fill — use the non-inverting ink so it stays
    // readable in dark mode (plain `risoInk` flips to cream). The red Delete
    // variant overrides this with `.risoPaper`.
    var foreground: Color = .risoInkStatic
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.risoHead(13, .extraBold))
                .foregroundStyle(foreground)
                .padding(.vertical, 6)
                .padding(.horizontal, 14)
                .background(Capsule().fill(fill))
                .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
        }
        .buttonStyle(RisoButtonStyle(offset: Riso.Shadow.small, radius: 999))
    }
}

/// 46×46 gold icon square (e.g. the + on Boards/Tasks).
struct RisoIconButton: View {
    let systemImage: String
    var fill: Color = .risoGold
    // Default sits on the gold fill — non-inverting ink keeps the glyph readable
    // in dark mode. Callers using a non-gold (adaptive) fill can override.
    var foreground: Color = .risoInkStatic
    var size: CGFloat = 46
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.system(size: size * 0.42, weight: .bold))
                .foregroundStyle(foreground)
                .frame(width: size, height: size)
                .risoCard(fill: fill)
        }
        .buttonStyle(RisoButtonStyle())
    }
}

// MARK: - Filter chip

/// Pill chip — selected = ink fill / paper text. No hard shadow (flat).
/// Optional `systemImage` renders before the label (e.g. a "Filters"
/// disclosure chip) — mirrors `RisoButton`'s `systemImage` slot so chips
/// with icons don't have to be hand-rolled.
struct RisoChip: View {
    let title: String
    var isOn: Bool = false
    var systemImage: String? = nil
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: 5) {
                if let systemImage { Image(systemName: systemImage) }
                Text(title)
            }
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

/// `RisoSegmented`'s two visual forms. Mirrors the web `RisoSegmented`
/// `variant` prop (`'card' | 'pill'`) verbatim.
///
/// - `.card` (default): bordered card buttons, colored active fill — the
///   prominent wizard/preferences picker. Existing call sites are
///   unaffected (this is the pre-existing, unchanged rendering).
/// - `.pill`: rounded compact toggle, ink active fill / paper text, muted
///   idle text — the Tasks-tab Library/Pools segment (P2 Task 3).
enum RisoSegmentedStyle {
    case card
    case pill
}

/// Generic segmented control — selected segment = filled / paper text.
///
/// - `equalWidth` (default true, `.card` style only): segments each take an
///   equal share of the width. Set false to size each segment to its label
///   — use this when labels vary in length and equal-width would clip the
///   long ones. Ignored by `.pill`, which always sizes to content (mirrors
///   the web `.pill` CSS: an `inline-flex` container hugging its content).
/// - `selectedFill` (`.card` style only): per-value fill for the selected
///   segment (default blue for all). Pass e.g. `{ $0.risoColor }` to
///   color-code by value. `.pill`'s active fill is always ink (never
///   per-value) per the web pill CSS.
/// - `style`: `.card` (default) or `.pill` — see `RisoSegmentedStyle`.
///
/// The default `equalWidth: true, style: .card` path is intentionally
/// visually identical to the original control — the full snapshot suite
/// confirms no diff for existing callers. Use `equalWidth: false` for
/// uneven `.card` labels that would otherwise clip.
struct RisoSegmented<T: Hashable>: View {
    let options: [(value: T, label: String)]
    @Binding var selection: T
    var equalWidth: Bool = true
    var selectedFill: (T) -> Color = { _ in .risoBlue }
    var style: RisoSegmentedStyle = .card

    var body: some View {
        switch style {
        case .card: cardBody
        case .pill: pillBody
        }
    }

    private var cardBody: some View {
        HStack(spacing: 6) {
            ForEach(options, id: \.value) { opt in
                Button { selection = opt.value } label: {
                    Text(opt.label)
                        .font(.risoHead(13, .bold))
                        // Only constrain in sizes-to-content mode; `nil` (the
                        // default) leaves the equal-width path unchanged.
                        .lineLimit(equalWidth ? nil : 1)
                        .foregroundStyle(selection == opt.value ? Color.risoPaper : Color.risoInk)
                        .frame(maxWidth: equalWidth ? .infinity : nil)
                        .padding(.vertical, 10)
                        .padding(.horizontal, equalWidth ? 0 : 14)
                        .background(
                            RoundedRectangle(cornerRadius: Riso.cardRadius)
                                .fill(selection == opt.value ? selectedFill(opt.value) : Color.risoPaper2)
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

    /// Rounded compact toggle: 2pt ink keyline capsule container (paper
    /// fill, 4pt internal padding), each segment a content-sized capsule
    /// button — ink fill / paper text when selected, transparent / muted
    /// text when idle. Mirrors web `RisoSegmented.module.css`'s `.pill`
    /// rule set exactly (font-head 11 bold, 7px/12px padding, 4pt gap).
    private var pillBody: some View {
        HStack(spacing: 4) {
            ForEach(options, id: \.value) { opt in
                let isOn = selection == opt.value
                Button { selection = opt.value } label: {
                    Text(opt.label)
                        .font(.risoHead(11, .bold))
                        .lineLimit(1)
                        .foregroundStyle(isOn ? Color.risoPaper : Color.risoMuted)
                        .padding(.vertical, 7)
                        .padding(.horizontal, 12)
                        .background(Capsule().fill(isOn ? Color.risoInk : Color.clear))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(4)
        .background(Capsule().fill(Color.risoPaper))
        .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container))
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

// MARK: - Text input fields

/// Riso-styled text field — Bricolage label, ink keyline, paper background.
/// Reusable across create/edit flows.
///
/// Matches the `risoTextInput` private helper in `RisoSpecialTaskPanel`
/// exactly — extracted here so `EditTaskSheet` and future surfaces can
/// share the same look without copying helper code.
///
/// - Parameters:
///   - axis: `.horizontal` (default, single-line) or `.vertical` (multiline).
///   - reservedLines: When non-nil the field reserves vertical space for that
///     many lines of text, preventing layout jitter as the user types. Only
///     meaningful when `axis == .vertical`.
struct RisoTextField: View {
    let placeholder: String
    @Binding var text: String
    var axis: Axis = .horizontal
    var reservedLines: Int? = nil

    var body: some View {
        if let lines = reservedLines {
            TextField(placeholder, text: $text, axis: axis)
                .lineLimit(lines, reservesSpace: true)
                .fieldStyle()
        } else {
            TextField(placeholder, text: $text, axis: axis)
                .fieldStyle()
        }
    }
}

/// Riso-styled number-pad text field. Same visual as `RisoTextField`
/// with `.numberPad` keyboard type.
///
/// Matches the `risoNumberInput` private helper in `RisoSpecialTaskPanel`.
struct RisoNumberField: View {
    let placeholder: String
    @Binding var text: String

    var body: some View {
        TextField(placeholder, text: $text)
            .keyboardType(.numberPad)
            .fieldStyle()
    }
}

/// Riso-styled secure (password) field. Same visual as `RisoTextField`
/// with `SecureField`'s obscured input. Used by the auth screen.
struct RisoSecureField: View {
    let placeholder: String
    @Binding var text: String
    var textContentType: UITextContentType? = nil

    var body: some View {
        SecureField(placeholder, text: $text)
            .textContentType(textContentType)
            // Passwords are case-sensitive — never auto-capitalize or correct.
            .textInputAutocapitalization(.never)
            .autocorrectionDisabled()
            .fieldStyle()
    }
}

// MARK: - Field style helper (internal)

private extension View {
    /// Shared padding/font/background/keyline used by `RisoTextField`
    /// and `RisoNumberField`.
    func fieldStyle() -> some View {
        self
            .font(.risoHead(14, .bold))
            .foregroundStyle(Color.risoInk)
            .tint(Color.risoBlue)
            .padding(.horizontal, 11)
            .padding(.vertical, 10)
            .background(Color.risoPaper)
            .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
            .overlay(
                RoundedRectangle(cornerRadius: Riso.cardRadius)
                    .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
            )
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
