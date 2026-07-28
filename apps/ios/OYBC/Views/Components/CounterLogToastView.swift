import SwiftUI

/// CounterLogToastView — reusable "Logged +N · Undo" toast (R2 Counters UX
/// refresh — Counters Hub + Counter Detail, docs/SHARED_COUNTERS.md
/// §Counters UX refresh → Amount logging, Locked decision 3). iOS twin of
/// web's `CounterLogToast` (`apps/web/src/components/counters/CounterLogToast.tsx`)
/// — copy is VERBATIM per CLAUDE.md cross-platform parity.
///
/// R3 board-play touchpoints unify board-play's ripple toast (formerly
/// `BoardPlayView`'s inline `showCreditToast`, no Undo) onto THIS component
/// via the `message` override below: the credited-toast copy contract
/// ("+{N} {counterName} — also counted on {boards}.") differs from this
/// view's own amount+unit-derived copy, so `message` lets a caller supply
/// fully composed text while reusing the card chrome + Undo affordance +
/// auto-dismiss timer verbatim. Web's twin is `CounterLogToast` merged with
/// `RisoCreditedToast` per the same R3 Global Constraint ("prefer ONE toast
/// component per platform").
///
/// Mount a NEW instance (different `.id(...)`) per toast so the auto-dismiss
/// timer restarts cleanly for back-to-back logs — see call sites in
/// `CountersHubView.swift` / `CounterDetailView.swift` / `BoardPlayView.swift`.
struct CounterLogToastView: View {

    /// Which write the toast is reporting — drives the default copy (ignored
    /// when `message` overrides it).
    enum Verb {
        /// "Logged +{N} {noun} · Undo" — an increment (Hub "+ Log" pill /
        /// Detail "+ Add N").
        case logged
        /// "Removed {N} {noun} · Undo" — a decrement (Detail "−" button).
        case removed
    }

    /// Amount just logged (always positive — see `verb`). Unused for body
    /// text when `message` is set, but still carried for callers/tests.
    let amount: Int
    /// The counter's unit noun, e.g. "push-ups". Unused for body text when
    /// `message` is set.
    let unit: String
    let verb: Verb
    /// R3: a fully composed message that REPLACES the amount+unit+verb-
    /// derived copy — the board-play credited toast's contract
    /// ("+{N} {counterName} — also counted on {board list}.") isn't
    /// expressible as amount/unit/verb alone (it carries a board list). `nil`
    /// (the default) preserves the R2 Hub/Detail "Logged/Removed" copy.
    var message: String? = nil
    /// Reverses the log entry (`AppDatabase.undoLastCounterLog`). The
    /// caller is responsible for clearing the toast after this resolves —
    /// mirrors web's `onUndo` (does NOT itself call `onDone`).
    let onUndo: () -> Void
    /// Called once after the auto-dismiss timer (~4s) expires. NOT called
    /// by `onUndo` — the caller clears the toast itself on that path.
    let onDone: () -> Void

    /// Auto-dismiss duration (design handoff §Interactions — "auto-dismiss ~4s").
    private static let dismissDelay: TimeInterval = 4

    private var verbLabel: String {
        switch verb {
        case .logged: return "Logged +\(amount)"
        case .removed: return "Removed \(amount)"
        }
    }

    private var bodyText: String {
        message ?? "\(verbLabel) \(unit)"
    }

    var body: some View {
        HStack(spacing: 10) {
            Text(bodyText)
                .font(.risoBody(12, .semibold))
                .foregroundStyle(Color.risoInk)
                .multilineTextAlignment(.leading)
                .fixedSize(horizontal: false, vertical: true)

            Spacer(minLength: 8)

            Button("Undo", action: onUndo)
                .font(.risoHead(12, .extraBold))
                .foregroundStyle(Color.risoBlue)
                .buttonStyle(.plain)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
        .background(Color.risoPaper2)
        .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .strokeBorder(Color.risoBlue, lineWidth: Riso.Keyline.dense)
        )
        .background(
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .fill(Color.risoInk)
                .offset(x: Riso.Shadow.small, y: Riso.Shadow.small)
        )
        .accessibilityElement(children: .combine)
        .task {
            do {
                try await _Concurrency.Task.sleep(nanoseconds: UInt64(Self.dismissDelay * 1_000_000_000))
            } catch {
                return // cancelled — the view was torn down (e.g. Undo already cleared it)
            }
            onDone()
        }
    }
}

// MARK: - Preview

#if DEBUG
#Preview("Counter log toast — logged") {
    ZStack {
        RisoPaperBackground()
        VStack {
            Spacer()
            CounterLogToastView(amount: 10, unit: "push-ups", verb: .logged, onUndo: {}, onDone: {})
                .padding(.horizontal, Riso.gutter)
                .padding(.bottom, 24)
        }
    }
}

#Preview("Counter log toast — removed") {
    ZStack {
        RisoPaperBackground()
        VStack {
            Spacer()
            CounterLogToastView(amount: 5, unit: "reps", verb: .removed, onUndo: {}, onDone: {})
                .padding(.horizontal, Riso.gutter)
                .padding(.bottom, 24)
        }
    }
}

#Preview("Counter log toast — board-play credited (R3 message override)") {
    ZStack {
        RisoPaperBackground()
        VStack {
            Spacer()
            CounterLogToastView(
                amount: 10, unit: "push-ups", verb: .logged,
                message: "+10 Push-ups — also counted on Daily Grind.",
                onUndo: {}, onDone: {}
            )
            .padding(.horizontal, Riso.gutter)
            .padding(.bottom, 24)
        }
    }
}
#endif
