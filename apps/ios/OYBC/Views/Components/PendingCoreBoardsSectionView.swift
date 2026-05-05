import SwiftUI

/// Variants for `PendingCoreBoardsSectionView`. Drives heading copy +
/// outer padding so the same component looks at home on both surfaces
/// without requiring two parallel files.
enum PendingCoreBoardsSectionVariant {
    /// Mounted above the board list on the Boards tab. Heading: "Pending boards".
    case boardsTab
    /// Mounted above the custom-board CTA on the Create tab. Heading:
    /// "Get started with today's boards".
    case createTab
}

/// PendingCoreBoardsSectionView — Promotes the "core boards" (daily /
/// weekly / monthly / yearly recurring boards) to the headline action on
/// the Boards and Create tabs. iOS twin of web's
/// `PendingCoreBoardsSection`. Replaces the smaller
/// `RecurringBoardsBannerView` from the earlier 6.1b implementation.
///
/// Each pending entry renders as a tappable card (large SF Symbol icon +
/// bold timeframe label + suggested-name subtitle + prominent Create
/// button + secondary Dismiss link). Renders nothing when `pending` is
/// empty — the parent's fallback content (custom-board CTA on Create,
/// plain board list on Boards) takes over.
///
/// Dismissals are session-only via local `@State Set<String>`. Permanent
/// suppression is the per-timeframe toggle in Board Preferences.
struct PendingCoreBoardsSectionView: View {

    // MARK: - Inputs

    /// Pending entries from `PendingRecurringBoardsViewModel.pending`.
    /// Pre-sorted longest-first.
    let pending: [PendingRecurringBoard]

    /// Which surface this section is mounted on.
    let variant: PendingCoreBoardsSectionVariant

    /// Invoked when the user taps Create on a row. Parent decides what
    /// to do — the Boards-tab consumer flips a tab-binding (cross-tab
    /// handoff into the Create tab); the Create-tab consumer enters
    /// wizard mode in place. Hoisting the behavior here lets the
    /// create-tab path skip a useless tab-bounce.
    let onCreate: (PendingRecurringBoard) -> Void

    // MARK: - Local state

    @State private var dismissedKeys: Set<String> = []

    // MARK: - Derived

    private var visible: [PendingRecurringBoard] {
        pending.filter { !dismissedKeys.contains(key(for: $0)) }
    }

    private func key(for entry: PendingRecurringBoard) -> String {
        "\(entry.timeframe.rawValue)::\(entry.startDate)"
    }

    private var heading: String {
        switch variant {
        case .createTab: return "Get started with today's boards"
        case .boardsTab: return "Pending boards"
        }
    }

    // MARK: - Body

    var body: some View {
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: 10) {
                Text(heading)
                    .font(.caption)
                    .fontWeight(.semibold)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                    .padding(.horizontal, 4)

                // `id: \.element.timeframe` rather than `\.startDate`:
                // each Timeframe enum case appears at most once per
                // detection pass, but on Jan 1 yearly/monthly/daily
                // share the same start date. Keying by timeframe
                // prevents the multi-row collision regression.
                ForEach(Array(visible.enumerated()), id: \.element.timeframe) { _, entry in
                    card(for: entry)
                }
            }
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Recurring boards to create")
        }
    }

    // MARK: - Card

    private func card(for entry: PendingRecurringBoard) -> some View {
        HStack(spacing: 14) {
            Image(systemName: icon(for: entry.timeframe))
                .font(.system(size: 26))
                .foregroundStyle(.tint)
                .frame(width: 40)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 2) {
                Text(label(for: entry.timeframe))
                    .font(.headline)
                    .fontWeight(.bold)
                Text(entry.suggestedName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            VStack(alignment: .trailing, spacing: 4) {
                Button("Create") {
                    onCreate(entry)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.regular)

                Button("Dismiss") {
                    dismissedKeys.insert(key(for: entry))
                }
                .buttonStyle(.plain)
                .font(.caption)
                .foregroundStyle(.secondary)
                .accessibilityLabel("Dismiss \(label(for: entry.timeframe)) prompt for this session")
            }
        }
        .padding(14)
        .background(
            RoundedRectangle(cornerRadius: 12)
                .fill(Color.accentColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 12)
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
                )
        )
    }

    // MARK: - Display helpers

    private func icon(for timeframe: Timeframe) -> String {
        switch timeframe {
        case .yearly:  return "calendar.badge.clock"
        case .monthly: return "calendar"
        case .weekly:  return "calendar.day.timeline.left"
        case .daily:   return "sun.max"
        case .custom:  return "pin" // never reached in Phase 1
        }
    }

    private func label(for timeframe: Timeframe) -> String {
        switch timeframe {
        case .yearly:  return "Yearly"
        case .monthly: return "Monthly"
        case .weekly:  return "Weekly"
        case .daily:   return "Daily"
        case .custom:  return "Custom"
        }
    }
}

#Preview("Multiple entries (Jan 1)") {
    ScrollView {
        PendingCoreBoardsSectionView(
            pending: [
                PendingRecurringBoard(
                    timeframe: .yearly,
                    startDate: "2026-01-01T00:00:00.000",
                    endDate: "2026-12-31T23:59:59.999",
                    suggestedName: "2026"
                ),
                PendingRecurringBoard(
                    timeframe: .monthly,
                    startDate: "2026-01-01T00:00:00.000",
                    endDate: "2026-01-31T23:59:59.999",
                    suggestedName: "January 2026"
                ),
                PendingRecurringBoard(
                    timeframe: .weekly,
                    startDate: "2025-12-29T00:00:00.000",
                    endDate: "2026-01-04T23:59:59.999",
                    suggestedName: "Week of Dec 29 – Jan 4"
                ),
                PendingRecurringBoard(
                    timeframe: .daily,
                    startDate: "2026-01-01T00:00:00.000",
                    endDate: "2026-01-01T23:59:59.999",
                    suggestedName: "Jan 1, 2026"
                ),
            ],
            variant: .boardsTab,
            onCreate: { _ in }
        )
        .padding()
    }
}

#Preview("Single Daily entry") {
    PendingCoreBoardsSectionView(
        pending: [
            PendingRecurringBoard(
                timeframe: .daily,
                startDate: "2026-05-04T00:00:00.000",
                endDate: "2026-05-04T23:59:59.999",
                suggestedName: "May 4, 2026"
            ),
        ],
        variant: .createTab,
        onCreate: { _ in }
    )
    .padding()
}
