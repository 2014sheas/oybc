import SwiftUI

/// CoreBoardsSectionView — persistent home-screen section showing one
/// row per *enabled* recurring timeframe (daily/weekly/monthly/yearly).
/// Replaces the earlier `PendingCoreBoardsSectionView` which only
/// rendered when there were uncreated current-window core boards.
///
/// Each row's content depends on `slot.currentBoard`:
///   - **Done** (board exists): timeframe label + window label +
///     "Done" pill + Play button (opens the board) + Browse →.
///   - **Not yet** (board nil): same labels + "Not yet" pill + Create
///     button + Browse →.
///
/// No dismiss affordance — per-timeframe disable lives in Board
/// Preferences (Profile → Board Preferences → Recurring section).
///
/// File kept at the original path so the Xcode project doesn't need
/// regeneration. Old type name is preserved via a typealias at the
/// bottom for any consumer still using it during the migration window.
struct CoreBoardsSectionView: View {

    // MARK: - Inputs

    /// One slot per enabled recurring timeframe, daily-first.
    let slots: [CoreBoardSlot]

    /// Invoked when the user taps Create on a not-yet row.
    let onCreate: (CoreBoardSlot) -> Void

    /// Optional — invoked when the user taps Play on a done row.
    /// Omit on the Create-tab caller (Create surface doesn't navigate
    /// to play — that's the Boards tab's job).
    var onPlay: ((String) -> Void)? = nil

    /// Optional — invoked when the user taps Browse → on a row.
    /// Opens the per-timeframe Core Board Browser. Omit on the
    /// Create-tab caller for the same reason as `onPlay`.
    var onBrowse: ((Timeframe) -> Void)? = nil

    // MARK: - Body

    var body: some View {
        if slots.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                Text("Core boards")
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .textCase(.uppercase)
                    .padding(.horizontal, 4)

                VStack(spacing: 10) {
                    ForEach(slots) { slot in
                        slotCard(slot)
                    }
                }
            }
        }
    }

    // MARK: - Per-row card

    @ViewBuilder
    private func slotCard(_ slot: CoreBoardSlot) -> some View {
        let isDone = slot.currentBoard != nil

        HStack(spacing: 10) {
            Image(systemName: icon(for: slot.timeframe))
                .font(.system(size: 18))
                .foregroundStyle(.tint)
                .frame(width: 28)
                .accessibilityHidden(true)

            VStack(alignment: .leading, spacing: 1) {
                Text(label(for: slot.timeframe))
                    .font(.subheadline)
                    .fontWeight(.semibold)
                Text(slot.windowLabel)
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }

            Spacer(minLength: 4)

            statusPill(isDone: isDone)

            if isDone, let board = slot.currentBoard {
                Button("Play") {
                    onPlay?(board.id)
                }
                .buttonStyle(.bordered)
                .controlSize(.small)
                .tint(.accentColor)
                .disabled(onPlay == nil)
                .accessibilityLabel("Open \(label(for: slot.timeframe)) board")
            } else {
                Button("Create") {
                    onCreate(slot)
                }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
                .accessibilityLabel("Create \(label(for: slot.timeframe)) board")
            }

            if let onBrowse = onBrowse {
                Button("Browse →") {
                    onBrowse(slot.timeframe)
                }
                .buttonStyle(.borderless)
                .controlSize(.small)
                .accessibilityLabel("Browse \(label(for: slot.timeframe)) core boards")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(Color.accentColor.opacity(0.08))
                .overlay(
                    RoundedRectangle(cornerRadius: 10)
                        .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
                )
        )
    }

    @ViewBuilder
    private func statusPill(isDone: Bool) -> some View {
        Text(isDone ? "DONE" : "NOT YET")
            .font(.system(size: 10, weight: .bold))
            .foregroundStyle(isDone ? Color(red: 0.122, green: 0.435, blue: 0.247) : .secondary)
            .padding(.horizontal, 8)
            .padding(.vertical, 2)
            .background(
                Capsule()
                    .fill(isDone
                        ? Color(red: 0.122, green: 0.435, blue: 0.247).opacity(0.15)
                        : Color(.tertiarySystemBackground))
            )
            .overlay(
                Capsule().strokeBorder(
                    isDone ? Color.clear : Color(.separator),
                    lineWidth: 1
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
        case .custom:  return "pin" // unreachable
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

/// Back-compat typealias for any consumer that still references the
/// old type name during the migration window. Safe to drop once all
/// callers use `CoreBoardsSectionView` directly.
typealias PendingCoreBoardsSectionView = CoreBoardsSectionView
