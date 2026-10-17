import SwiftUI

// MARK: - Small pieces shared by the square sheet's bodies

/// The square sheet's callbacks. Every default is a no-op so snapshot hosts
/// pass only what they exercise.
struct SquareSheetActions {
    /// "Library ›" pill / a child's chevron: open the task in the library.
    var onOpenLibrary: (String) -> Void = { _ in }
    /// A preset / rest chip, or an "Other…" / "Remove…" entry. `taskId` is the
    /// square's own task or a compound child's; `persistAsDefault` is true only for an entry.
    var onLog: (_ taskId: String, _ amount: CountValue, _ persistAsDefault: Bool) -> Void = { _, _, _ in }
    var onRemove: (_ taskId: String, _ amount: CountValue) -> Void = { _, _ in }
    var onUndo: () -> Void = {}
    var onToggleChild: (String) -> Void = { _ in }
    var onMarkDone: () -> Void = {}
    var onOpenBoard: (String) -> Void = { _ in }
    var onLateLog: () -> Void = {}
}

/// Which "Other…" / "Remove…" amount entry is open, and for which task.
struct SquareSheetEntry: Equatable {
    let scopeTaskId: String
    let isRemove: Bool
}

/// A pill-shaped neutral badge ("WATCHING", "CLOSED") — the `RisoStatusPill`
/// chrome for states that pill has no case for.
struct SquareSheetBadge: View {
    let text: String
    var systemImage: String? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let systemImage { Image(systemName: systemImage).font(.system(size: 8, weight: .bold)) }
            Text(text.uppercased())
        }
        .font(.risoHead(9, .bold))
        .tracking(0.45)
        .foregroundStyle(Color.risoMuted)
        .padding(.vertical, 3)
        .padding(.horizontal, 8)
        .background(Capsule().fill(Color.risoPaper2))
        .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
        .lineLimit(1)
        .fixedSize()
    }
}

/// The 9pt "TAP TO LOG" style eyebrow.
struct SquareSheetEyebrow: View {
    let text: String
    var body: some View {
        Text(text.uppercased())
            .font(.risoHead(9, .bold))
            .tracking(1.1)
            .foregroundStyle(Color.risoMuted)
    }
}

/// The kind's amount entry for "Other…" / "Remove…" (decimal for continuous,
/// an h : m wheel for duration) with OK and cancel.
struct SquareSheetEntryRow: View {
    let kind: CountKind
    let unit: String
    let isRemove: Bool
    var compact: Bool = false
    let onSubmit: (CountValue) -> Void
    let onCancel: () -> Void

    @State private var text = ""

    private var parsed: CountValue? { CounterLogAmount.parseCustom(text, kind: kind) }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            GoalEntryView(
                kind: kind, text: $text, placeholder: isRemove ? "Remove" : "Amount",
                suffix: unit.isEmpty || kind == .duration ? nil : unit,
                startsOpen: kind == .duration
            )
            Button("OK") { if let parsed { onSubmit(parsed) } }
                .font(.risoHead(13, .extraBold))
                .foregroundStyle(Color.risoInkStatic)
                .padding(.vertical, compact ? 7 : 9)
                .padding(.horizontal, 14)
                .background(Capsule().fill(Color.risoGold))
                .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
                .disabled(parsed == nil)
                .opacity(parsed == nil ? 0.5 : 1)
            Button(action: onCancel) {
                Image(systemName: "xmark")
                    .font(.system(size: 12, weight: .bold))
                    .foregroundStyle(Color.risoMuted)
                    .frame(width: 28, height: 36)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Cancel")
        }
    }
}

/// The closed-board lock row: a lock, "Closed Oct 11" and a small neutral
/// "Late log…" when the square is routable.
struct SquareSheetClosedRow: View {
    let closed: SquareSheetContent.Closed
    let onLateLog: () -> Void

    var body: some View {
        HStack(spacing: 10) {
            Image(systemName: "lock.fill")
                .font(.system(size: 13))
                .foregroundStyle(Color.risoMuted)
            Text(closed.lockText)
                .font(.risoHead(13, .bold))
                .foregroundStyle(Color.risoInk)
            Spacer(minLength: 8)
            if closed.canLateLog {
                RisoButton(title: "Late log…", kind: .neutral, small: true, action: onLateLog)
            }
        }
        .padding(.vertical, 10)
        .padding(.horizontal, 12)
        .risoCard(keyline: Riso.Keyline.dense, fill: .risoPaper2)
    }
}
