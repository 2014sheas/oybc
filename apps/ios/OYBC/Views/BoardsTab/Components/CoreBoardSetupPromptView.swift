import SwiftUI

/// Empty-window prompt for the core-board window pager.
///
/// No board row is written until the user taps the button (lazy) —
/// this view only surfaces the CTA. Past windows show "Backfill";
/// current/future windows show "Set up".
///
/// Rendered in the Riso design language: mini-board art, Bricolage
/// heading, and a Riso primary button. Two containers:
///   - `framed: false` (default): standalone full-bleed layout on a
///     paper background (legacy pager behaviour, snapshot-covered).
///   - `framed: true`: bare content column for embedding inside the
///     pager's 2.5pt dashed empty-window frame (masthead rework).
///
/// Mirrors the web `CoreBoardSetupPrompt` component.
struct CoreBoardSetupPromptView: View {
    let label: String
    let isPast: Bool
    /// When true, this window already has a DRAFT core board: the prompt
    /// reads as "finish your draft" and the CTA (`onSetUp`) resumes it in
    /// the wizard rather than creating a fresh board. Drafts are never
    /// opened as a playable board, so this is how a draft window surfaces.
    var resumeDraft: Bool = false
    /// When true, render as a bare content column (the pager wraps it in
    /// a dashed frame) instead of the standalone full-bleed layout.
    var framed: Bool = false
    let onSetUp: () -> Void

    var body: some View {
        if framed {
            content
        } else {
            ZStack {
                RisoPaperBackground()
                content
                    .padding(Riso.gutter)
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private var content: some View {
        VStack(spacing: 20) {
            // Mini-board art replaces the mood-switched Blip (copy/CTA
            // still vary by isPast/resumeDraft below).
            RisoMiniBoardArt(size: 64, state: resumeDraft ? .draft : .started)

            Text(resumeDraft ? "Draft in progress for \(label)." : "No board for \(label) yet.")
                .risoH2()
                .multilineTextAlignment(.center)

            Text(
                resumeDraft
                    ? "Pick up where you left off and finish setting up this board."
                    : (isPast
                        ? "Add a past board to fill in this window."
                        : "Set up a board for this window to start tracking your goals.")
            )
            .risoSub()
            .multilineTextAlignment(.center)
            .padding(.horizontal, 24)

            RisoButton(
                title: resumeDraft
                    ? "Resume draft"
                    : "\(isPast ? "Backfill" : "Set up") \(label)",
                kind: .primary,
                systemImage: resumeDraft
                    ? "pencil.and.outline"
                    : (isPast ? "clock.arrow.circlepath" : "plus"),
                action: onSetUp
            )
            .padding(.top, 4)
        }
    }
}
