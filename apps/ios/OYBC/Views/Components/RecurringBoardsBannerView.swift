import SwiftUI

/// RecurringBoardsBannerView — Lists the recurring board windows the user
/// should be prompted to create. Rendered above the board list on the
/// Boards tab when `pending.isEmpty == false`. iOS twin of web's
/// `RecurringBoardsBanner` component (Phase 6.1b).
///
/// Two affordances per row:
///   - **Create**: invokes `onCreate(entry)` — the parent navigates into
///     the board wizard with the timeframe prefilled (and field locked).
///   - **Dismiss**: hides that row for the **rest of the app session**
///     (no persistence). Re-prompts on next launch. Permanent suppression
///     is via the corresponding toggle in Board Preferences.
///
/// Order is preserved from `findPendingRecurringBoards` (longest-window-
/// first) so creating top-down builds the parent chain before children —
/// makes the wizard's "From parent boards" filter useful immediately.
struct RecurringBoardsBannerView: View {

    // MARK: - Inputs

    /// Pending entries from `PendingRecurringBoardsViewModel.pending`.
    let pending: [PendingRecurringBoard]
    /// Invoked when the user taps Create on a row.
    let onCreate: (PendingRecurringBoard) -> Void

    // MARK: - Local state

    /// Session-only dismissal set — keys are `<timeframe>::<startDate>`.
    /// Cleared when the view is destroyed (e.g., navigating away from the
    /// Boards tab and back). Persistent suppression is via prefs toggles.
    @State private var dismissedKeys: Set<String> = []

    // MARK: - Derived

    private var visible: [PendingRecurringBoard] {
        pending.filter { !dismissedKeys.contains(key(for: $0)) }
    }

    private func key(for entry: PendingRecurringBoard) -> String {
        "\(entry.timeframe.rawValue)::\(entry.startDate)"
    }

    // MARK: - Body

    var body: some View {
        if !visible.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Text("Pending recurring boards")
                    .font(.caption)
                    .fontWeight(.semibold)
                    .textCase(.uppercase)
                    .foregroundStyle(.secondary)
                    .padding(.bottom, 2)

                // `id: \.timeframe` is safe because each Timeframe appears at
                // most once per detection pass (findPendingRecurringBoards
                // iterates the four recurring timeframes deduped by enum).
                // Using `\.startDate` would collapse entries on Jan 1 where
                // yearly + monthly + daily all share the same start date.
                ForEach(Array(visible.enumerated()), id: \.element.timeframe) { index, entry in
                    if index > 0 {
                        Divider()
                    }
                    row(for: entry)
                }
            }
            .padding(12)
            .background(
                RoundedRectangle(cornerRadius: 12)
                    .fill(Color.accentColor.opacity(0.06))
                    .overlay(
                        RoundedRectangle(cornerRadius: 12)
                            .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
                    )
            )
            .accessibilityElement(children: .contain)
            .accessibilityLabel("Recurring boards to create")
        }
    }

    // MARK: - Row

    private func row(for entry: PendingRecurringBoard) -> some View {
        HStack(spacing: 10) {
            // SF Symbol — sharper than emoji at this size and renders
            // correctly across simulator runtimes (some sim builds ship
            // without AppleColorEmoji.ttc).
            Image(systemName: icon(for: entry.timeframe))
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: 24)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(label(for: entry.timeframe))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(entry.suggestedName)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            Button("Create") {
                onCreate(entry)
            }
            .buttonStyle(.borderedProminent)
            .controlSize(.small)

            Button("Dismiss") {
                dismissedKeys.insert(key(for: entry))
            }
            .buttonStyle(.bordered)
            .controlSize(.small)
            .accessibilityLabel("Dismiss \(label(for: entry.timeframe)) prompt for this session")
        }
        .padding(.vertical, 4)
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
        case .custom:  return "Custom" // never reached in Phase 1
        }
    }
}

#Preview {
    VStack {
        RecurringBoardsBannerView(
            pending: [
                PendingRecurringBoard(
                    timeframe: .yearly,
                    startDate: "2026-01-01T00:00:00.000",
                    endDate: "2026-12-31T23:59:59.999",
                    suggestedName: "2026"
                ),
                PendingRecurringBoard(
                    timeframe: .monthly,
                    startDate: "2026-05-01T00:00:00.000",
                    endDate: "2026-05-31T23:59:59.999",
                    suggestedName: "May 2026"
                ),
                PendingRecurringBoard(
                    timeframe: .daily,
                    startDate: "2026-05-02T00:00:00.000",
                    endDate: "2026-05-02T23:59:59.999",
                    suggestedName: "Today"
                ),
            ],
            onCreate: { _ in }
        )
        .padding()

        Spacer()
    }
}
