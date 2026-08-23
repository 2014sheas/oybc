import SwiftUI

/// Riso-styled account card — the top section of the Profile tab.
///
/// Shows a circular Blip avatar, display name with a pencil edit affordance,
/// and the user's email address. Tapping the name row fires `onEditName`.
///
/// This is a pure presentational view — it takes props and calls back.
/// The name-edit alert is hosted in the caller (ProfileView) so the
/// alert state doesn't need to live inside this component.
///
/// **Guest mode** (docs/GUEST_MODE.md §Phase 3): a Firebase anonymous session
/// has no email. When `isGuest` is true, "Guest" renders where the email
/// would go, regardless of what's passed for `email` (an anon `User.email`
/// is always `""`, never a real address). Name edit stays available — it
/// works the same for a guest's local row.
struct RisoProfileAccountCard: View {
    let displayName: String
    let email: String?
    var isGuest: Bool = false
    let onEditName: () -> Void

    var body: some View {
        HStack(spacing: 14) {
            // Blip avatar — circular keyline around the placeholder mascot
            ZStack {
                Circle()
                    .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
                    .frame(width: 58, height: 58)
                BlipPlaceholder(size: 50, mood: .happy)
            }
            .frame(width: 58, height: 58)

            VStack(alignment: .leading, spacing: 3) {
                // Name row — tap anywhere on the row to edit
                Button(action: onEditName) {
                    HStack(spacing: 5) {
                        Text(displayName)
                            .font(.risoHead(17, .extraBold))
                            .tracking(-0.34)
                            .foregroundStyle(Color.risoInk)
                        Text("✎")
                            .font(.risoBody(13, .medium))
                            .foregroundStyle(Color.risoMuted)
                    }
                }
                .buttonStyle(.plain)

                if isGuest {
                    Text("Guest")
                        .risoSub()
                } else if let email {
                    Text(email)
                        .risoSub()
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(Riso.cardPadding)
        .risoCard()
        .risoHardShadow(Riso.Shadow.small, radius: Riso.cardRadius)
    }
}

#if DEBUG
#Preview {
    ZStack {
        RisoPaperBackground()
        RisoProfileAccountCard(
            displayName: "OYBC User",
            email: "you@example.com",
            onEditName: {}
        )
        .padding(20)
    }
}

#Preview("Guest") {
    ZStack {
        RisoPaperBackground()
        RisoProfileAccountCard(
            displayName: "OYBC User",
            email: nil,
            isGuest: true,
            onEditName: {}
        )
        .padding(20)
    }
}
#endif
