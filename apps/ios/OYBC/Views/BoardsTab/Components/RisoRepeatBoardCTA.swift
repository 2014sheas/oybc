import SwiftUI

/// Board-screen "↻ Repeat this board…" CTA for a one-off board (Task Pools
/// + Recurring Boards Rework, P6 — docs/POOLS_RECURRING.md §Surfaces item
/// 7). Shown only for a non-recurring, non-sealed board with a
/// non-CHOSEN center (the caller's gating job, not this view's).
///
/// Tapping the dashed button reveals an inline cadence picker (reusing the
/// wizard's "Repeats" `RisoSegmented` vocabulary — same four options, same
/// styling — from `RisoBoardSetupForm`) plus a confirm button. Confirming
/// calls `onConfirm(cadence)`; the caller is responsible for the actual
/// `repeatBoardAsTemplate` write and for replacing this CTA with
/// `RisoRecurringManageRow` once the board's `spawnedFromTemplateId` is
/// back-stamped.
///
/// Leaf view (no DB access) so it's independently snapshot-testable, same
/// rationale as `RisoRecurringManageRow`.
struct RisoRepeatBoardCTA: View {
    var onConfirm: (Timeframe) -> Void

    @State private var isExpanded: Bool
    @State private var selectedCadence: Timeframe

    private let cadenceOptions: [(value: Timeframe, label: String)] = [
        (.daily, "Daily"),
        (.weekly, "Weekly"),
        (.monthly, "Monthly"),
        (.yearly, "Yearly"),
    ]

    /// - Parameters:
    ///   - initiallyExpanded: Seeds the cadence-picker's expanded state.
    ///     Defaults to `false` (collapsed, matching every production call
    ///     site) — exposed only so snapshot tests can render the expanded
    ///     shape deterministically without simulating a tap on `@State`
    ///     from outside the view.
    ///   - initialCadence: Seeds the selected cadence. Defaults to `.daily`.
    ///   - onConfirm: Called with the chosen cadence when the user taps
    ///     "Start repeating".
    init(
        initiallyExpanded: Bool = false,
        initialCadence: Timeframe = .daily,
        onConfirm: @escaping (Timeframe) -> Void
    ) {
        self._isExpanded = State(initialValue: initiallyExpanded)
        self._selectedCadence = State(initialValue: initialCadence)
        self.onConfirm = onConfirm
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            RisoDashedButton(label: "↻ Repeat this board…") {
                withAnimation(.easeInOut(duration: 0.18)) {
                    isExpanded.toggle()
                }
            }

            if isExpanded {
                VStack(alignment: .leading, spacing: 10) {
                    RisoSegmented(
                        options: cadenceOptions,
                        selection: $selectedCadence
                    )
                    RisoButton(title: "Start repeating", kind: .primary, fullWidth: true) {
                        onConfirm(selectedCadence)
                        isExpanded = false
                    }
                }
            }
        }
    }
}

#if DEBUG
#Preview("Repeat Board CTA") {
    ZStack {
        RisoPaperBackground()
        VStack(spacing: 14) {
            RisoRepeatBoardCTA(onConfirm: { _ in })
        }
        .padding()
    }
}
#endif
