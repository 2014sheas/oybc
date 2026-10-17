import SwiftUI

/// The blue Log card on Counter Detail (docs/TASK_DETAIL_REDESIGN.md §Counter
/// Detail): the one-gesture chip row (`CounterLogAmount.tapChips(kind:)` — no
/// goal, so no rest chip) logs immediately; "Other…" opens the kind's entry
/// (decimal / h : m) and "− Remove…" the same entry in the other direction.
/// Logging is the caller's `onLog`, which persists the amount as the counter's
/// default. Web twin: `CounterDetailLogCard.tsx`.
struct CounterDetailLogCard: View {

    let group: SharedCounterGroup
    var isLogging: Bool
    var logError: String?
    var onLog: (CountValue, CounterLogDirection) -> Void

    @State private var entryDirection: CounterLogDirection?
    @State private var draft: String

    init(
        group: SharedCounterGroup,
        isLogging: Bool = false,
        logError: String? = nil,
        /// Snapshot-testability seams: open the entry row (optionally prefilled).
        /// Production call sites never pass these.
        initialSelectedAmount: CountValue? = nil,
        initialCustomActive: Bool = false,
        onLog: @escaping (CountValue, CounterLogDirection) -> Void = { _, _ in }
    ) {
        self.group = group
        self.isLogging = isLogging
        self.logError = logError
        self.onLog = onLog
        _entryDirection = State(initialValue: initialCustomActive ? .add : nil)
        _draft = State(initialValue: initialCustomActive ? initialSelectedAmount.map { formatCountForInput($0, kind: group.countKind) } ?? "" : "")
    }

    /// "Log guitar"; a Duration counter has no unit noun ("Log"). Unit-tested.
    static func headerTitle(kind: CountKind, unit: String?) -> String {
        "Log" + countUnitSuffix(kind, unit: unit)
    }

    // MARK: - Body

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(Self.headerTitle(kind: group.countKind, unit: group.unit))
                .font(.risoHead(15, .extraBold))
                .foregroundStyle(Color.risoPaper)

            TapLogChipRow(chips: CounterLogAmount.tapChips(kind: group.countKind, goal: nil), disabled: isLogging) { chip in
                if let value = chip.value {
                    onLog(value, .add)
                } else {
                    open(.add)
                }
            }

            if let direction = entryDirection { entryRow(direction) }

            Button { open(.remove) } label: {
                Text("− Remove…")
                    .font(.risoHead(12, .bold))
                    .foregroundStyle(Color.risoPaper.opacity(0.85))
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .disabled(isLogging || group.lifetime == 0)
            .opacity(isLogging || group.lifetime == 0 ? 0.45 : 1)

            if let logError {
                Text(logError)
                    .font(.risoBody(11, .regular))
                    .foregroundStyle(Color.risoPaper.opacity(0.9))
                    .frame(maxWidth: .infinity)
                    .multilineTextAlignment(.center)
            }
        }
        .padding(Riso.cardPadding)
        .background(RoundedRectangle(cornerRadius: Riso.cardRadius).fill(Color.risoBlue))
        .clipShape(RoundedRectangle(cornerRadius: Riso.cardRadius))
        .overlay(
            RoundedRectangle(cornerRadius: Riso.cardRadius)
                .strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.container)
        )
        .risoHardShadow(Riso.Shadow.card, radius: Riso.cardRadius)
    }

    private func open(_ direction: CounterLogDirection) {
        if entryDirection != direction { draft = "" }
        entryDirection = direction
    }

    private func entryRow(_ direction: CounterLogDirection) -> some View {
        let parsed = CounterLogAmount.parseCustom(draft, kind: group.countKind)
        return HStack(alignment: .top, spacing: 8) {
            GoalEntryView(
                kind: group.countKind, text: $draft, placeholder: direction == .remove ? "Remove" : "Amount",
                suffix: (group.unit ?? "").isEmpty || group.countKind == .duration ? nil : group.unit
            )
            Button("OK") {
                guard let parsed else { return }
                entryDirection = nil
                draft = ""
                onLog(parsed, direction)
            }
            .font(.risoHead(13, .extraBold))
            .foregroundStyle(Color.risoInkStatic)
            .padding(.vertical, 9)
            .padding(.horizontal, 14)
            .background(Capsule().fill(Color.risoGold))
            .overlay(Capsule().strokeBorder(Color.risoInk, lineWidth: Riso.Keyline.dense))
            .disabled(parsed == nil || isLogging)
            .opacity(parsed == nil || isLogging ? 0.5 : 1)
        }
    }
}
