import SwiftUI

// MARK: - RisoInitialAvatar

/// Initials avatar — the Profile-surface replacement for the retired
/// `BlipPlaceholder` mascot (Blip-retirement handoff, 2026-09-10), matching
/// web's `ProfilePage` `.avatarPlaceholder` (blue circle, cream initial).
///
/// The glyph color is `risoOnColor` (static cream) — it must NOT flip in
/// dark mode, where `risoPaper` goes near-black and would vanish on blue.
struct RisoInitialAvatar: View {
    /// Single display character — compute via `Self.initial(...)`.
    let initial: String
    var size: CGFloat = 58

    var body: some View {
        Circle()
            .fill(Color.risoBlue)
            .overlay(
                Circle().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
            )
            .overlay(
                Text(initial)
                    .font(.risoHead(size * 0.42, .extraBold))
                    .foregroundStyle(Color.risoOnColor)
            )
            .frame(width: size, height: size)
    }

    /// Initial rule — mirrors web `ProfilePage.tsx` (guest-mode aware):
    /// first char of the trimmed display name, uppercased; else the email's
    /// first char; else "G" for guests; else "?".
    static func initial(displayName: String?, email: String?, isGuest: Bool) -> String {
        if let c = displayName?.trimmingCharacters(in: .whitespacesAndNewlines).first {
            return String(c).uppercased()
        }
        if isGuest { return "G" }
        if let c = email?.trimmingCharacters(in: .whitespacesAndNewlines).first {
            return String(c).uppercased()
        }
        return "?"
    }
}

#if DEBUG
#Preview {
    ZStack {
        RisoPaperBackground()
        HStack(spacing: 20) {
            RisoInitialAvatar(initial: "S", size: 58)
            RisoInitialAvatar(initial: "G", size: 92)
                .risoHardShadow(Riso.Shadow.small, radius: 46)
        }
    }
}
#endif
