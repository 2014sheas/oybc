import SwiftUI

/// Visual variant for `CreateHubBoardCTAView`.
enum CreateHubBoardCTAVariant {
    /// Large gradient card with an icon. Used when the parent has no
    /// pending core boards to surface above.
    case primary
    /// Smaller flat card with muted styling. Used when
    /// `CoreBoardsSectionView` is the headline action above this CTA.
    case secondary
}

/// CreateHubBoardCTAView — Riso-styled card that invites the user to start
/// a new board. iOS twin of web's `CreateHubBoardCTA`.
///
/// Task Pools + Recurring Boards Rework (P4) — collapsed to a SINGLE flow:
/// the separate "Create a recurring board" CTA (#71's `.recurring` kind)
/// retired along with the `?newRecurring=1`-equivalent deep link
/// (`pendingNewRecurringTemplate`) — recurrence is now a Step-1 "Repeats"
/// board property (`BoardWizardViewModel.setRepeats(_:)`), chosen inside
/// the one wizard entry point, not a separate CTA. `variant` (`.primary`
/// risoCard + hard shadow, red system-image badge, Bricolage headline vs.
/// `.secondary` lighter flat card, muted icon square) is unchanged.
struct CreateHubBoardCTAView: View {
    let onTap: () -> Void
    var variant: CreateHubBoardCTAVariant = .primary

    // MARK: - Copy

    /// Byte-identical to web's copy (parity-critical, same spec) —
    /// docs/POOLS_RECURRING.md §Surfaces item 3.
    private let title = "Start a new board"
    private let subtitle = "One-off or repeating — decide in setup."
    private let systemImageName = "plus"

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
                // Icon square — gold fill with ink symbol (non-inverting ink so
                // the glyph stays readable on gold in dark mode).
                Image(systemName: systemImageName)
                    .font(.system(size: 18, weight: .bold))
                    .foregroundStyle(Color.risoInkStatic)
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
