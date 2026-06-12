import SwiftUI

/// Riso typography helpers — the named roles from `riso.css`. Tracking is
/// converted from the CSS `em` values to points at each role's fixed size
/// (em × size).
extension View {
    /// Kicker — Bricolage 700, 12px, +.22em caps, red by default.
    func risoKicker(_ color: Color = .risoRed) -> some View {
        self.font(.risoHead(12, .bold))
            .tracking(2.64)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }

    /// H1 display — Bricolage 800, 34px, −.03em.
    func risoH1() -> some View {
        self.font(.risoHead(34, .extraBold))
            .tracking(-1.02)
            .foregroundStyle(Color.risoInk)
    }

    /// H2 — Bricolage 800, 22px, −.02em.
    func risoH2() -> some View {
        self.font(.risoHead(22, .extraBold))
            .tracking(-0.44)
            .foregroundStyle(Color.risoInk)
    }

    /// Section label — Archivo 700, 11px, +.1em caps, muted.
    func risoSectionLabel(_ color: Color = .risoMuted) -> some View {
        self.font(.risoBody(11, .bold))
            .tracking(1.1)
            .textCase(.uppercase)
            .foregroundStyle(color)
    }

    /// Secondary subtitle — Archivo 600, 13px, muted.
    func risoSub() -> some View {
        self.font(.risoBody(13, .semibold))
            .foregroundStyle(Color.risoMuted)
    }
}
