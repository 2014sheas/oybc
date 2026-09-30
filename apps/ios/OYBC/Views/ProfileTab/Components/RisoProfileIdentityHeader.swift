import SwiftUI

/// Profile-home identity header (design handoff §1.1) — a plain row, no card
/// chrome: `RisoInitialAvatar` 48pt, name (head 800 22pt, tracking −0.02em)
/// with the inline edit-name affordance, email below (muted, 12pt). The
/// trailing gear button lives in `ProfileView` (it needs the `NavigationLink`
/// to `SettingsView`, which this pure-props leaf doesn't own).
///
/// Ports the edit-name tap logic straight out of the retired
/// `RisoProfileAccountCard` (deleted in the Profile reorg — its card chrome
/// is gone, replaced by this bare row) — same behavior, smaller avatar,
/// bigger name type per the new spec.
struct RisoProfileIdentityHeader: View {
    let displayName: String
    let email: String?
    var isGuest: Bool = false
    let onEditName: () -> Void

    var body: some View {
        HStack(spacing: 12) {
            RisoInitialAvatar(
                initial: RisoInitialAvatar.initial(
                    displayName: displayName, email: email, isGuest: isGuest
                ),
                size: 48
            )

            VStack(alignment: .leading, spacing: 2) {
                Button(action: onEditName) {
                    HStack(spacing: 5) {
                        Text(displayName)
                            .font(.risoHead(22, .extraBold))
                            .tracking(-0.44)
                            .foregroundStyle(Color.risoInk)
                        Text("✎")
                            .font(.risoBody(13, .medium))
                            .foregroundStyle(Color.risoMuted)
                    }
                }
                .buttonStyle(.plain)

                if isGuest {
                    Text("Guest")
                        .font(.risoBody(12, .semibold))
                        .foregroundStyle(Color.risoMuted)
                } else if let email {
                    Text(email)
                        .font(.risoBody(12, .semibold))
                        .foregroundStyle(Color.risoMuted)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }
}

#if DEBUG
#Preview {
    ZStack {
        RisoPaperBackground()
        RisoProfileIdentityHeader(
            displayName: "Alex Rivera",
            email: "alex@example.com",
            onEditName: {}
        )
        .padding(20)
    }
}

#Preview("Guest") {
    ZStack {
        RisoPaperBackground()
        RisoProfileIdentityHeader(
            displayName: "OYBC User",
            email: nil,
            isGuest: true,
            onEditName: {}
        )
        .padding(20)
    }
}
#endif
