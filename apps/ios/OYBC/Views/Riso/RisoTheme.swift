import SwiftUI

/// Riso design-system tokens — the SwiftUI counterpart of `proto/riso.css`.
///
/// Colors live in `Resources/Assets.xcassets` with light ("day press") and
/// dark ("night press") appearances, so they flip automatically with the
/// existing `ThemePreference` → `.preferredColorScheme` wiring in
/// `MainTabView`. Fonts are the static weights bundled under
/// `Resources/Fonts` (instanced from the OFL variable fonts) and registered
/// via `UIAppFonts` in `project.yml`.
///
/// Numeric tokens (radii, keyline widths, hard-shadow offsets, spacing)
/// mirror the CSS `:root` vars. Reach for the semantic helpers
/// (`.risoCard()`, `RisoButton`, `Color.risoInk`, `Font.risoHead`) rather
/// than re-deriving these values per screen.
enum Riso {
    // Corner radii
    static let cardRadius: CGFloat = 7   // --r-card: cards, inputs, buttons
    static let cellRadius: CGFloat = 6   // --r-cell: board cells
    static let pill: CGFloat = 999       // chips / pills

    // Keyline widths
    enum Keyline {
        static let container: CGFloat = 2   // interactive containers
        static let dense: CGFloat = 1.5     // dense rows / chips / cells
    }

    // Hard-shadow offsets (no blur, ink color). Press = translate by the
    // offset and collapse the shadow to 0 — see `RisoButtonStyle`.
    enum Shadow {
        static let card: CGFloat = 4
        static let button: CGFloat = 3
        static let small: CGFloat = 2
    }

    // Spacing
    static let gutter: CGFloat = 20
    static let cardPadding: CGFloat = 14
    static let cellGap: CGFloat = 7

    /// Press animation duration (the "press into the paper" effect).
    static let pressDuration: Double = 0.10
}

// MARK: - Bundle

/// Marker used to resolve the OYBC app bundle from any execution context
/// (the app itself or an app-hosted test target), so named colors and
/// fonts load identically under snapshot tests.
private final class RisoBundleToken {}

extension Bundle {
    static let riso = Bundle(for: RisoBundleToken.self)
}

// MARK: - Colors

extension Color {
    static let risoPaper = Color("RisoPaper", bundle: .riso)
    static let risoPaper2 = Color("RisoPaper2", bundle: .riso)
    static let risoInk = Color("RisoInk", bundle: .riso)
    /// Non-inverting dark ink (`#18120B` in both light and dark). `risoInk`
    /// flips to cream in dark mode, which is unreadable on the always-bright
    /// `risoGold` accent and makes `.multiply` overprint dots vanish. Use this
    /// for content placed on gold and for halftone/overprint dots.
    static let risoInkStatic = Color("RisoInkStatic", bundle: .riso)
    static let risoMuted = Color("RisoMuted", bundle: .riso)
    static let risoBlue = Color("RisoBlue", bundle: .riso)
    static let risoRed = Color("RisoRed", bundle: .riso)
    static let risoGreen = Color("RisoGreen", bundle: .riso)
    static let risoGold = Color("RisoGold", bundle: .riso)
    static let risoAchievement = Color("RisoAchievement", bundle: .riso)
}

// MARK: - Fonts

/// Display / heading face — Bricolage Grotesque. Two bundled weights.
enum RisoHeadWeight {
    case bold       // 700
    case extraBold  // 800
    var psName: String {
        switch self {
        case .bold: return "BricolageGrotesque-Bold"
        case .extraBold: return "BricolageGrotesque-ExtraBold"
        }
    }
}

/// Body / metadata face — Archivo. Five bundled weights.
enum RisoBodyWeight {
    case regular    // 400
    case medium     // 500
    case semibold   // 600
    case bold       // 700
    case extraBold  // 800
    var psName: String {
        switch self {
        case .regular: return "Archivo-Regular"
        case .medium: return "Archivo-Medium"
        case .semibold: return "Archivo-SemiBold"
        case .bold: return "Archivo-Bold"
        case .extraBold: return "Archivo-ExtraBold"
        }
    }
}

extension Font {
    /// Bricolage Grotesque at `size`, scaling with Dynamic Type relative to
    /// `.title`. (Snapshots run at the default content size, so they stay
    /// deterministic.)
    static func risoHead(_ size: CGFloat, _ weight: RisoHeadWeight = .extraBold) -> Font {
        .custom(weight.psName, size: size, relativeTo: .title)
    }

    /// Archivo at `size`, scaling with Dynamic Type relative to `.body`.
    static func risoBody(_ size: CGFloat, _ weight: RisoBodyWeight = .regular) -> Font {
        .custom(weight.psName, size: size, relativeTo: .body)
    }
}
