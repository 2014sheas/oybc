import SwiftUI

/// RisoCounterLinkHintView — the always-visible auto-link hint card (R1
/// counters refresh, "Refining counters" design handoff §Creation
/// Surfaces). iOS twin of web's `CounterLinkHint.tsx`.
///
/// Replaces the old suggest-confirm suggestion card. When a counting task's
/// typed (verb, noun) pair exactly matches an existing counter, linking is
/// ON by default — this card explains what will happen and offers a
/// "Don't link" opt-out (toggling back to "Link" re-enables it). It's a
/// single reusable component so the identical hint renders across every
/// counting-task creation surface (`RisoSpecialTaskPanel`'s standalone
/// counting fields and `RisoCompoundFieldsView`'s inline counting sub
/// fields) rather than being duplicated per host.
///
/// Blue fill — dark-mode contract: content uses `Color.risoPaper` (the
/// on-color cream token), matching `RisoButton`'s `.blue` kind
/// (`RisoControls.swift`: fill `.risoBlue` → foreground `.risoPaper`).
/// `risoInkStatic` is reserved for content on the (non-inverting) gold fill —
/// using it here would put near-black text on `risoBlue`'s dark-mode tint,
/// which is nearly illegible. `risoPaper` and `risoBlue` both adapt together
/// (paper flips toward ink, blue lightens) so contrast holds in both schemes.
struct RisoCounterLinkHintView: View {
    /// The matched counter's pair-derived display name
    /// (`CounterName.formatCounterName`), e.g. "Push-ups" or "Run miles".
    let counterName: String
    /// The matched counter's all-time lifetime total.
    let lifetime: Int
    /// The new task's own goal (`maxCount`) — shown in the "0–{goal} window"
    /// sub-copy. Caller only renders this view once a valid positive goal
    /// exists.
    let goal: Int
    /// Whether this create currently links to the counter.
    let linked: Bool
    /// Toggles the link on/off for this create.
    let onToggle: () -> Void

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            VStack(alignment: .leading, spacing: 3) {
                Text(linked ? "Counts toward your \(counterName) counter" : "Won't count toward \(counterName)")
                    .font(.risoHead(13, .bold))
                    .foregroundStyle(Color.risoPaper)
                Text(
                    linked
                        ? "\(lifetime.formatted()) all-time · this task keeps its own 0–\(goal) window"
                        : "Creates a separate, unlinked counter."
                )
                .font(.risoBody(11, .semibold))
                .foregroundStyle(Color.risoPaper.opacity(0.85))
            }
            Spacer(minLength: 0)
            // Outlined pill (not a filled RisoButton) — transparent fill,
            // risoPaper ring + text, matching web's `.hintPill` treatment
            // (an on-blue outline, never a competing solid fill).
            Button(action: onToggle) {
                Text(linked ? "Don't link" : "Link")
                    .font(.risoHead(12, .bold))
                    .foregroundStyle(Color.risoPaper)
                    .padding(.vertical, 6)
                    .padding(.horizontal, 14)
                    .overlay(Capsule().strokeBorder(Color.risoPaper, lineWidth: Riso.Keyline.container))
            }
            .buttonStyle(.plain)
        }
        .padding(10)
        .background(Color.risoBlue)
        .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
        .overlay(
            // Outer keyline stays the static ink ring (matches web's
            // `.hint { border: 2px solid var(--riso-ink-static) }`) — only
            // the pill's own ring uses the on-color cream token.
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .strokeBorder(Color.risoInkStatic, lineWidth: Riso.Keyline.container)
        )
    }
}
