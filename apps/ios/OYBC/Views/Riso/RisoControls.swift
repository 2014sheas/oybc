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
        // Static cream on red/blue/green — the on-colour contract (web
        // `--riso-on-color`); adaptive paper would flip dark in dark mode.
        default: return .risoOnColor
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
/// foreground: .risoOnColor` for a destructive "Delete".
struct RisoToolbarPill: View {
    let title: String
    var fill: Color = .risoGold
    // Default sits on the gold fill — use the non-inverting ink so it stays
    // readable in dark mode (plain `risoInk` flips to cream). The red Delete
    // variant overrides this with static `.risoOnColor`.
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

/// `RisoSegmented`'s two sizes. Mirrors the web `size` prop
/// (`'default' | 'compact'`) verbatim, and like it shapes the `.pill`
/// form only — `.card` ignores it.
///
/// - `.regular` (default): the shipped metrics, unchanged.
/// - `.compact`: a 22pt pill with a 1.5pt ink border and 10.5/700
///   segments split by an ink divider — the inline row control the
///   wizard member row's One square / Split up toggle uses (handoff
///   "Compound member").
enum RisoSegmentedSize {
    case regular
    case compact
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
    /// Selected-segment label colour for the `.card` style. Defaults to the
    /// static on-colour cream (matches the default blue fill); pass
    /// `.risoPaper` for an ink fill or `.risoInkStatic` for gold.
    var selectedForeground: (T) -> Color = { _ in .risoOnColor }
    var style: RisoSegmentedStyle = .card
    var size: RisoSegmentedSize = .regular

    var body: some View {
        switch style {
        case .card: cardBody
        case .pill:
            switch size {
            case .regular: pillBody
            case .compact: compactPillBody
            }
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
                        .foregroundStyle(selection == opt.value ? selectedForeground(opt.value) : Color.risoInk)
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

    /// `.pill` at `.compact`: a 22pt capsule with NO internal padding —
    /// the segments butt up against each other, split by a 1.5pt ink
    /// divider, and the selected one fills the full cell height with ink.
    /// Mirrors the web `.pill.compact` rule set (height 22, border 1.5,
    /// segment radius 0, 10.5/700, 9pt side padding).
    private var compactPillBody: some View {
        HStack(spacing: 0) {
            ForEach(Array(options.enumerated()), id: \.element.value) { index, opt in
                let isOn = selection == opt.value
                if index > 0 {
                    Rectangle()
                        .fill(Color.risoInk)
                        .frame(width: Riso.Keyline.dense)
                }
                Button { selection = opt.value } label: {
                    Text(opt.label)
                        .font(.risoHead(10.5, .bold))
                        .lineLimit(1)
                        .foregroundStyle(isOn ? Color.risoPaper : Color.risoMuted)
                        .padding(.horizontal, 9)
                        .frame(maxHeight: .infinity)
                        .background(isOn ? Color.risoInk : Color.clear)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .frame(height: 22)
        .background(Color.risoPaper)
        .clipShape(Capsule())
        .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
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
        // "#" (a number) reads as "counting" and frees "C" for compound —
        // avoids the old C/counting vs K/compound letter collision.
        case .counting: return "#"
        case .compound: return "C"
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
        default: return .risoOnColor
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

extension RisoTaskKind {
    /// Shared TaskType → kit-kind mapping (extract-at-three: previously
    /// duplicated privately in RisoLibrarySheetView / RisoPoolListView;
    /// the Board Sources source-row panel is the third caller).
    init(taskType: TaskType) {
        switch taskType {
        case .normal: self = .normal
        case .counting: self = .counting
        case .compound: self = .compound
        case .achievement: self = .achievement
        }
    }
}

// MARK: - Show-expired toggle

/// The one "Show expired tasks" switch, shared by every surface that hides
/// finished windows by default.
///
/// Extracted from the Tasks tab's secondary filter panel when the Counters
/// hub gained the same control (B3 RC9) — the label is a cross-platform copy
/// contract (web's `ShowExpiredToggle`), so it lives in exactly one place on
/// each platform rather than being retyped per screen.
struct RisoShowExpiredToggle: View {

    /// Whether expired tasks are currently shown.
    @Binding var isOn: Bool

    var body: some View {
        Toggle("Show expired tasks", isOn: $isOn)
            .font(.risoBody(13, .medium))
            .tint(Color.risoBlue)
    }
}

// MARK: - Impact note

/// A quiet one-line consequence note on a destructive-confirm sheet — the kind
/// of sentence that states what ELSE a delete takes with it.
///
/// Muted body copy rather than a card, deliberately: it is a consequence of
/// the action, not a list the person picks through. Extracted when the B3 RC12
/// derived-counter line landed on BOTH confirm sheets
/// (`CounterDeleteConfirmView`, `TaskDeleteConfirmView`) so a future restyle
/// has one place to land; the modifier stack is byte-identical to the one both
/// sheets inlined before.
struct RisoImpactNote: View {

    /// The sentence to render.
    let text: String

    var body: some View {
        Text(text)
            .font(.risoBody(12, .semibold))
            .foregroundStyle(Color.risoMuted)
            .fixedSize(horizontal: false, vertical: true)
            .frame(maxWidth: .infinity, alignment: .leading)
    }
}

// MARK: - Hit slop

extension View {
    /// Extends this view's touch target by `inset` on every side WITHOUT
    /// moving layout: the padding grows the rect the content shape is laid
    /// on, then the equal negative padding hands the size back. Use it on a
    /// small glyph button's label, choosing `inset` so glyph + 2 × inset is
    /// at least 28pt (the Riso small-control floor) — because it is
    /// symmetric it stays layout-neutral whatever the glyph size.
    /// (`RisoSubPageHeader`'s back button uses the same pattern for 44pt.)
    func risoHitSlop(_ inset: CGFloat) -> some View {
        padding(inset)
            .contentShape(Rectangle())
            .padding(-inset)
    }
}

// MARK: - Undo pill

/// The exclusion UNDO pill, which reverses an exclusion in place — a member row's
/// excluded state and a compound part line's excluded state.
///
/// Before the audit T2 sweep those two sites each hand-rolled a capsule, both
/// under the 28pt hit-area floor the neighbouring ✕ buttons use. The two
/// VISUAL scales are a design-handoff contract (the part line is "a size
/// down": 10.5pt / 1.5pt keyline / paper-2 fill vs the member row's 11.5pt /
/// 2pt bare outline — web pins the difference in `e2e/member-rules.spec.ts`),
/// so they survive as `Scale`; what is now shared is the builder and the
/// 28pt-tall touch target, which extends past the visual capsule. Web twin:
/// `MemberRuleRow.module.css` `.undo` / `.partUndo`.
struct RisoUndoPill: View {

    /// Visual scale — member row vs compound part line.
    enum Scale {
        case member
        case part
    }

    /// Which visual scale to draw.
    var scale: Scale = .member

    /// VoiceOver label, e.g. "Undo excluding Pushups" — the visible "UNDO"
    /// alone does not say what comes back.
    let accessibilityLabel: String

    /// Invoked on tap.
    let action: () -> Void

    /// Minimum touch-target height, matching the rows' 28pt ✕ buttons.
    static let hitHeight: CGFloat = 28

    var body: some View {
        Button(action: action) {
            capsule
                .frame(minHeight: Self.hitHeight)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var capsule: some View {
        switch scale {
        case .member:
            Text("UNDO")
                .font(.risoBody(11.5, .extraBold))
                .foregroundStyle(Color.risoInk)
                .padding(.horizontal, 10)
                .padding(.vertical, 4)
                .overlay(
                    Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
                )
        case .part:
            Text("UNDO")
                .font(.risoBody(10.5, .extraBold))
                .tracking(0.6)
                .foregroundStyle(Color.risoInk)
                .padding(.horizontal, 9)
                .padding(.vertical, 3)
                .background(Capsule().fill(Color.risoPaper2))
                .overlay(
                    Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense)
                )
        }
    }
}
