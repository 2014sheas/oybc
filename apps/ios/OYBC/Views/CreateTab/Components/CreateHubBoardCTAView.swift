import SwiftUI

/// Visual variant for `CreateHubBoardCTAView`.
enum CreateHubBoardCTAVariant {
    /// Large gradient card with an icon. Used when the parent has no
    /// pending core boards to surface above.
    case primary
    /// Smaller flat card with muted styling. Used when
    /// `CoreBoardsSectionView` is the headline action above this CTA,
    /// and always for the recurring entry point (#71).
    case secondary
}

/// Which creation flow the card launches (#71):
///   - `.oneOff`: a single board (the wizard's default flow).
///   - `.recurring`: a recurring-board template that auto-spawns a
///     fresh board each window.
enum CreateHubBoardCTAKind {
    case oneOff
    case recurring
}

/// CreateHubBoardCTAView — Riso-styled card that invites the user to start
/// a new board. iOS twin of web's `CreateHubBoardCTA`.
///
/// Two axes:
///   - `kind` (#71): `.oneOff` (a single board) vs `.recurring` (a
///     template that auto-spawns each window). The recurring entry
///     replaced the in-wizard "Make recurring" toggle.
///   - `variant`: `.primary` (risoCard + hard shadow, red system-image
///     badge, Bricolage headline) vs `.secondary` (lighter flat card,
///     muted icon square).
struct CreateHubBoardCTAView: View {
    var kind: CreateHubBoardCTAKind = .oneOff
    let onTap: () -> Void
    var variant: CreateHubBoardCTAVariant = .primary

    // MARK: - Copy

    private var title: String {
        kind == .recurring ? "Create a recurring board" : "Start a new board"
    }
    private var subtitle: String {
        kind == .recurring
            ? "Auto-spawns a fresh board each window from a pool."
            : "Set it up, pick your tasks, and activate."
    }
    private var systemImageName: String {
        kind == .recurring ? "repeat" : "plus"
    }

    // MARK: - Body

    var body: some View {
        switch variant {
        case .primary:
            primaryButton
        case .secondary:
            secondaryButton
        }
    }

    // MARK: - Primary variant

    /// Riso primary card — red fill, Bricolage headline, hard shadow press.
    /// Matches the `rd-cta` prototype treatment (`.rd-cta--primary`).
    private var primaryButton: some View {
        Button(action: onTap) {
            HStack(spacing: 14) {
                // Icon square — gold fill with ink symbol
                Image(systemName: systemImageName)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.risoInk)
                    .frame(width: 44, height: 44)
                    .risoCard(fill: Color.risoGold)

                VStack(alignment: .leading, spacing: 3) {
                    Text(title)
                        .font(.risoHead(16, .extraBold))
                        .foregroundStyle(Color.risoPaper)
                        .lineLimit(1)
                    Text(subtitle)
                        .font(.risoBody(12, .medium))
                        .foregroundStyle(Color.risoPaper.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 13, weight: .bold))
                    .foregroundStyle(Color.risoPaper.opacity(0.7))
            }
            .padding(Riso.cardPadding)
            .risoCard(fill: Color.risoRed)
        }
        .buttonStyle(RisoButtonStyle())
        .accessibilityLabel(title)
    }

    // MARK: - Secondary variant

    /// Riso secondary card — paper2 fill, muted icon, Archivo label.
    /// Matches the `rd-cta--secondary` prototype treatment.
    private var secondaryButton: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                // Muted icon square
                Image(systemName: systemImageName)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(Color.risoMuted)
                    .frame(width: 32, height: 32)
                    .background(
                        RoundedRectangle(cornerRadius: 6)
                            .fill(Color.risoPaper)
                    )
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .strokeBorder(Color.risoInk.opacity(0.35), lineWidth: Riso.Keyline.dense)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.risoBody(14, .semibold))
                        .foregroundStyle(Color.risoInk)
                    Text(subtitle)
                        .font(.risoBody(11, .regular))
                        .foregroundStyle(Color.risoMuted)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .frame(maxWidth: .infinity, alignment: .leading)

                Image(systemName: "chevron.right")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(Color.risoMuted)
            }
            .padding(12)
            .contentShape(Rectangle())
            .risoCard(fill: .risoPaper2)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
