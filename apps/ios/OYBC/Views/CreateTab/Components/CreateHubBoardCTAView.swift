import SwiftUI

/// Visual variant for `CreateHubBoardCTAView`.
enum CreateHubBoardCTAVariant {
    /// Large gradient card with sparkle icon. The original (and default)
    /// presentation; used when the parent has no pending core boards to
    /// surface above.
    case primary
    /// Smaller flat card with muted styling. Used when
    /// `PendingCoreBoardsSectionView` is the headline action above this
    /// CTA — Phase 6.1d demoted the headline once core boards became
    /// the prominent option, but the wording was tightened in the
    /// Phase 6.2 rework: the secondary CTA is no longer "custom-only"
    /// (the wizard's recurring toggle means this entry can build
    /// recurring boards too), so both variants share the same name.
    case secondary
}

/// CreateHubBoardCTAView — Card that invites the user to start a new
/// board. Renders the primary action on the Create Hub; tapping it
/// launches the 3-step board-creation wizard. iOS twin of web's
/// `CreateHubBoardCTA`.
///
/// Two variants — same destination, different visual weight:
///   - `.primary` (default): large gradient card with sparkle icon.
///   - `.secondary`: smaller flat card. Same copy as primary but
///     muted, used when `PendingCoreBoardsSectionView` is the
///     headline action above this CTA.
struct CreateHubBoardCTAView: View {
    let onTap: () -> Void
    var variant: CreateHubBoardCTAVariant = .primary

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
                Text("✨")
                    .font(.system(size: 32))
                VStack(alignment: .leading, spacing: 4) {
                    Text("Start a new board")
                        .font(.title3)
                        .fontWeight(.bold)
                        .foregroundColor(.white)
                    Text("Set it up, pick your tasks, and activate.")
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
        .accessibilityLabel("Start a new board")
    }

    // MARK: - Secondary

    private var secondaryButton: some View {
        Button(action: onTap) {
            HStack(spacing: 12) {
                Image(systemName: "plus")
                    .font(.body)
                    .fontWeight(.semibold)
                    .foregroundStyle(.secondary)
                    .frame(width: 28, height: 28)
                    .overlay(
                        RoundedRectangle(cornerRadius: 6)
                            .stroke(Color.secondary.opacity(0.25), lineWidth: 0.5)
                    )

                VStack(alignment: .leading, spacing: 2) {
                    Text("Start a new board")
                        .font(.subheadline)
                        .fontWeight(.semibold)
                        .foregroundColor(.primary)
                    Text("Pick a timeframe, size, and tasks — optionally recurring.")
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
        .accessibilityLabel("Start a new board")
    }
}
