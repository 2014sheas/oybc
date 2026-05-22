import SwiftUI

/// CoreBoardsSectionView — persistent home-screen section showing one
/// row per *enabled* recurring timeframe (daily/weekly/monthly/yearly).
///
/// Each row is a single tap target. The parent decides where it
/// navigates — the Boards-tab consumer pushes the per-timeframe
/// browser; the Create-tab consumer launches the wizard for that
/// timeframe's current window. No competing in-row buttons.
///
/// No dismiss affordance — per-timeframe disable lives in Board
/// Preferences (Profile → Board Preferences → Recurring section).
///
/// File kept at the original path so the Xcode project doesn't need
/// regeneration. Old type name preserved via a typealias at the
/// bottom for any consumer still using it during the migration window.
struct CoreBoardsSectionView: View {

    // MARK: - Inputs

    /// One slot per enabled recurring timeframe, daily-first.
    let slots: [CoreBoardSlot]

    /// Invoked when the user taps anywhere on a row.
    let onSelect: (CoreBoardSlot) -> Void

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
                        slotRow(slot)
                    }
                }
            }
        }
    }

    // MARK: - Per-row tappable card

    @ViewBuilder
    private func slotRow(_ slot: CoreBoardSlot) -> some View {
        Button {
            onSelect(slot)
        } label: {
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
                        .foregroundColor(.primary)
                    Text(slot.windowLabel)
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 8)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(
                RoundedRectangle(cornerRadius: 10)
                    .fill(Color.accentColor.opacity(0.08))
                    .overlay(
                        RoundedRectangle(cornerRadius: 10)
                            .stroke(Color.secondary.opacity(0.15), lineWidth: 0.5)
                    )
            )
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityLabel("\(label(for: slot.timeframe)) core boards — \(slot.windowLabel)")
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
