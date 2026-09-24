import SwiftUI

/// The Mark complete / Mark incomplete button shown in `BoardPlayView`'s
/// detail sheet for a NORMAL task, extracted to a pure presentational leaf so
/// it can be snapshot-tested without a DB-backed container.
///
/// Windowed Completion (docs Decision 9 + §Write paths — "the toggle is
/// disabled with an explanatory affordance"): when `sealBlocked` is true, the
/// button renders disabled and a short functional caption explains why —
/// every live completion event backing this green is sealed-window-immune, so
/// un-completing here would tombstone nothing.
struct CompletionToggleView: View {
    /// The task's current (windowed or frozen-snapshot) completed state.
    let isCompleted: Bool
    /// True iff un-completing would be inert because every live completion is
    /// sealed-window-immune (docs Decision 9). Disables the button + shows
    /// the explanatory caption in place of a silent no-op tap.
    var sealBlocked: Bool = false
    /// Any other reason the toggle should be disabled (board locked / a write
    /// already in flight) — composed with `sealBlocked` for the final
    /// disabled state.
    var disabled: Bool = false
    let action: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Button(action: action) {
                HStack(spacing: 8) {
                    Image(systemName: isCompleted ? "xmark.circle" : "checkmark.circle")
                    Text(isCompleted ? "Mark incomplete" : "Mark complete")
                }
                .font(.risoHead(15, .bold))
                .foregroundStyle(isCompleted ? Color.risoInk : Color.risoPaper)
                .frame(maxWidth: .infinity)
                .padding(.vertical, 13)
                .risoCard(fill: isCompleted ? .risoPaper2 : .risoGreen)
            }
            .buttonStyle(RisoButtonStyle())
            .disabled(disabled || sealBlocked)

            if sealBlocked {
                Text("Completed in a closed window")
                    .font(.risoBody(11.5, .semibold))
                    .foregroundStyle(Color.risoMuted)
            }
        }
    }
}

#if DEBUG
#Preview("Completion Toggle") {
    ZStack {
        RisoPaperBackground()
        VStack(spacing: 16) {
            CompletionToggleView(isCompleted: false, action: {})
            CompletionToggleView(isCompleted: true, action: {})
            CompletionToggleView(isCompleted: true, sealBlocked: true, action: {})
        }
        .padding()
    }
}
#endif
