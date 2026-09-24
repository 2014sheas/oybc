import SwiftUI

/// CoreBoardsSectionView — the Create hub's "Core boards" section: one
/// row per enabled recurring timeframe (daily/weekly/monthly/yearly)
/// whose current window has **no** core board yet. The consumer passes
/// `uncreatedCoreBoardSlots(...)`; a window whose core board already
/// exists is opened from the Boards tab's core grid, never re-created
/// from here.
///
/// Each row is a single tap target that launches the wizard for that
/// timeframe's current window. No competing in-row buttons.
///
/// No dismiss affordance — per-timeframe disable lives in Board
/// Preferences (Profile → Board Preferences → Recurring section).
///
/// Renders nothing when `slots` is empty — no recurring timeframe is
/// enabled, or every enabled window already has its core board.
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

    /// Issue #321 — one-line muted subtitle under the section heading
    /// (`nil` renders no subtitle; the Create hub passes its copy).
    var subtitle: String? = nil

    // MARK: - Body

    var body: some View {
        if slots.isEmpty {
            EmptyView()
        } else {
            VStack(alignment: .leading, spacing: 10) {
                VStack(alignment: .leading, spacing: 2) {
                    Text("Core boards")
                        .risoSectionLabel()
                    if let subtitle {
                        Text(subtitle)
                            .font(.risoBody(12, .regular))
                            .foregroundStyle(Color.risoMuted)
                    }
                }

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
            HStack(spacing: 12) {
                // Ink-keyline icon square — glyph on gold takes static ink
                Image(systemName: icon(for: slot.timeframe))
                    .font(.system(size: 17, weight: .bold))
                    .foregroundStyle(Color.risoInkStatic)
                    .frame(width: 40, height: 40)
                    .background(
                        RoundedRectangle(cornerRadius: Riso.cellRadius)
                            .fill(Color.risoGold)
                            .overlay(
                                RoundedRectangle(cornerRadius: Riso.cellRadius)
                                    .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense)
                            )
                    )
                    .accessibilityHidden(true)

                VStack(alignment: .leading, spacing: 2) {
                    Text(label(for: slot.timeframe))
                        .font(.risoHead(15, .bold))
                        .foregroundStyle(Color.risoInk)
                    Text(slot.windowLabel)
                        .font(.risoBody(12, .semibold))
                        .foregroundStyle(Color.risoMuted)
                }

                Spacer(minLength: 4)

                Image(systemName: "chevron.right")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(Color.risoMuted)
            }
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
            .risoCard(fill: .risoPaper2)
            .risoHardShadow(Riso.Shadow.small)
            .contentShape(Rectangle())
        }
        .buttonStyle(RisoButtonStyle(offset: Riso.Shadow.small, radius: Riso.cardRadius))
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
        case .indefinite: return "infinity" // unreachable
        }
    }

    private func label(for timeframe: Timeframe) -> String {
        switch timeframe {
        case .yearly:  return "Yearly"
        case .monthly: return "Monthly"
        case .weekly:  return "Weekly"
        case .daily:   return "Daily"
        case .custom:  return "Custom"
        case .indefinite: return "Ongoing"
        }
    }
}

/// Back-compat typealias for any consumer that still references the
/// old type name during the migration window. Safe to drop once all
/// callers use `CoreBoardsSectionView` directly.
typealias PendingCoreBoardsSectionView = CoreBoardsSectionView
