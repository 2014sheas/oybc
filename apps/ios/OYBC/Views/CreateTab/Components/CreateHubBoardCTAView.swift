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

/// CreateHubBoardCTAView — Card that invites the user to start a new
/// board. Renders an action on the Create Hub; tapping it launches the
/// 3-step board-creation wizard. iOS twin of web's `CreateHubBoardCTA`.
///
/// Two axes:
///   - `kind` (#71): `.oneOff` (a single board) vs `.recurring` (a
///     template that auto-spawns each window). The recurring entry
///     replaced the in-wizard "Make recurring" toggle.
///   - `variant`: `.primary` (large gradient headline card) vs
///     `.secondary` (smaller flat card) — same destination, different
///     visual weight.
struct CreateHubBoardCTAView: View {
    var kind: CreateHubBoardCTAKind = .oneOff
    let onTap: () -> Void
    var variant: CreateHubBoardCTAVariant = .primary

    /// Copy + glyphs per `kind`.
    private var title: String {
        kind == .recurring ? "Create a recurring board" : "Start a new board"
    }
    private var subtitle: String {
        kind == .recurring
            ? "Auto-spawns a fresh board each window from a pool."
            : "Set it up, pick your tasks, and activate."
    }
    private var emoji: String { kind == .recurring ? "🔁" : "✨" }
    private var secondarySymbol: String { kind == .recurring ? "repeat" : "plus" }

    var body: some View {
        switch variant {
        case .primary:
            primaryButton
        case .secondary:
            secondaryButton
        }
    }

    // MARK: - Primary

    private var primaryButton: some View {
        Button(action: onTap) {
            HStack(spacing: 16) {
                Text(emoji)
                    .font(.system(size: 32))
                VStack(alignment: .leading, spacing: 4) {
                    Text(title)
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundColor(.white.opacity(0.85))
                        .fixedSize(horizontal: false, vertical: true)
                }
                Spacer()
                Image(systemName: "chevron.right")
                    .font(.title3)
                    .fontWeight(.semibold)
                    .foregroundColor(.white.opacity(0.9))
            }
            .padding(20)
            .background(
                LinearGradient(
                    colors: [Color.blue, Color.indigo],
                    startPoint: .topLeading,
                    endPoint: .bottomTrailing
                )
            )
            .cornerRadius(14)
            .shadow(color: Color.blue.opacity(0.25), radius: 10, x: 0, y: 4)
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }

    // MARK: - Secondary

    private var secondaryButton: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: secondarySymbol)
                    .font(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text(title)
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    Text(subtitle)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }

                Spacer()

                Image(systemName: "chevron.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(14)
            // `.contentShape(Rectangle())` makes the entire padded card
            // area tappable, not just the visible icon + text. The
            // `.background(...).stroke(...)` below paints only the border;
            // without `.contentShape` the empty interior of the card
            // (between the icon and the chevron) is not opaque content
            // and SwiftUI's hit-testing skips it, leaving most of the
            // CTA non-tappable.
            .contentShape(Rectangle())
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
            )
        }
        .buttonStyle(.plain)
        .accessibilityLabel(title)
    }
}
