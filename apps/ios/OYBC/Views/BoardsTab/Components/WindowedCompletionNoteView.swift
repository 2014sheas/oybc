import SwiftUI

/// One-time in-app upgrade note required by the Windowed Completion rollout
/// (docs/WINDOWED_COMPLETION.md §What changes visibly at upgrade). iOS twin of
/// web's `WindowedCompletionNote.tsx`.
///
/// After the migration, live boards re-evaluate under windowed semantics: a task
/// completed *before* a board started no longer carries its green onto that
/// board. That is user-visible and would look like data loss without a word of
/// explanation. Copy is verbatim-identical to web and stays strictly functional.
///
/// Deliberately minimal: a single dismissible Boards-tab banner row, shown once
/// and remembered via `UserDefaults` (`@AppStorage`). NOT gated on whether this
/// device actually had bleed-greens — every upgraded device shows it once, then
/// never again.
struct WindowedCompletionNoteView: View {
    /// `UserDefaults` key persisting one-time dismissal. Presence of `true` = the
    /// user has seen + dismissed it. Mirrors web's
    /// `oybc.windowedCompletionNoteDismissed.v1` localStorage key.
    @AppStorage("oybc.windowedCompletionNoteDismissed.v1") private var dismissed = false

    var body: some View {
        if !dismissed {
            WindowedCompletionNoteCard { dismissed = true }
        }
    }
}

/// The pure Riso-styled leaf — takes an `onDismiss` closure and holds no
/// persistence, so it renders deterministically for snapshot coverage.
///
/// Gold Riso surface with `Color.risoInkStatic` content (plain `risoInk` flips
/// to cream in dark mode and would vanish on the light gold fill —
/// reference_riso_adaptive_ink_fill_darkmode). Matches `RisoArrivalBanner`.
struct WindowedCompletionNoteCard: View {
    /// Called when the user taps "Got it".
    let onDismiss: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 10) {
            VStack(alignment: .leading, spacing: 5) {
                HStack(spacing: 6) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 12, weight: .bold))
                        .foregroundStyle(Color.risoInkStatic)
                    Text("What's new")
                        .font(.risoHead(13, .bold))
                        .foregroundStyle(Color.risoInkStatic)
                }
                Text("Boards now track each window's work — squares completed before a board started no longer carry over.")
                    .font(.risoBody(12, .semibold))
                    .foregroundStyle(Color.risoInkStatic)
                    .multilineTextAlignment(.leading)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }

            Button(action: onDismiss) {
                Text("Got it")
                    .font(.risoHead(12, .bold))
                    .foregroundStyle(Color.risoInkStatic)
                    .padding(.horizontal, 12)
                    .padding(.vertical, 7)
                    .overlay(
                        RoundedRectangle(cornerRadius: Riso.cellRadius)
                            .strokeBorder(Color.risoInkStatic, lineWidth: Riso.Keyline.dense)
                    )
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Dismiss what's-new note")
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 12)
        .background(Color.risoGold)
        .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .strokeBorder(Color.risoInkStatic, lineWidth: Riso.Keyline.container)
        )
        .background(
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .fill(Color.risoInkStatic)
                .offset(x: Riso.Shadow.small, y: Riso.Shadow.small)
        )
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}
